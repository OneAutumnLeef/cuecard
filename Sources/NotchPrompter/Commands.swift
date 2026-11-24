import AppKit
import Carbon.HIToolbox
import PrompterSpeech

/// Every action the menu bar and the global hotkeys can trigger.
struct Commands {
    var togglePlay: () -> Void
    var restart: () -> Void
    var toggleShown: () -> Void
    var previousSentence: () -> Void
    var nextSentence: () -> Void
    var faster: () -> Void
    var slower: () -> Void
    var editScript: () -> Void
    var openFile: () -> Void
    var openSettings: () -> Void
    var toggleVoice: () -> Void
    var openWelcome: () -> Void
    var rehearsalReport: () -> Void
    var phoneRemote: () -> Void
}

/// A global shortcut: Control + Option + key.
struct Shortcut {
    let keyCode: Int
    /// Key equivalent shown in the menu.
    let key: String
    let symbol: String

    static let modifiers = UInt32(controlKey | optionKey)
    static let menuModifiers: NSEvent.ModifierFlags = [.control, .option]

    static let play = Shortcut(keyCode: kVK_Space, key: " ", symbol: "Space")
    static let restart = Shortcut(keyCode: kVK_ANSI_R, key: "r", symbol: "R")
    static let show = Shortcut(keyCode: kVK_ANSI_P, key: "p", symbol: "P")
    static let previous = Shortcut(keyCode: kVK_ANSI_LeftBracket, key: "[", symbol: "[")
    static let next = Shortcut(keyCode: kVK_ANSI_RightBracket, key: "]", symbol: "]")
    static let slower = Shortcut(keyCode: kVK_ANSI_Minus, key: "-", symbol: "−")
    static let faster = Shortcut(keyCode: kVK_ANSI_Equal, key: "=", symbol: "=")
    static let edit = Shortcut(keyCode: kVK_ANSI_E, key: "e", symbol: "E")
    static let settings = Shortcut(keyCode: kVK_ANSI_Comma, key: ",", symbol: ",")
    static let voice = Shortcut(keyCode: kVK_ANSI_V, key: "v", symbol: "V")

    var display: String { "⌃⌥\(symbol)" }

    static let all: [(name: String, shortcut: Shortcut)] = [
        ("Start / pause", .play), ("Show / hide prompter", .show), ("Restart", .restart),
        ("Previous sentence", .previous), ("Next sentence", .next),
        ("Slower", .slower), ("Faster", .faster), ("Edit script", .edit), ("Settings", .settings),
        ("Voice / fixed speed", .voice),
    ]
}

/// Registers system-wide hotkeys with Carbon, which needs no Accessibility permission.
final class HotKeys {
    static let shared = HotKeys()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    private(set) var failed: [String] = []

    func register(_ s: Shortcut, name: String, _ handler: @escaping () -> Void) {
        installIfNeeded()
        let id = UInt32(handlers.count + refs.count + failed.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(s.keyCode), Shortcut.modifiers,
                                         EventHotKeyID(signature: OSType(0x4D54_4C50), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
        } else {
            failed.append("\(name) (\(s.display))")
            NSLog("Notch Prompter: could not register \(s.display) for \(name), status \(status)")
        }
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }
}

nonisolated private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                       _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hk = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    guard status == noErr else { return status }
    let id = hk.id
    MainActor.assumeIsolated { HotKeys.shared.fire(id) }  // Carbon delivers these on the main thread
    return noErr
}

