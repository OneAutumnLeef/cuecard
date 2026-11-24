import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Speech

/// What the recogniser heard: the text of the current stretch so far (volatile) or a settled stretch (final).
public struct HeardText: Sendable, Codable, Equatable {
    public let text: String
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal }
}

/// A word from a settled result, with when it was spoken (seconds from the start of the audio).
public struct TimedWord: Sendable, Codable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
}

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String

    /// Every audio device with at least one input stream.
    public static func all() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

public enum ListenerError: LocalizedError {
    case microphoneDenied, noAudioFormat, noInput, unsupportedLocale(String)
    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Turn on Notch Prompter in System Settings → Privacy & Security → Microphone."
        case .noAudioFormat: "The speech recogniser couldn't agree on an audio format."
        case .noInput: "No microphone input is available."
        case .unsupportedLocale(let l): "Speech recognition isn't available for \(l) on this Mac."
        }
    }
}

/// Streams microphone (or file) audio into Apple's on-device `SpeechAnalyzer` and reports what it hears.
///
/// Uses `.volatileResults` + `.fastResults`, which Phase 0 measured at ~0.7 s from word to text
/// (versus ~2.4 s without `.fastResults`). Callbacks arrive on the main thread, in order.
public final class SpeechListener: @unchecked Sendable {
    public typealias TextHandler = @MainActor (HeardText) -> Void
    public typealias LevelHandler = @MainActor (Double) -> Void
    public typealias NoticeHandler = @MainActor (String) -> Void

    private let locale: Locale
    private let onText: TextHandler
    private let onLevel: LevelHandler
    private let onNotice: NoticeHandler

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var engine: AVAudioEngine?
    private var deviceUID: String?
    private var configObserver: NSObjectProtocol?
    private let levelMeter = LevelMeter()
    private var recordURL: URL?
    private var recordFile: AVAudioFile?
    public private(set) var isRunning = false

    public init(locale: Locale, onText: @escaping TextHandler, onLevel: @escaping LevelHandler,
                onNotice: @escaping NoticeHandler = { _ in }) {
        self.locale = locale
        self.onText = onText
        self.onLevel = onLevel
        self.onNotice = onNotice
    }

    // MARK: - Capabilities

    public static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    public static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    /// English locales whose speech model is already on this Mac, plus any others it supports.
    public static func availableLocales() async -> (installed: [Locale], supported: [Locale]) {
        (await Array(SpeechTranscriber.installedLocales), await SpeechTranscriber.supportedLocales)
    }

    // MARK: - Microphone

