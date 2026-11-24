import Foundation

/// A named look: fonts, colours and layout. Applying one never touches behaviour
/// (scroll mode, speed, microphone, language, privacy, display placement).
public struct LookPreset: Identifiable, Sendable, Equatable {
    public let id: String
    public let summary: String
    let apply: @Sendable (inout PrompterSettings) -> Void

    public static func == (a: LookPreset, b: LookPreset) -> Bool { a.id == b.id }

    public func applied(to s: PrompterSettings) -> PrompterSettings {
        var out = s
        let d = PrompterSettings()
        // Start from the default look, then apply the preset, so presets don't depend on each other.
        out.panelWidth = d.panelWidth; out.visibleLines = d.visibleLines
        out.fontSize = d.fontSize; out.fontWeight = d.fontWeight; out.fontDesign = d.fontDesign
        out.lineSpacing = d.lineSpacing; out.alignment = d.alignment
        out.textColor = d.textColor; out.highlightColor = d.highlightColor; out.highlightStyle = d.highlightStyle
        out.spokenOpacity = d.spokenOpacity; out.cueColor = d.cueColor
        out.backgroundColor = d.backgroundColor; out.backgroundOpacity = d.backgroundOpacity
        apply(&out)
        return out.clamped()
    }

    /// True if the settings' look matches this preset exactly.
    public func matches(_ s: PrompterSettings) -> Bool {
        applied(to: s) == s
    }

    public static let all: [LookPreset] = [
        LookPreset(id: "Classic", summary: "White on black, amber word") { _ in },
        LookPreset(id: "High Contrast", summary: "Bigger, bold, yellow pill") { s in
            s.fontSize = 26; s.fontWeight = .bold
            s.highlightColor = RGBA(1, 0.86, 0.1); s.highlightStyle = .pill; s.spokenOpacity = 0.22
        },
        LookPreset(id: "Calm", summary: "Rounded, soft white, blue underline") { s in
            s.fontDesign = .rounded; s.fontWeight = .medium
            s.textColor = RGBA(0.91, 0.91, 0.93); s.highlightColor = RGBA(0.45, 0.72, 1)
            s.highlightStyle = .underline; s.spokenOpacity = 0.4
        },
        LookPreset(id: "Large", summary: "32 pt, two lines, wider") { s in
            s.fontSize = 32; s.fontWeight = .bold; s.visibleLines = 2; s.panelWidth = 580; s.lineSpacing = 1.3
        },
        LookPreset(id: "Serif Reader", summary: "New York serif, warm, left-aligned") { s in
            s.fontDesign = .serif; s.fontWeight = .regular; s.fontSize = 24; s.alignment = .leading
            s.textColor = RGBA(1, 0.96, 0.9); s.highlightColor = RGBA(1, 0.62, 0.27); s.panelWidth = 480
        },
    ]
}