/// The menu-bar icon and its menu, rebuilt each time it opens so titles match the current state.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private let commands: Commands

    init(model: AppModel, commands: Commands) {
        self.model = model
        self.commands = commands
        super.init()
        item.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Notch Prompter")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    /// The same menu, for right-clicking the prompter (the menu-bar icon can sit behind the island).
    func makeMenu() -> NSMenu {
        let m = NSMenu()
        populate(m)
        return m
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let playTitle: String = if model.countdown != nil { "Cancel Countdown" }
            else if model.isPlaying { "Pause" }
            else if model.hasStarted && !model.isFinished { "Resume" }
            else { "Start" }
        add(menu, playTitle, .play, commands.togglePlay)
        add(menu, "Restart", .restart, commands.restart)
        add(menu, model.isShown && model.isExpanded ? "Hide Prompter" : "Show Prompter", .show, commands.toggleShown)
        menu.addItem(.separator())
        add(menu, "Previous Sentence", .previous, commands.previousSentence)
        add(menu, "Next Sentence", .next, commands.nextSentence)
        menu.addItem(.separator())
        add(menu, "Follow My Voice", .voice, commands.toggleVoice)
        menu.items.last?.state = model.isVoiceMode ? .on : .off
        if model.isVoiceMode {
            menu.addItem(microphoneMenu())
            add(menu, "Record Diagnostic Take", nil) { [weak self] in
                guard let self else { return }
                model.recordNextTake.toggle()
                model.showNotice(model.recordNextTake ? "The next voice session will be recorded" : "Diagnostic take cancelled")
            }
            menu.items.last?.state = model.recordNextTake ? .on : .off
            if case .failed = model.listening {
                add(menu, "Open Microphone Privacy Settings…", nil) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else {
            let speed = NSMenuItem(title: "Speed: \(Int(model.settings.wpm)) words per minute", action: nil, keyEquivalent: "")
            speed.isEnabled = false
            menu.addItem(speed)
            add(menu, "Faster", .faster, commands.faster)
            add(menu, "Slower", .slower, commands.slower)
        }
        menu.addItem(.separator())
        add(menu, "Edit Scripts…", .edit, commands.editScript)
        add(menu, "Rehearsal Report…", nil, commands.rehearsalReport)
        menu.addItem(scriptsMenu())
        add(menu, "Settings…", .settings, commands.openSettings)
        add(menu, "Phone Remote…", nil, commands.phoneRemote)
        add(menu, "Welcome & Shortcuts…", nil, commands.openWelcome)
        if !HotKeys.shared.failed.isEmpty {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "Shortcuts in use by another app: " + HotKeys.shared.failed.joined(separator: ", "),
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        menu.addItem(.separator())
        add(menu, "Quit Notch Prompter", nil, { NSApp.terminate(nil) }, key: "q", modifiers: .command)
    }

    private func scriptsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Scripts", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for info in model.scripts.prefix(20) {
            add(sub, info.title, nil) { [weak self] in self?.model.selectScript(info.id) }
            sub.items.last?.state = info.id == model.currentScriptID ? .on : .off
        }
        sub.addItem(.separator())
        add(sub, "New Script", nil) { [weak self] in
            self?.model.newScript()
            self?.commands.editScript()
        }
        add(sub, "Import File…", nil, commands.openFile)
        item.submenu = sub
        return item
    }

    private func microphoneMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = model.settings.microphoneUID
        add(sub, "System Default", nil) { [weak self] in self?.model.settings.microphoneUID = "" }
        sub.items.last?.state = current.isEmpty ? .on : .off
        for device in AudioInputDevice.all() {
            add(sub, device.name, nil) { [weak self] in self?.model.settings.microphoneUID = device.uid }
            sub.items.last?.state = device.uid == current ? .on : .off
        }
        item.submenu = sub
        return item
    }

    private func add(_ menu: NSMenu, _ title: String, _ shortcut: Shortcut?, _ action: @escaping () -> Void,
                     key: String = "", modifiers: NSEvent.ModifierFlags = []) {
        let mi = NSMenuItem(title: title, action: #selector(MenuActionTarget.run(_:)), keyEquivalent: "")
        mi.target = MenuActionTarget.shared
        mi.representedObject = ActionBox(action)
        if let shortcut {
            mi.keyEquivalent = shortcut.key
            mi.keyEquivalentModifierMask = Shortcut.menuModifiers
        } else if !key.isEmpty {
            mi.keyEquivalent = key
            mi.keyEquivalentModifierMask = modifiers
        }
        menu.addItem(mi)
    }
}

/// NSMenuItem can't be subclassed cleanly under main-actor isolation, so items carry their closure in a box.
final class ActionBox: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}

final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()
    @objc func run(_ sender: NSMenuItem) { (sender.representedObject as? ActionBox)?.handler() }
}
