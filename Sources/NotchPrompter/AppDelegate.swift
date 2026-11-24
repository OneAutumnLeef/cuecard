import AppKit
import PrompterCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panel: NotchPanelController!
    private var ticker: Ticker!
    private var menuBar: MenuBarController!
    private var editor: EditorWindowController!
    private var settingsWindow: SettingsWindowController!
    private var welcome: WelcomeWindowController!
    private var reportWindow: RehearsalWindowController!
    private var remote: PhoneRemote!
    private var remoteWindow: PhoneRemoteWindowController!
    private var shownBeforeSettings = false
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = LaunchArgs.parse()
        model = AppModel(store: args.storeDir.map { Store(directory: URL(fileURLWithPath: $0)) } ?? .standard)
        panel = NotchPanelController(model: model)
        ticker = Ticker { [weak self] dt in self?.model.tick(dt) }
        model.onPlayingChange = { [weak self] playing in self?.ticker.setRunning(playing, screen: self?.panel.screen) }

        editor = EditorWindowController(model: model) { [weak self] in self?.model.play() }
        settingsWindow = SettingsWindowController(model: model)
        settingsWindow.onOpen = { [weak self] in
            guard let self else { return }
            shownBeforeSettings = model.isShown && model.isExpanded
            model.show()   // live preview while adjusting
        }
        settingsWindow.onClose = { [weak self] in
            guard let self, !shownBeforeSettings, !model.isPlaying, model.countdown == nil else { return }
            model.hide()
        }

        welcome = WelcomeWindowController(model: model,
                                          onTry: { [weak self] in self?.model.play() },
                                          onEditor: { [weak self] in self?.editor.show() })
        reportWindow = RehearsalWindowController(model: model)
        remote = PhoneRemote(model: model)
        remoteWindow = PhoneRemoteWindowController(remote: remote)
        model.onRehearsalReport = { [weak self] report in self?.reportWindow.show(report) }
        let m = model!
        let commands = Commands(
            togglePlay: { m.togglePlay() },
            restart: { m.restart() },
            toggleShown: { m.toggleShown() },
            previousSentence: { m.previousSentence() },
            nextSentence: { m.nextSentence() },
            faster: { m.faster() },
            slower: { m.slower() },
            editScript: { [weak self] in self?.editor.show() },
            openFile: { [weak self] in self?.editor.openFile() },
            openSettings: { [weak self] in self?.settingsWindow.show() },
            toggleVoice: { m.toggleVoiceMode() },
            openWelcome: { [weak self] in self?.welcome.show() },
            rehearsalReport: { m.showRehearsalReport() },
            phoneRemote: { [weak self] in self?.remoteWindow.show() }
        )
        menuBar = MenuBarController(model: model, commands: commands)
        panel.menuProvider = { [weak self] in self?.menuBar.makeMenu() ?? NSMenu() }
        model.openEditor = commands.editScript
        model.openSettings = commands.openSettings
        let hk = HotKeys.shared
        hk.register(.play, name: "Start / pause", commands.togglePlay)
        hk.register(.show, name: "Show / hide", commands.toggleShown)
        hk.register(.restart, name: "Restart", commands.restart)
        hk.register(.previous, name: "Previous sentence", commands.previousSentence)
        hk.register(.next, name: "Next sentence", commands.nextSentence)
        hk.register(.slower, name: "Slower", commands.slower)
        hk.register(.faster, name: "Faster", commands.faster)
        hk.register(.edit, name: "Edit script", commands.editScript)
        hk.register(.settings, name: "Settings", commands.openSettings)
        hk.register(.voice, name: "Voice / fixed speed", commands.toggleVoice)

        let queued = pendingURLs
        pendingURLs = []
        queued.forEach(handle)
        if args.isEmpty {
            if model.isFirstLaunch && queued.isEmpty { welcome.show() }
        } else {
            runDebugArgs(args)
        }
    }

    // MARK: - notchprompter:// links (Shortcuts, the `prompter` command, other apps)

    func application(_ application: NSApplication, open urls: [URL]) {
        guard model != nil else { pendingURLs.append(contentsOf: urls); return }
        urls.forEach(handle)
    }

    static var inbox: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTele/Inbox", isDirectory: true)
    }

    private func handle(_ url: URL) {
        guard let command = URLCommand.parse(url) else {
            model.showNotice("Didn't understand that link")
            return
        }
        switch command {
        case .add(let title, let source, let start):
            let text: String?
            switch source {
            case .text(let t): text = t
            case .inbox(let name):
                let file = Self.inbox.appendingPathComponent(name)
                text = try? String(contentsOf: file, encoding: .utf8)
                try? FileManager.default.removeItem(at: file)
            }
            guard let text, !text.isEmpty else { model.showNotice("That script was empty"); return }
            model.importScript(title: title, text: text)
            if start { model.play() } else { model.show() }
        case .open(let title, let start):
            guard model.openScript(titled: title) else { model.showNotice("No script called “\(title)”"); return }
            if start { model.play() } else { model.show() }
        case .play: model.play()
        case .pause: model.pause()
        case .toggle: model.togglePlay()
        case .show: model.show()
        case .hide: model.hide()
        case .restart: model.restart()
        case .mode(let voice): model.settings.scrollMode = voice ? .voice : .fixed
        }
    }

    // MARK: - Launch arguments used for automated checks

    private func runDebugArgs(_ a: LaunchArgs) {
        if let f = a.listenFile { model.debugAudioFile = URL(fileURLWithPath: f) }
        if let path = a.script, let text = try? String(contentsOfFile: path, encoding: .utf8) { model.scriptText = text }
        if a.editor { editor.show() }
        if a.settings { settingsWindow.show() }
        if a.welcome { welcome.show() }
        if a.remote, a.windowShot != nil { remoteWindow.show() }
        if a.remote { remote.start(); print("REMOTE \(remote.address) \(remote.ipAddress ?? "")"); fflush(stdout) }
        if a.show { model.show() }
        if a.play { model.play() }
        if let i = a.seek { model.jump(to: i) }
        if a.hover { after(0.6) { [weak self] in self?.model.setHovering(true) } }
        if let path = a.snapshot {
            after(a.snapshotAfter) { [weak self] in self?.snapshot(to: path) }
        }
        if let path = a.windowShot {
            after(a.snapshotAfter) { [weak self] in
                guard let self else { return }
                let w = a.remote ? remoteWindow.nsWindow : a.report ? reportWindow.nsWindow
                    : (a.settings ? settingsWindow.nsWindow : (a.welcome ? welcome.nsWindow : editor.nsWindow))
                if let v = w?.contentView { self.writeViewImage(v, to: path) }
            }
        }
        if let q = a.quitAfter { after(q) { NSApp.terminate(nil) } }
    }

    private func after(_ seconds: Double, _ f: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            f()
        }
    }

    private func snapshot(to path: String) {
        let view = PrompterView(model: model).background(Color(white: 0.86))
        let r = ImageRenderer(content: view)
        r.scale = panel.screen?.backingScaleFactor ?? 2
        if let cg = r.cgImage { write(cg, to: path) }
    }

    /// Captures a window's content over its background colour (the content alone is often transparent).
    private func writeViewImage(_ v: NSView, to path: String) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let out = NSImage(size: v.bounds.size)
        out.lockFocus()
        v.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: v.bounds.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: v.bounds.size), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) {
            try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    private func write(_ cg: CGImage, to path: String) {
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

struct LaunchArgs {
    var storeDir: String?
    var show = false, play = false, editor = false, settings = false, hover = false, welcome = false, report = false, remote = false
    var seek: Int?
    var listenFile: String?, script: String?
    var snapshot: String?, windowShot: String?
    var snapshotAfter = 2.0
    var quitAfter: Double?

    var isEmpty: Bool {
        !show && !play && !editor && !settings && !hover && !welcome && !remote && listenFile == nil && script == nil && seek == nil && snapshot == nil && windowShot == nil && quitAfter == nil
    }

    static func parse() -> LaunchArgs {
        var a = LaunchArgs()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let x = it.next() {
            switch x {
            case "--store": a.storeDir = it.next()
            case "--show": a.show = true
            case "--play": a.play = true
            case "--editor": a.editor = true
            case "--settings": a.settings = true
            case "--hover": a.hover = true
            case "--welcome": a.welcome = true
            case "--report": a.report = true
            case "--remote": a.remote = true
            case "--listen-file": a.listenFile = it.next()
            case "--script": a.script = it.next()
            case "--seek": a.seek = it.next().flatMap { Int($0) }
            case "--snapshot": a.snapshot = it.next()
            case "--window-shot": a.windowShot = it.next()
            case "--snapshot-after": a.snapshotAfter = it.next().flatMap { Double($0) } ?? 2
            case "--quit-after": a.quitAfter = it.next().flatMap { Double($0) }
            default: break
            }
        }
        return a
    }
}