    /// - Parameter recordTo: if set, the raw microphone audio is also saved there (a .caf file).
    public func startMicrophone(deviceUID: String?, recordTo: URL? = nil) async throws {
        await stop()
        guard await Self.requestMicrophone() else { throw ListenerError.microphoneDenied }
        self.deviceUID = deviceUID
        self.recordURL = recordTo
        let cont = try await startAnalyzer()
        try startEngine(feeding: cont)
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.restartEngine()
        }
        isRunning = true
    }

    public func stop() async {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        stopEngine()
        continuation?.finish()
        continuation = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        transcriber = nil
        resultsTask?.cancel()
        resultsTask = nil
        isRunning = false
    }

    // MARK: - Files (for the benchmark)

    /// Streams a file through the recogniser, paced like a live microphone when `realtime` is true,
    /// and returns once every result has been delivered.
    public func runFile(_ url: URL, realtime: Bool = true) async throws {
        await stop()
        let cont = try await startAnalyzer()
        guard let fmt = analyzerFormat else { throw ListenerError.noAudioFormat }
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard let conv = AVAudioConverter(from: inFmt, to: fmt) else { throw ListenerError.noAudioFormat }
        let chunk = AVAudioFrameCount(inFmt.sampleRate * 0.05)
        let start = DispatchTime.now().uptimeNanoseconds
        var fed = 0.0
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            fed += Double(buf.frameLength) / inFmt.sampleRate
            if realtime {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                if fed > elapsed { try await Task.sleep(nanoseconds: UInt64((fed - elapsed) * 1e9)) }
            }
            reportLevel(buf)
            if let out = convert(buf, conv, fmt) { cont.yield(AnalyzerInput(buffer: out)) }
        }
        cont.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        analyzer = nil
        continuation = nil
    }

    /// Fast, non-live transcription with word timings (used to build ground truth).
    public static func transcribeWords(_ url: URL, locale: Locale) async throws -> [TimedWord] {
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) { try await req.downloadAndInstall() }
        let analyzer = SpeechAnalyzer(modules: [t])
        let file = try AVAudioFile(forReading: url)
        let collect = Task { () -> [TimedWord] in
            var out: [TimedWord] = []
            for try await r in t.results where r.isFinal {
                for run in r.text.runs {
                    guard let tr = run.audioTimeRange else { continue }
                    let w = String(r.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !w.isEmpty { out.append(TimedWord(text: w, start: tr.start.seconds, end: tr.end.seconds)) }
                }
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }

    // MARK: - Internals

    private func startAnalyzer() async throws -> AsyncStream<AnalyzerInput>.Continuation {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw ListenerError.unsupportedLocale(locale.identifier(.bcp47))
        }
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                  reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            deliver { [onNotice] in onNotice("Downloading the speech model…") }
            try await req.downloadAndInstall()
        }
        let a = SpeechAnalyzer(modules: [t])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { throw ListenerError.noAudioFormat }
        try await a.prepareToAnalyze(in: fmt)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let onText = onText, onNotice = onNotice
        resultsTask = Task { [weak self] in
            do {
                for try await r in t.results {
                    let heard = HeardText(text: String(r.text.characters), isFinal: r.isFinal)
                    self?.deliver { onText(heard) }
                }
            } catch is CancellationError {
            } catch {
                self?.deliver { onNotice("Speech recognition stopped: \(error.localizedDescription)") }
            }
        }
        try await a.start(inputSequence: stream)
        analyzer = a
        transcriber = t
        analyzerFormat = fmt
        continuation = cont
        return cont
    }

    private func startEngine(feeding cont: AsyncStream<AnalyzerInput>.Continuation) throws {
        guard let fmt = analyzerFormat else { throw ListenerError.noAudioFormat }
        let engine = AVAudioEngine()   // fresh engine each time: it caches the device format
        let input = engine.inputNode
        if let uid = deviceUID, let device = AudioInputDevice.all().first(where: { $0.uid == uid }),
           let unit = input.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else { throw ListenerError.noInput }
        guard let conv = AVAudioConverter(from: inFmt, to: fmt) else { throw ListenerError.noAudioFormat }
        if let url = recordURL {
            recordFile = try? AVAudioFile(forWriting: url, settings: inFmt.settings)
        }
        let file = recordFile
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
            guard let self else { return }
            try? file?.write(from: buf)
            self.reportLevel(buf)
            if let out = self.convert(buf, conv, fmt) { cont.yield(AnalyzerInput(buffer: out)) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        recordFile = nil      // closes the file
        recordURL = nil       // a device change ends the recording (the format may differ)
    }

    /// The input device changed (AirPods connected, mic unplugged): rebuild the engine, keep the recogniser.
    private func restartEngine() {
        guard isRunning, let cont = continuation else { return }
        stopEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isRunning else { return }
            do {
                try self.startEngine(feeding: cont)
                self.deliver { [onNotice] in onNotice("Microphone changed — still listening") }
            } catch {
                self.deliver { [onNotice] in onNotice("Microphone unavailable: \(error.localizedDescription)") }
            }
        }
    }

    private func convert(_ buf: AVAudioPCMBuffer, _ conv: AVAudioConverter, _ fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var given = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, st in
            if given { st.pointee = .noDataNow; return nil }
            given = true
            st.pointee = .haveData
            return buf
        }
        return status == .error ? nil : out
    }

    private func reportLevel(_ buf: AVAudioPCMBuffer) {
        if let db = levelMeter.add(buf) {
            let onLevel = onLevel
            deliver { onLevel(db) }
        }
    }

    private func deliver(_ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
    }
}

/// Averages audio into one dBFS reading per 50 ms.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sum = 0.0
    private var frames = 0
    private var target = 0

    func add(_ buf: AVAudioPCMBuffer) -> Double? {
        let n = Int(buf.frameLength)
        guard n > 0 else { return nil }
        var s = 0.0
        if let f = buf.floatChannelData?[0] {
            for i in 0..<n { let x = Double(f[i]); s += x * x }
        } else if let p = buf.int16ChannelData?[0] {
            for i in 0..<n { let x = Double(p[i]) / 32768; s += x * x }
        } else {
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        if target == 0 { target = Int(buf.format.sampleRate * 0.05) }
        sum += s
        frames += n
        guard frames >= target else { return nil }
        let rms = (sum / Double(frames)).squareRoot()
        sum = 0
        frames = 0
        return 20 * log10(max(rms, 1e-6))
    }
}
