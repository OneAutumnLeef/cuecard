import AppKit
import Observation
import PrompterCore
import PrompterSpeech
import QuartzCore

/// Size of the island and its text area, in points.
struct PanelGeometry: Equatable {
    var notchWidth: CGFloat = 180
    var notchHeight: CGFloat = 32
    var panelWidth: CGFloat = 440
    var lineHeight: CGFloat = 30
    var visibleLines = 3
    /// Floating panel (anywhere on screen) rather than hanging from the notch.
    var floating = false

    static let hPad: CGFloat = 22
    static let topGap: CGFloat = 6
    static let bottomPad: CGFloat = 14

    var textWidth: CGFloat { panelWidth - 2 * Self.hPad }
    var textHeight: CGFloat { lineHeight * CGFloat(visibleLines) }
    var panelHeight: CGFloat { notchHeight + Self.topGap + textHeight + Self.bottomPad }
    /// Room beside the notch in the menu-bar row, used for the time and speed readouts.
    var wingWidth: CGFloat { max(0, (panelWidth - (floating ? 80 : notchWidth)) / 2 - 14) }
}

enum ListeningState: Equatable {
    case off, starting, listening
    case failed(String)
}

/// All app state: settings, the script, layout and playback (fixed pace or following the voice).
/// The views and controllers observe it.
@Observable
final class AppModel {
    @ObservationIgnored let store: Store

    var settings: PrompterSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    var scriptText: String {
        didSet { if scriptText != oldValue { scriptChanged() } }
    }

    private(set) var script: Script
    private(set) var lines: [[Int]] = []
    private(set) var lineOfToken: [Int] = []
    private(set) var geometry = PanelGeometry()
    private(set) var font: NSFont
    private(set) var spaceWidth: CGFloat = 6

    private(set) var currentIndex = 0
    private(set) var isPlaying = false
    private(set) var isShown = false
    private(set) var isExpanded = false
    private(set) var countdown: Int?
    private(set) var remainingSeconds = 0
    private(set) var isFinished = false
    private(set) var isHovering = false
    let isFirstLaunch: Bool

    // Voice mode
    private(set) var listening: ListeningState = .off
    private(set) var voiceConfidence: VoiceTracker.Confidence = .waiting
    private(set) var voiceActive = false
    private(set) var measuredWPM = 0
    private(set) var notice: String?
    private(set) var scripts: [ScriptInfo] = []
    @ObservationIgnored private var rehearsal: RehearsalRecorder?
    @ObservationIgnored private var lastRehearsalSample = 0.0
    /// Called with a finished (or on-demand) rehearsal report.
    @ObservationIgnored var onRehearsalReport: ((RehearsalReport) -> Void)?
    @ObservationIgnored private var loadingScript = false

    @ObservationIgnored private var scroller: AutoScroller
    @ObservationIgnored private var spoken: SpokenScript
    @ObservationIgnored private var tracker: VoiceTracker
    @ObservationIgnored private var listener: SpeechListener?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var notch: (width: CGFloat, height: CGFloat) = (180, 32)
    @ObservationIgnored private var scrollAccumulator: CGFloat = 0
    @ObservationIgnored private var saveSettingsTask: Task<Void, Never>?
    @ObservationIgnored private var saveScriptTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    /// For automated checks: listen to this file instead of the microphone.
    @ObservationIgnored var debugAudioFile: URL?
    /// When set, the next voice session is saved (audio + log) for tuning.
    var recordNextTake = false
    @ObservationIgnored private var take: DiagnosticTake?
    @ObservationIgnored private var takeBase: URL?
    @ObservationIgnored private var takeStart = 0.0
    @ObservationIgnored private var lastSampleAt = 0.0
    @ObservationIgnored var openEditor: (() -> Void)?
    @ObservationIgnored var openSettings: (() -> Void)?
    @ObservationIgnored var onShownChange: ((Bool) -> Void)?
    @ObservationIgnored var onPlayingChange: ((Bool) -> Void)?
    @ObservationIgnored var onLayoutChange: (() -> Void)?
    @ObservationIgnored var onScreenPreferenceChange: (() -> Void)?

    var isVoiceMode: Bool { settings.scrollMode == .voice }
    var currentLine: Int { lineOfToken.isEmpty ? 0 : lineOfToken[min(currentIndex, lineOfToken.count - 1)] }
    var hasStarted: Bool { isVoiceMode ? currentIndex > 0 : scroller.position > 0 }
    var estimatedSeconds: Int { Int(AutoScroller(script: script, wpm: settings.wpm).totalTime().rounded()) }

