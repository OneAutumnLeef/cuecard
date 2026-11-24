import AppKit
import PrompterCore
import SwiftUI

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(nsColor: nsColor) }

    init(color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
}

enum Fonts {
    /// The prompter font. The same NSFont is used to measure line breaks and to draw, so they always agree.
    static func prompter(_ s: PrompterSettings) -> NSFont {
        let weight: NSFont.Weight = switch s.fontWeight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
        let base = NSFont.systemFont(ofSize: s.fontSize, weight: weight)
        let design: NSFontDescriptor.SystemDesign? = switch s.fontDesign {
        case .standard: nil
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        if let design, let d = base.fontDescriptor.withDesign(design), let f = NSFont(descriptor: d, size: s.fontSize) {
            return f
        }
        return base
    }
}

func formatClock(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
