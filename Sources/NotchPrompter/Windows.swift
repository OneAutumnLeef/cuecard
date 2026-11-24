import AppKit
import AVFoundation
import PDFKit
import PrompterSpeech
import PrompterCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Script editor

final class EditorWindowController: NSObject {
    private var window: NSWindow?
    private let model: AppModel
    private let onStart: () -> Void

    init(model: AppModel, onStart: @escaping () -> Void) {
        self.model = model
        self.onStart = onStart
    }

    var nsWindow: NSWindow? { window }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Scripts"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: EditorView(model: model, onStart: onStart,
                                                               onImport: { [weak self] in self?.openFile() }))
            w.center()
            w.setFrameAutosaveName("ScriptEditor2")
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Imports a file as a new script in the library.
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ScriptImporter.types
        panel.allowsMultipleSelection = false
        panel.message = "Choose a script: text, Markdown, Word, RTF or PDF"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try ScriptImporter.read(url)
            model.importScript(title: url.deletingPathExtension().lastPathComponent, text: text)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

enum ScriptImporter {
    static var types: [UTType] {
        [.plainText, .text, .rtf, .rtfd, .pdf] + ["md", "markdown", "docx", "doc", "odt", "pptx"].compactMap { UTType(filenameExtension: $0) }
    }

    static func read(_ url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ["txt", "md", "markdown", "text", ""].contains(ext) {
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
            var enc = String.Encoding.utf8
            return try String(contentsOf: url, usedEncoding: &enc)
        }
        if ext == "pptx" { return try speakerNotes(url) }
        if ext == "pdf" {
            guard let s = PDFDocument(url: url)?.string else { throw CocoaError(.fileReadCorruptFile) }
            return s
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
    }

    /// PowerPoint: unzip to a temporary folder and read the speaker notes, slide by slide.
    static func speakerNotes(_ url: URL) throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pptx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", url.path, tmp.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        let notes = try PptxNotes.extract(fromUnzipped: tmp)
        guard !notes.isEmpty else {
            throw NSError(domain: "NotchPrompter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This presentation has no speaker notes to import."])
        }
        return notes
    }
}

struct EditorView: View {
    @Bindable var model: AppModel
    let onStart: () -> Void
    let onImport: () -> Void
    @State private var title = ""
    @State private var confirmDelete: String?
    @State private var rewriteStyle: RewriteStyle?
    @State private var aiStatus = ScriptRewriter.availability

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.currentScriptID },
                                    set: { if let id = $0 { model.selectScript(id) } })) {
                ForEach(model.scripts) { info in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title).lineLimit(1)
                        Text(info.modified, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(info.id)
                    .contextMenu {
                        Button("Move to Trash", role: .destructive) { confirmDelete = info.id }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
            .toolbar {
                ToolbarItemGroup {
                    Button { model.newScript() } label: { Label("New Script", systemImage: "square.and.pencil") }
                        .help("New script")
                    Button(action: onImport) { Label("Import", systemImage: "square.and.arrow.down") }
                        .help("Import a text, Markdown, Word, RTF, PDF or PowerPoint (speaker notes) file")
                }
            }
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .onSubmit { model.renameCurrentScript(to: title) }
                    Menu {
                        ForEach(RewriteStyle.allCases) { style in
                            Button(style.rawValue) { rewriteStyle = style }
                        }
                        Divider()
                        Text(aiStatus.message)
                    } label: {
                        Label("Rewrite", systemImage: "wand.and.stars")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!aiStatus.ready || model.script.isEmpty)
                    .help(aiStatus.ready ? "Rewrite this script with Apple Intelligence (on this Mac)" : aiStatus.message)
                    .onHover { _ in aiStatus = ScriptRewriter.availability }
                    Button { confirmDelete = model.currentScriptID } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Move this script to the Trash")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                TextEditor(text: $model.scriptText)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.script.wordCount) words · about \(formatClock(model.estimatedSeconds)) at \(Int(model.settings.wpm)) wpm")
                        Text("⌃⌥Space start / pause · ⌃⌥V voice or fixed · hover the prompter for controls")
                            .foregroundStyle(.secondary)
                        Text("[PAUSE] holds a moment · [any note] is a stage note")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    Spacer()
                    Button("Start Prompter", action: onStart)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .onAppear { title = model.currentScriptID; aiStatus = ScriptRewriter.availability }
        .sheet(item: $rewriteStyle) { style in
            RewriteSheet(model: model, style: style) { rewriteStyle = nil }
        }
        .onChange(of: model.currentScriptID) { _, new in title = new }
        .confirmationDialog("Move “\(confirmDelete ?? "")” to the Trash?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let id = confirmDelete { model.deleteScript(id) }
                confirmDelete = nil
            }
        } message: {
            Text("You can get it back from the Trash in Finder.")
        }
    }
}