    init(store: Store) {
        self.store = store
        var s = store.loadSettings()
        let library = store.library
        let firstLaunch = library.list().isEmpty && store.loadScript() == nil
        let migrated = (try? store.migrateToLibrary(welcomeText: SampleScript.text)) ?? "Welcome"
        if s.currentScriptID.isEmpty || !library.contains(s.currentScriptID) { s.currentScriptID = migrated }
        let text = library.load(s.currentScriptID) ?? ""
        let parsed = Script(text: text)
        let spokenScript = SpokenScript(parsed)
        isFirstLaunch = firstLaunch
        settings = s
        scriptText = text
        script = parsed
        spoken = spokenScript
        font = Fonts.prompter(s)
        scroller = AutoScroller(script: parsed, wpm: s.wpm)
        tracker = AppModel.makeTracker(spokenScript, wpm: s.wpm, startWord: 0)
        scripts = library.list()
        relayout()
        updateRemaining()
        try? store.save(s)
    }

    // MARK: - Script library

    var currentScriptID: String { settings.currentScriptID }

    func reloadScripts() { scripts = store.library.list() }

    func selectScript(_ id: String) {
        guard id != settings.currentScriptID, let text = store.library.load(id) else { return }
        flushScriptSave()
        loadingScript = true
        settings.currentScriptID = id
        scriptText = text
        loadingScript = false
        jump(to: 0)
    }

    func newScript() {
        guard let info = try? store.library.create(title: "Untitled", text: "") else { return }
        reloadScripts()
        selectScript(info.id)
    }

    func importScript(title: String, text: String) {
        guard let info = try? store.library.create(title: title, text: text) else { return }
        reloadScripts()
        selectScript(info.id)
        showNotice("Imported “\(info.id)”")
    }

