import FoundationModels
import PrompterCore
import SwiftUI

/// Rewrites a script with Apple's on-device language model (Apple Intelligence). Nothing leaves the Mac.
enum RewriteStyle: String, CaseIterable, Identifiable {
    case speakable = "Easier to Say"
    case shorter = "Shorter (about 20%)"
    case pauses = "Add Pauses"
    case numbers = "Spell Out Numbers and Symbols"

    var id: String { rawValue }

    var instructions: String {
        let keep = "Keep anything in square brackets, like [PAUSE] or [smile], exactly as it is. Keep line breaks. Reply with only the rewritten text, no introduction."
        switch self {
        case .speakable:
            return "You edit scripts read aloud from a teleprompter. Rewrite the text so it is easy to say: shorter sentences, plain words, natural spoken rhythm. Keep the meaning, names, facts and numbers. " + keep
        case .shorter:
            return "You edit scripts read aloud from a teleprompter. Make the text about 20% shorter while keeping every key point, name and number. " + keep
        case .pauses:
            return "You edit scripts read aloud from a teleprompter. Insert [PAUSE] at natural breathing points and before important points, about every two or three sentences. Do not change, add or remove any other words. " + keep
        case .numbers:
            return "You edit scripts read aloud from a teleprompter. Rewrite numbers, symbols, abbreviations and units the way they are spoken, for example 40% becomes forty percent, $5M becomes five million dollars, Q3 becomes Q three. Change nothing else. " + keep
        }
    }
}

enum ScriptRewriter {
    /// Whether the model can be used now, and if not, what to tell the user.
    static var availability: (ready: Bool, message: String) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, "Runs on this Mac with Apple Intelligence.")
        case .unavailable(.modelNotReady):
            return (false, "Apple Intelligence is still downloading its model. Try again a little later.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return (false, "Turn on Apple Intelligence in System Settings to use rewriting.")
        case .unavailable(.deviceNotEligible):
            return (false, "This Mac can't run Apple Intelligence.")
        case .unavailable:
            return (false, "Apple Intelligence isn't available right now.")
        }
    }

    /// Rewrites paragraph by paragraph (each in a fresh session, so long scripts never overflow the model's context).
    static func rewrite(_ text: String, style: RewriteStyle, progress: @escaping (Double) -> Void) async throws -> String {
        let paragraphs = text.components(separatedBy: "\n")
        let work = paragraphs.filter { !isSkippable($0) }.count
        var done = 0
        var out: [String] = []
        for p in paragraphs {
            if isSkippable(p) { out.append(p); continue }
            let session = LanguageModelSession(instructions: style.instructions)
            let reply = try await session.respond(to: p)
            out.append(reply.content.trimmingCharacters(in: .whitespacesAndNewlines))
            done += 1
            progress(Double(done) / Double(max(work, 1)))
        }
        return out.joined(separator: "\n")
    }

    /// Blank lines and lines that are only a stage note stay as they are.
    private static func isSkippable(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || (t.hasPrefix("[") && t.hasSuffix("]") && !t.dropFirst().contains("["))
    }
}

/// Shows the rewrite in progress, then a preview you can edit before replacing or saving as a new script.
struct RewriteSheet: View {
    let model: AppModel
    let style: RewriteStyle
    let onClose: () -> Void

    @State private var result = ""
    @State private var progress = 0.0
    @State private var error: String?
    @State private var running = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(style.rawValue).font(.title2.weight(.semibold))
            if running {
                ProgressView(value: progress) { Text("Rewriting on this Mac…") }
                Spacer()
            } else if let error {
                Text(error).foregroundStyle(.red)
                Spacer()
            } else {
                Text("Check and edit the result before using it.").foregroundStyle(.secondary)
                TextEditor(text: $result)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                Text("\(wordCount(model.scriptText)) words → \(wordCount(result)) words").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                if !running && error == nil {
                    Button("Save as New Script") {
                        model.importScript(title: "\(model.currentScriptID) (\(style.rawValue))", text: result)
                        onClose()
                    }
                    Button("Replace Script") {
                        model.scriptText = result
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .task {
            do {
                result = try await ScriptRewriter.rewrite(model.scriptText, style: style) { p in
                    Task { @MainActor in progress = p }
                }
            } catch {
                self.error = "Couldn't rewrite: \(error.localizedDescription)"
            }
            running = false
        }
    }

    private func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
}