// MARK: - Settings

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    init(model: AppModel) { self.model = model }

    var nsWindow: NSWindow? { window }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Notch Prompter Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("Settings")
            window = w
        }
        onOpen?()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var devices: [AudioInputDevice] = []
    @State private var locales: [String] = []
    @State private var micStatus = SpeechListener.microphoneStatus
    @State private var screens: [String] = []
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    var body: some View {
        Form {
            Section {
                Picker("Scrolling", selection: $model.settings.scrollMode) {
                    Text("Follow my voice").tag(ScrollMode.voice)
                    Text("Fixed speed").tag(ScrollMode.fixed)
                }
                .pickerStyle(.segmented)
                if model.isVoiceMode {
                    Picker("Microphone", selection: $model.settings.microphoneUID) {
                        Text("System default").tag("")
                        ForEach(devices) { Text($0.name).tag($0.uid) }
                    }
                    Picker("Language", selection: $model.settings.speechLocale) {
                        Text("Automatic (\(localeName(model.resolvedLocale.identifier(.bcp47))))").tag("")
                        ForEach(locales, id: \.self) { Text(localeName($0)).tag($0) }
                    }
                    MicAccessRow(status: $micStatus)
                    Toggle("Show a rehearsal report when I finish", isOn: $model.settings.showReportOnFinish)
                }
            } header: {
                Text("Voice")
            } footer: {
                Text(model.isVoiceMode
                     ? "Recognition runs on this Mac; nothing is sent anywhere. The mic in the notch turns green while it's following you."
                     : "Scrolls at the speed below. ⌃⌥V switches to following your voice.")
                    .foregroundStyle(.secondary)
            }
            .task {
                devices = AudioInputDevice.all()
                screens = NSScreen.screens.map(\.localizedName)
                micStatus = SpeechListener.microphoneStatus
                locales = await SpeechListener.availableLocales().installed.map { $0.identifier(.bcp47) }.sorted()
            }
            Section("Display") {
                Picker("Placement", selection: $model.settings.displayMode) {
                    Text("In the notch").tag(DisplayMode.notch)
                    Text("Floating").tag(DisplayMode.floating)
                }
                .pickerStyle(.segmented)
                Picker("Screen", selection: $model.settings.screenName) {
                    Text("Automatic (built-in)").tag("")
                    ForEach(screens, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Mirror text (for teleprompter glass)", isOn: $model.settings.mirror)
                if model.settings.displayMode == .floating {
                    LabeledContent("Position") {
                        Button("Reset") { model.settings.floatingX = nil; model.settings.floatingY = nil }
                    }
                }
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                    ForEach(LookPreset.all) { preset in
                        PresetButton(preset: preset, selected: preset.matches(model.settings)) {
                            model.settings = preset.applied(to: model.settings)
                        }
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Looks")
            } footer: {
                Text("A starting point: fine-tune anything below. Looks never change your speed, voice or display settings.")
                    .foregroundStyle(.secondary)
            }
            Section("Text") {
                SliderRow(title: "Size", value: $model.settings.fontSize, range: 14...44, step: 1) { "\(Int($0)) pt" }
                Picker("Weight", selection: $model.settings.fontWeight) {
                    ForEach(FontWeightOption.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Typeface", selection: $model.settings.fontDesign) {
                    Text("System").tag(FontDesignOption.standard)
                    Text("Rounded").tag(FontDesignOption.rounded)
                    Text("Serif").tag(FontDesignOption.serif)
                    Text("Monospaced").tag(FontDesignOption.monospaced)
                }
                SliderRow(title: "Line spacing", value: $model.settings.lineSpacing, range: 1.1...1.8, step: 0.02) {
                    String(format: "%.2f×", $0)
                }
                Picker("Alignment", selection: $model.settings.alignment) {
                    Text("Centre").tag(TextAlignmentOption.center)
                    Text("Left").tag(TextAlignmentOption.leading)
                }
                .pickerStyle(.segmented)
            }
            Section("Panel") {
                SliderRow(title: "Width", value: $model.settings.panelWidth, range: 300...800, step: 10) { "\(Int($0)) pt" }
                Stepper("Visible lines: \(model.settings.visibleLines)", value: $model.settings.visibleLines, in: 1...6)
            }
            Section("Colours") {
                ColorPicker("Text", selection: color(\.textColor), supportsOpacity: false)
                ColorPicker("Highlight", selection: color(\.highlightColor), supportsOpacity: false)
                Picker("Highlight style", selection: $model.settings.highlightStyle) {
                    Text("Colour").tag(HighlightStyle.color)
                    Text("Pill").tag(HighlightStyle.pill)
                    Text("Underline").tag(HighlightStyle.underline)
                }
                .pickerStyle(.segmented)
                SliderRow(title: "Spoken words", value: $model.settings.spokenOpacity, range: 0...1, step: 0.02) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                ColorPicker("Stage notes", selection: color(\.cueColor), supportsOpacity: false)
                ColorPicker("Background", selection: color(\.backgroundColor), supportsOpacity: false)
                SliderRow(title: "Background opacity", value: $model.settings.backgroundOpacity, range: 0.5...1, step: 0.01) {
                    "\(Int(($0 * 100).rounded()))%"
                }
            }
            Section("Fixed speed") {
                SliderRow(title: "Speed", value: $model.settings.wpm, range: 40...300, step: 5) { "\(Int($0)) wpm" }
                Picker("Countdown", selection: $model.settings.countdownSeconds) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
            }
            Section {
                Toggle("Hide from screen sharing and recordings", isOn: $model.settings.hideFromScreenShare)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Zoom, Meet, OBS and screenshots won't show the prompter.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open Notch Prompter at login", isOn: Binding(get: { loginEnabled }, set: { setLogin($0) }))
                if let loginNote { Text(loginNote).font(.callout).foregroundStyle(.secondary) }
            } header: {
                Text("General")
            }
            Section("Shortcuts") {
                ForEach(Shortcut.all, id: \.name) { row in
                    LabeledContent(row.name) { Text(row.shortcut.display).monospaced() }
                }
            }
            HStack {
                Spacer()
                Button("Reset to Defaults") { model.settings = PrompterSettings() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginNote = nil
        } catch {
            loginNote = "macOS didn't allow it: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        if status == .requiresApproval {
            loginNote = "Approve Notch Prompter in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func localeName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    private func color(_ kp: WritableKeyPath<PrompterSettings, RGBA>) -> Binding<Color> {
        Binding(get: { model.settings[keyPath: kp].color },
                set: { model.settings[keyPath: kp] = RGBA(color: $0) })
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step).frame(minWidth: 170)
                Text(label(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
        }
    }
}

struct PresetButton: View {
    let preset: LookPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.id).font(.callout.weight(.semibold))
                Text(preset.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Microphone permission, with the right button for each state.
struct MicAccessRow: View {
    @Binding var status: AVAuthorizationStatus

    var body: some View {
        LabeledContent("Microphone access") {
            switch status {
            case .authorized:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined:
                Button("Allow…") {
                    Task {
                        _ = await SpeechListener.requestMicrophone()
                        status = SpeechListener.microphoneStatus
                    }
                }
            default:
                Button("Open Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