    /// Opens a script by title (case-insensitive). Returns false if there's no such script.
    @discardableResult
    func openScript(titled title: String) -> Bool {
        guard let info = scripts.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) else { return false }
        selectScript(info.id)
        return true
    }

    func renameCurrentScript(to title: String) {
        flushScriptSave()
        guard let newID = try? store.library.rename(settings.currentScriptID, to: title),
              newID != settings.currentScriptID else { return }
        settings.currentScriptID = newID
        reloadScripts()
    }

    /// Moves a script to the Trash. If it was open, opens the next one (or a new empty script).
    func deleteScript(_ id: String) {
        if id == settings.currentScriptID { saveScriptTask?.cancel() }
        try? store.library.delete(id)
        reloadScripts()
        guard id == settings.currentScriptID else { return }
        if let next = scripts.first {
            settings.currentScriptID = ""
            selectScript(next.id)
        } else {
            newScript()
        }
    }

    private func flushScriptSave() {
        guard saveScriptTask != nil else { return }
        saveScriptTask?.cancel()
        saveScriptTask = nil
        try? store.library.save(settings.currentScriptID, text: scriptText)
    }

    private static func makeTracker(_ s: SpokenScript, wpm: Double, startWord: Int) -> VoiceTracker {
        var c = TrackerConfig()
        c.initialRate = min(max(wpm / 60, 1.2), 4.5)
        return VoiceTracker(script: s, config: c, startWord: startWord)
    }

    // MARK: - Layout

    func setNotch(width: CGFloat, height: CGFloat) {
        guard notch.width != width || notch.height != height else { return }
        notch = (width, height)
        relayout()
    }

    private func relayout() {
        font = Fonts.prompter(settings)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        spaceWidth = (" " as NSString).size(withAttributes: attrs).width
        var g = PanelGeometry()
        g.floating = settings.displayMode == .floating
        g.notchWidth = g.floating ? 0 : notch.width
        g.notchHeight = g.floating ? 26 : notch.height
        g.panelWidth = max(CGFloat(settings.panelWidth), g.notchWidth + 100)
        g.lineHeight = CGFloat(settings.fontSize * settings.lineSpacing).rounded()
        g.visibleLines = settings.visibleLines
        geometry = g
        let tokens = script.tokens
        lines = LineLayout.wrap(tokens, maxWidth: Double(g.textWidth - 8), spaceWidth: Double(spaceWidth)) {
            Double((tokens[$0].text as NSString).size(withAttributes: attrs).width)
        }
        lineOfToken = LineLayout.lineIndex(of: lines, tokenCount: tokens.count)
        onLayoutChange?()
    }

    private func settingsChanged(from old: PrompterSettings) {
        let s = settings
        if s.wpm != old.wpm {
            scroller.wpm = s.wpm
            updateRemaining()
        }
        if s.scrollMode != old.scrollMode {
            if rehearsal != nil { completeRehearsal(show: false) }
            let wasPlaying = isPlaying || countdown != nil
            pause()
            cancelCountdown()
            positionEngines(atToken: currentIndex)
            showNotice(s.scrollMode == .voice ? "Following your voice" : "Fixed speed: \(Int(s.wpm)) wpm")
            if wasPlaying { play() }
        } else if (s.speechLocale != old.speechLocale || s.microphoneUID != old.microphoneUID), listener != nil {
            stopListening()
            startListening()
        }
        let affectsLayout = s.fontSize != old.fontSize || s.fontWeight != old.fontWeight
            || s.fontDesign != old.fontDesign || s.lineSpacing != old.lineSpacing
            || s.panelWidth != old.panelWidth || s.visibleLines != old.visibleLines
            || s.displayMode != old.displayMode
        if s.screenName != old.screenName || s.displayMode != old.displayMode { onScreenPreferenceChange?() }
        if affectsLayout { relayout() } else { onLayoutChange?() }
        saveSettingsTask?.cancel()
        let store = store
        saveSettingsTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? store.save(s)
        }
    }

    private func scriptChanged() {
        let keep = currentIndex
        if rehearsal != nil { completeRehearsal(show: false) }
        script = Script(text: scriptText)
        spoken = SpokenScript(script)
        scroller = AutoScroller(script: script, wpm: settings.wpm)
        tracker = Self.makeTracker(spoken, wpm: settings.wpm, startWord: 0)
        isFinished = false
        positionEngines(atToken: min(keep, max(script.tokens.count - 1, 0)))
        relayout()
        guard !loadingScript else { return }
        saveScriptTask?.cancel()
        let library = store.library, text = scriptText, id = settings.currentScriptID
        saveScriptTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? library.save(id, text: text)
            self.saveScriptTask = nil
            self.reloadScripts()
        }
    }

    /// Puts both the fixed-pace scroller and the voice tracker at a token, so switching modes keeps your place.
    private func positionEngines(atToken token: Int) {
        if token > 0 { scroller.jump(to: token) } else { scroller = AutoScroller(script: script, wpm: settings.wpm) }
        tracker.jump(toWord: wordIndex(forToken: token))
        syncIndex()
    }

    private func wordIndex(forToken t: Int) -> Int {
        guard !spoken.firstWordOfToken.isEmpty else { return 0 }
        return spoken.firstWordOfToken[min(max(t, 0), spoken.firstWordOfToken.count - 1)]
    }

    // MARK: - Showing and hiding

    func show() {
        hideTask?.cancel()
        if isShown {
            if !isExpanded { isExpanded = true }
            return
        }
        isShown = true
        onShownChange?(true)
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            self.isExpanded = true
        }
    }

    /// Shows the control bar after a short delay, so passing the cursor over the notch doesn't flash it.
    func setHovering(_ inside: Bool) {
        hoverTask?.cancel()
        guard inside else {
            if isHovering { isHovering = false }
            return
        }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self.isHovering = true
        }
    }

    func hide() {
        pause()
        cancelCountdown()
        setHovering(false)
        guard isShown else { return }
        isExpanded = false
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self.isShown = false
            self.onShownChange?(false)
        }
    }

    func toggleShown() { isShown && isExpanded ? hide() : show() }

    // MARK: - Playback

    func togglePlay() {
        if countdown != nil { cancelCountdown(); return }
        isPlaying ? pause() : play()
    }

    func play() {
        let wasVisible = isShown && isExpanded
        show()
        guard !script.isEmpty else { return }
        if isFinished { jump(to: 0) }
        if isVoiceMode {
            startListening()   // no countdown: it simply waits for you to start reading
            return
        }
        if scroller.isFinished { jump(to: 0) }
        if !hasStarted, settings.countdownSeconds > 0 {
            startCountdown(from: settings.countdownSeconds, after: wasVisible ? 0 : 0.45)
        } else {
            setPlaying(true)
        }
    }

    func pause() {
        setPlaying(false)
        stopListening()
    }

    func restart() {
        cancelCountdown()
        rehearsal = nil          // starting over: a new run-through
        jump(to: 0)
    }

    // MARK: - Rehearsal reports

    /// Saves the current run-through's report (if there's enough to say) and optionally shows it.
    func completeRehearsal(show: Bool) {
        guard let r = rehearsal else { return }
        rehearsal = nil
        guard let report = r.report(title: settings.currentScriptID) else { return }
        try? store.rehearsals.save(report)
        if show { onRehearsalReport?(report) }
    }

    /// The menu's "Rehearsal Report…": the run-through in progress, else the latest saved one for this script.
    func showRehearsalReport() {
        if let live = rehearsal?.report(title: settings.currentScriptID) {
            onRehearsalReport?(live)
        } else if let saved = store.rehearsals.all(script: settings.currentScriptID).first {
            onRehearsalReport?(saved)
        } else {
            showNotice("No rehearsals of this script yet. Read it in voice mode.")
        }
    }

    func toggleVoiceMode() { settings.scrollMode = isVoiceMode ? .fixed : .voice }

    func tick(_ dt: Double) {
        guard isPlaying else { return }
        if isVoiceMode {
            let now = CACurrentMediaTime()
            tracker.advance(to: now)
            syncIndex()
            if rehearsal != nil, now - lastRehearsalSample >= 0.05 {
                lastRehearsalSample = now
                rehearsal?.sample(t: now, confirmed: tracker.confirmed, speaking: tracker.isSpeaking)
            }
            if take != nil, now - lastSampleAt >= 0.05 {
                lastSampleAt = now
                take?.samples.append(.init(t: now - takeStart, display: tracker.display,
                                           confirmed: tracker.confirmed, speaking: tracker.isSpeaking))
            }
            if tracker.confidence != voiceConfidence { voiceConfidence = tracker.confidence }
            if tracker.isSpeaking != voiceActive { voiceActive = tracker.isSpeaking }
            let wpm = Int(tracker.wordsPerMinute.rounded())
            if abs(wpm - measuredWPM) >= 3 { measuredWPM = wpm }
            if tracker.isFinished, !isFinished {
                isFinished = true
                finishTask?.cancel()
                finishTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, self.isFinished else { return }
                    self.pause()
                    self.completeRehearsal(show: self.settings.showReportOnFinish)
                }
            }
            return
        }
        scroller.advance(by: dt)
        syncIndex()
        if scroller.isFinished {
            isFinished = true
            setPlaying(false)
        }
    }

    func jump(to index: Int) {
        scroller.jump(to: index)
        tracker.jump(toWord: wordIndex(forToken: index))
        isFinished = false
        finishTask?.cancel()
        syncIndex()
    }

    func previousSentence() { jump(to: script.previousSentenceStart(from: currentIndex)) }

    func nextSentence() {
        if let n = script.nextSentenceStart(from: currentIndex) { jump(to: n) }
    }

    func faster() { settings.wpm = min(settings.wpm + 10, AutoScroller.maxWPM) }
    func slower() { settings.wpm = max(settings.wpm - 10, AutoScroller.minWPM) }

    /// Trackpad / wheel scrolling over the panel moves the position line by line.
    func scroll(by deltaY: CGFloat) {
        guard !lines.isEmpty else { return }
        scrollAccumulator += deltaY
        let step = max(geometry.lineHeight, 10)
        var moved = 0
        while scrollAccumulator <= -step { scrollAccumulator += step; moved += 1 }
        while scrollAccumulator >= step { scrollAccumulator -= step; moved -= 1 }
        guard moved != 0 else { return }
        let target = min(max(currentLine + moved, 0), lines.count - 1)
        jump(to: lines[target][0])
    }

    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        onPlayingChange?(playing)
    }

    private func startCountdown(from n: Int, after delay: Double) {
        cancelCountdown()
        countdownTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            for i in stride(from: n, to: 0, by: -1) {
                guard !Task.isCancelled else { return }
                self.countdown = i
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self.countdown = nil
            self.setPlaying(true)
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        if countdown != nil { countdown = nil }
    }

    private func syncIndex() {
        let i = isVoiceMode ? spoken.token(atWord: tracker.displayWord) : scroller.currentIndex
        if i != currentIndex { currentIndex = i }
        updateRemaining()
    }

    private func updateRemaining() {
        let r: Int
        if isVoiceMode {
            r = Int((Double(max(spoken.count - tracker.displayWord - 1, 0)) / max(tracker.rate, 0.5)).rounded(.up))
        } else {
            r = Int(scroller.remainingTime().rounded(.up))
        }
        if r != remainingSeconds { remainingSeconds = r }
    }

    // MARK: - Listening

    /// The speech language: the chosen one, or the Mac's language and region.
    var resolvedLocale: Locale {
        if !settings.speechLocale.isEmpty { return Locale(identifier: settings.speechLocale) }
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier ?? "US"
        return Locale(identifier: "\(lang)-\(region)")
    }

    private func startListening(locale: Locale? = nil) {
        setPlaying(true)
        guard listener == nil else { return }
        listening = .starting
        let useLocale = locale ?? resolvedLocale
        var recordURL: URL?
        if recordNextTake, debugAudioFile == nil {
            let base = DiagnosticTake.newBaseURL()
            takeBase = base
            recordURL = base.appendingPathExtension("caf")
            take = DiagnosticTake(script: scriptText, locale: useLocale.identifier(.bcp47), audioFile: recordURL!.lastPathComponent)
            takeStart = CACurrentMediaTime()
            showNotice("Recording a diagnostic take")
        }
        let l = SpeechListener(
            locale: useLocale,
            onText: { [weak self] heard in
                guard let self else { return }
                let now = CACurrentMediaTime()
                tracker.hear(heard.text, isFinal: heard.isFinal, at: now)
                if heard.isFinal { rehearsal?.heard(final: heard.text) }
                take?.events.append(.init(t: now - takeStart, text: heard.text, final: heard.isFinal))
            },
            onLevel: { [weak self] db in
                guard let self else { return }
                let now = CACurrentMediaTime()
                tracker.level(db, at: now)
                take?.levels.append(.init(t: now - takeStart, db: db))
            },
            onNotice: { [weak self] message in self?.showNotice(message) }
        )
        listener = l
        tracker.recogniserRestarted()
        if rehearsal == nil { rehearsal = RehearsalRecorder(script: spoken) }
        let uid = settings.microphoneUID.isEmpty ? nil : settings.microphoneUID
        let testAudio = debugAudioFile
        listenTask = Task { [weak self] in
            do {
                if let testAudio {
                    // Automated check: play a recording through the same pipeline instead of the mic.
                    self?.listening = .listening
                    try await l.runFile(testAudio, realtime: true)
                    return
                }
                try await l.startMicrophone(deviceUID: uid, recordTo: recordURL)
                guard let self, self.listener === l else { await l.stop(); return }
                self.listening = .listening
                if recordURL != nil { self.takeStart = CACurrentMediaTime() }   // audio starts about now
            } catch ListenerError.unsupportedLocale(let code) where locale == nil && code != "en-US" {
                guard let self, self.listener === l else { return }
                self.listener = nil
                self.showNotice("No speech model for \(code); using US English")
                self.startListening(locale: Locale(identifier: "en-US"))
            } catch {
                guard let self, self.listener === l else { return }
                self.listener = nil
                self.listening = .failed(error.localizedDescription)
                self.setPlaying(false)
                self.showNotice(error.localizedDescription, seconds: 6)
            }
        }
    }

    private func stopListening() {
        listenTask?.cancel()
        listenTask = nil
        if let l = listener {
            listener = nil
            Task { await l.stop() }
        }
        if let t = take, let base = takeBase {
            take = nil
            takeBase = nil
            recordNextTake = false
            do {
                try t.save(to: base)
                showNotice("Diagnostic take saved", seconds: 3)
            } catch {
                showNotice("Couldn't save the take: \(error.localizedDescription)", seconds: 4)
            }
        }
        if case .failed = listening { return }
        listening = .off
        voiceActive = false
    }

    func showNotice(_ text: String, seconds: Double = 2.5) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.notice = nil
        }
    }
}

enum SampleScript {
    static let text = """
    Welcome to Notch Prompter. This text sits right under your camera, so you can read while looking at the lens.
    Read this aloud and the highlight follows your voice. Speed up, slow down or stop, and it keeps your place. [PAUSE]
    Hover over the prompter to get controls, or right-click it for the full menu. Control Option V switches between following your voice and a fixed speed.
    Control Option left or right bracket jumps back or forward a sentence. Click any word to jump to it, or scroll on the panel to move line by line. [smile]
    Control Option E opens the editor for your own script, and Control Option comma opens settings. Words in square brackets are stage notes.
    """
}
