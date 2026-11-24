import Foundation

/// An sRGB colour that can be saved to JSON.
public struct RGBA: Codable, Equatable, Sendable {
    public var r, g, b, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// `#RRGGBB` or `#RRGGBBAA`.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        } else {
            self.init(Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255,
                      Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
    public static let amber = RGBA(1.0, 0.80, 0.25)
    public static let sky = RGBA(0.50, 0.72, 1.0)
}

public enum FontWeightOption: String, Codable, CaseIterable, Sendable { case regular, medium, semibold, bold, heavy }
public enum FontDesignOption: String, Codable, CaseIterable, Sendable { case standard, rounded, serif, monospaced }
public enum HighlightStyle: String, Codable, CaseIterable, Sendable { case color, pill, underline }
public enum TextAlignmentOption: String, Codable, CaseIterable, Sendable { case center, leading }
/// Follow the speaker's voice, or scroll at a fixed words-per-minute pace.
public enum ScrollMode: String, Codable, CaseIterable, Sendable { case voice, fixed }
/// Hang from the notch (or the top of a screen without one), or float anywhere as a movable panel.
public enum DisplayMode: String, Codable, CaseIterable, Sendable { case notch, floating }

/// Everything the user can customise. Missing keys in a saved file fall back to defaults,
/// so adding settings later never breaks an existing file.
public struct PrompterSettings: Codable, Equatable, Sendable {
    // Panel
    public var panelWidth = 440.0
    public var visibleLines = 3
    // Text
    public var fontSize = 22.0
    public var fontWeight = FontWeightOption.semibold
    public var fontDesign = FontDesignOption.standard
    public var lineSpacing = 1.38
    public var alignment = TextAlignmentOption.center
    // Colours
    public var textColor = RGBA.white
    public var highlightColor = RGBA.amber
    public var highlightStyle = HighlightStyle.color
    public var spokenOpacity = 0.32
    public var cueColor = RGBA.sky
    public var backgroundColor = RGBA.black
    public var backgroundOpacity = 1.0
    // Playback
    public var scrollMode = ScrollMode.voice
    public var wpm = 150.0
    public var countdownSeconds = 3
    // Voice
    /// BCP-47 code such as "en-IN"; empty means "use the Mac's language".
    public var speechLocale = ""
    /// Core Audio device UID; empty means the system default input.
    public var microphoneUID = ""
    // Display
    public var displayMode = DisplayMode.notch
    /// The screen to use, by name; empty means the built-in screen with a notch (or the main screen).
    public var screenName = ""
    /// Flip text horizontally for beam-splitter teleprompter glass.
    public var mirror = false
    /// Where the floating panel was last left (its top-left corner, in screen points).
    public var floatingX: Double?
    public var floatingY: Double?
    // Library
    public var currentScriptID = ""
    /// Open the rehearsal report automatically after reading a script to the end in voice mode.
    public var showReportOnFinish = true
    /// Private code in the phone remote's link.
    public var remoteToken = ""
    // Privacy
    public var hideFromScreenShare = true

    public init() {}

    public static let ranges = (
        panelWidth: 300.0...800.0, visibleLines: 1...6, fontSize: 14.0...44.0, lineSpacing: 1.1...1.8,
        spokenOpacity: 0.0...1.0, backgroundOpacity: 0.5...1.0, wpm: AutoScroller.minWPM...AutoScroller.maxWPM,
        countdownSeconds: 0...10
    )

    /// The same settings with every number pulled into its allowed range.
    public func clamped() -> PrompterSettings {
        var s = self
        let r = Self.ranges
        s.panelWidth = s.panelWidth.clamped(to: r.panelWidth)
        s.visibleLines = s.visibleLines.clamped(to: r.visibleLines)
        s.fontSize = s.fontSize.clamped(to: r.fontSize)
        s.lineSpacing = s.lineSpacing.clamped(to: r.lineSpacing)
        s.spokenOpacity = s.spokenOpacity.clamped(to: r.spokenOpacity)
        s.backgroundOpacity = s.backgroundOpacity.clamped(to: r.backgroundOpacity)
        s.wpm = s.wpm.clamped(to: r.wpm)
        s.countdownSeconds = s.countdownSeconds.clamped(to: r.countdownSeconds)
        return s
    }

    enum CodingKeys: String, CodingKey {
        case panelWidth, visibleLines, fontSize, fontWeight, fontDesign, lineSpacing, alignment
        case textColor, highlightColor, highlightStyle, spokenOpacity, cueColor, backgroundColor, backgroundOpacity
        case scrollMode, wpm, countdownSeconds, speechLocale, microphoneUID, hideFromScreenShare
        case displayMode, screenName, mirror, floatingX, floatingY, currentScriptID, showReportOnFinish, remoteToken
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrompterSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        panelWidth = v(.panelWidth, d.panelWidth)
        visibleLines = v(.visibleLines, d.visibleLines)
        fontSize = v(.fontSize, d.fontSize)
        fontWeight = v(.fontWeight, d.fontWeight)
        fontDesign = v(.fontDesign, d.fontDesign)
        lineSpacing = v(.lineSpacing, d.lineSpacing)
        alignment = v(.alignment, d.alignment)
        textColor = v(.textColor, d.textColor)
        highlightColor = v(.highlightColor, d.highlightColor)
        highlightStyle = v(.highlightStyle, d.highlightStyle)
        spokenOpacity = v(.spokenOpacity, d.spokenOpacity)
        cueColor = v(.cueColor, d.cueColor)
        backgroundColor = v(.backgroundColor, d.backgroundColor)
        backgroundOpacity = v(.backgroundOpacity, d.backgroundOpacity)
        scrollMode = v(.scrollMode, d.scrollMode)
        wpm = v(.wpm, d.wpm)
        countdownSeconds = v(.countdownSeconds, d.countdownSeconds)
        speechLocale = v(.speechLocale, d.speechLocale)
        microphoneUID = v(.microphoneUID, d.microphoneUID)
        hideFromScreenShare = v(.hideFromScreenShare, d.hideFromScreenShare)
        displayMode = v(.displayMode, d.displayMode)
        screenName = v(.screenName, d.screenName)
        mirror = v(.mirror, d.mirror)
        floatingX = (try? c.decodeIfPresent(Double.self, forKey: .floatingX)) ?? nil
        floatingY = (try? c.decodeIfPresent(Double.self, forKey: .floatingY)) ?? nil
        currentScriptID = v(.currentScriptID, d.currentScriptID)
        showReportOnFinish = v(.showReportOnFinish, d.showReportOnFinish)
        remoteToken = v(.remoteToken, d.remoteToken)
        self = clamped()
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
