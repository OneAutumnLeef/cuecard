import AppKit
import AVFoundation
import PrompterSpeech
import SwiftUI

/// First-run guide (also under "Welcome & Shortcuts…" in the menu): what the app does,
/// microphone permission, and the shortcuts worth remembering.
final class WelcomeWindowController: NSObject {
    private var window: NSWindow?
    private let model: AppModel
    private let onTry: () -> Void
    private let onEditor: () -> Void

    init(model: AppModel, onTry: @escaping () -> Void, onEditor: @escaping () -> Void) {
        self.model = model
        self.onTry = onTry
        self.onEditor = onEditor
    }

    var nsWindow: NSWindow? { window }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "Welcome"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WelcomeView(
                model: model,
                onTry: { [weak self] in self?.window?.close(); self?.onTry() },
                onEditor: { [weak self] in self?.window?.close(); self?.onEditor() }))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    let model: AppModel
    let onTry: () -> Void
    let onEditor: () -> Void
    @State private var mic = SpeechListener.microphoneStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notch Prompter").font(.largeTitle.weight(.bold))
                Text("Your script, right under the camera. It follows your voice.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            row("rectangle.topthird.inset.filled", "Lives in the notch",
                "⌃⌥Space starts and pauses from anywhere. Hover over it for controls; right-click it for the full menu.")
            VStack(alignment: .leading, spacing: 8) {
                row("waveform", "Follows your voice",
                    "Speed up, slow down, pause, skip or go back: it keeps your place. Speech is recognised on this Mac only.")
                HStack {
                    Spacer().frame(width: 40)
                    MicAccessRow(status: $mic)
                }
            }
            row("doc.text", "Your scripts",
                "⌃⌥E opens the editor. Import Word, PDF, Markdown or text. [PAUSE] holds a moment; [anything] is a stage note.")
            row("eye.slash", "Hidden from screen sharing",
                "Zoom, Meet and recordings don't see it (switch this off in Settings if you want them to).")

            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Shortcut.all, id: \.name) { item in
                    GridRow {
                        Text(item.shortcut.display).monospaced().foregroundStyle(.secondary)
                        Text(item.name)
                    }
                }
            }
            .font(.callout)

            HStack {
                Button("Open Script Editor", action: onEditor)
                Spacer()
                Button("Try It Now", action: onTry)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 520)
        .onAppear { mic = SpeechListener.microphoneStatus }
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
