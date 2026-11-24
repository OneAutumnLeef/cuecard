// NotchSpike: a teleprompter panel that grows out of the notch and highlights words at a fixed pace.
//
//   NotchSpike [--share none|readOnly] [--seconds 20] [--wpm 160] [--width 440] [--lines 3]
//              [--font 22] [--snapshot out.png] [--capture-test out.png] [--log out.txt]
//
// --snapshot renders the panel to a PNG (no permissions needed).
// --capture-test grabs the real screen with ScreenCaptureKit (what Zoom/OBS use) to see if the panel leaks.

import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Options & logging

struct Opts {
    var share = "none"
    var seconds: Double = 0
    var wpm: Double = 160
    var width: CGFloat = 440
    var lines = 3
    var fontSize: CGFloat = 22
    var snapshot: String?
    var captureTest: String?
    var logPath: String?
    var script: String?

    static func parse() -> Opts {
        var o = Opts()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--share": o.share = it.next() ?? "none"
            case "--seconds": o.seconds = Double(it.next() ?? "") ?? 0
            case "--wpm": o.wpm = Double(it.next() ?? "") ?? 160
            case "--width": o.width = CGFloat(Double(it.next() ?? "") ?? 440)
            case "--lines": o.lines = Int(it.next() ?? "") ?? 3
            case "--font": o.fontSize = CGFloat(Double(it.next() ?? "") ?? 22)
            case "--snapshot": o.snapshot = it.next()
            case "--capture-test": o.captureTest = it.next()
            case "--log": o.logPath = it.next()
            case "--script": o.script = it.next()
            default: break
            }
        }
        return o
    }
}

enum Log {
    nonisolated(unsafe) static var handle: FileHandle?
    static func line(_ s: String) {
        print(s); fflush(stdout)
        if let h = handle, let d = (s + "\n").data(using: .utf8) { h.write(d) }
    }
}

let defaultScript = """
Hi everyone, and thanks for joining today. Over the next few minutes I want to walk you through three ideas \
that changed how our team works. First, we stopped measuring hours and started measuring outcomes. That sounds \
simple, but it forced every person to explain what they were actually trying to achieve. Second, we moved our \
planning from once a quarter to every two weeks. Plans got smaller, and we finally learned to say no.
"""

// MARK: - Geometry

struct Geometry {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let panelWidth: CGFloat
    let lineHeight: CGFloat
    let visibleLines: Int
    let hPad: CGFloat = 20
    let topGap: CGFloat = 6
    let bottomPad: CGFloat = 14
    var textWidth: CGFloat { panelWidth - 2 * hPad - 16 }
    var panelHeight: CGFloat { notchHeight + topGap + lineHeight * CGFloat(visibleLines) + bottomPad }
}

// MARK: - State

@Observable
final class PrompterState {
    let words: [String]
    var lines: [[Int]] = []
    var lineOfWord: [Int] = []
    var cursor: Double = -1      // fractional word index; -1 = not started
    var expanded = false

    init(text: String) {
        words = text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var currentWord: Int { Int(cursor.rounded(.down)) }
    var currentLine: Int { lineOfWord.isEmpty ? 0 : lineOfWord[max(0, min(currentWord, lineOfWord.count - 1))] }

    /// Greedy word wrap using the same font SwiftUI will draw with.
    func wrap(font: NSFont, maxWidth: CGFloat, spacing: CGFloat) {
        var result: [[Int]] = [[]]
        var width: CGFloat = 0
        for (i, w) in words.enumerated() {
            let ww = (w as NSString).size(withAttributes: [.font: font]).width
            let needed = result[result.count - 1].isEmpty ? ww : width + spacing + ww
            if needed > maxWidth, !result[result.count - 1].isEmpty {
                result.append([i]); width = ww
            } else {
                result[result.count - 1].append(i); width = needed
            }
        }
        lines = result
        lineOfWord = Array(repeating: 0, count: words.count)
        for (li, line) in lines.enumerated() { for wi in line { lineOfWord[wi] = li } }
    }
}

// MARK: - Island shape (flush with the top edge, concave top corners like the real notch)

struct IslandShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 20
    func path(in r: CGRect) -> Path {
        let t = min(topRadius, r.width / 4), b = min(bottomRadius, r.height / 2, r.width / 4)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - View

struct PrompterView: View {
    let state: PrompterState
    let g: Geometry
    let fontSize: CGFloat
    let spacing: CGFloat

    private let spoken = Color.white.opacity(0.32)
    private let upcoming = Color.white
    private let current = Color(red: 1.0, green: 0.80, blue: 0.25)

    var body: some View {
        let w = state.expanded ? g.panelWidth : g.notchWidth
        let h = state.expanded ? g.panelHeight : g.notchHeight
        ZStack(alignment: .top) {
            IslandShape().fill(Color.black).frame(width: w, height: h)
            if state.expanded {
                text
                    .frame(width: g.textWidth, height: g.lineHeight * CGFloat(g.visibleLines), alignment: .top)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.62),
                                                 .init(color: .black.opacity(0.25), location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(.top, g.notchHeight + g.topGap)
                    .transition(.opacity)
            }
        }
        .frame(width: g.panelWidth, height: g.panelHeight, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: state.expanded)
    }

    private var text: some View {
        VStack(spacing: 0) {
            ForEach(state.lines.indices, id: \.self) { li in
                HStack(spacing: spacing) {
                    ForEach(state.lines[li], id: \.self) { wi in
                        Text(state.words[wi]).foregroundStyle(color(wi))
                    }
                }
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .frame(width: g.textWidth, height: g.lineHeight)
            }
        }
        .offset(y: -CGFloat(state.currentLine) * g.lineHeight)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: state.currentLine)
        .animation(.easeOut(duration: 0.12), value: state.currentWord)
    }

    private func color(_ wi: Int) -> Color {
        wi < state.currentWord ? spoken : (wi == state.currentWord ? current : upcoming)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let opts = Opts.parse()
    var panel: NSPanel!
    var state: PrompterState!
    var geometry: Geometry!
    var screen: NSScreen!
    var timer: Timer?
    var spacing: CGFloat = 6

    func applicationDidFinishLaunching(_ note: Notification) {
        if let p = opts.logPath { FileManager.default.createFile(atPath: p, contents: nil); Log.handle = FileHandle(forWritingAtPath: p) }
        screen = NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main!
        let f = screen.frame
        var notchW: CGFloat = 180, notchH = NSStatusBar.system.thickness + 2
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notchW = f.width - l.width - r.width
            notchH = screen.safeAreaInsets.top
        }
        let font = NSFont.systemFont(ofSize: opts.fontSize, weight: .semibold)
        spacing = (" " as NSString).size(withAttributes: [.font: font]).width
        geometry = Geometry(notchWidth: notchW, notchHeight: notchH, panelWidth: max(opts.width, notchW + 40),
                            lineHeight: (opts.fontSize * 1.38).rounded(), visibleLines: opts.lines)
        let text = opts.script.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? defaultScript
        state = PrompterState(text: text)
        state.wrap(font: font, maxWidth: geometry.textWidth - 4, spacing: spacing)

        let rect = NSRect(x: f.midX - geometry.panelWidth / 2, y: f.maxY - geometry.panelHeight,
                          width: geometry.panelWidth, height: geometry.panelHeight)
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.sharingType = opts.share == "readOnly" ? .readOnly : .none
        let host = NSHostingView(rootView: makeView())
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()

        Log.line("Screen \(screen.localizedName) \(f.size), notch \(notchW)×\(notchH) pt")
        Log.line("Panel \(rect), level \(panel.level.rawValue), sharingType \(opts.share), \(state.words.count) words in \(state.lines.count) lines")

        after(0.35) { self.state.expanded = true }
        after(1.0) { self.startTicking() }
        if let p = opts.snapshot { after(3.0) { self.snapshot(to: p) } }
        if let p = opts.captureTest { after(3.2) { Task { await self.captureTest(to: p) } } }
        if opts.seconds > 0 {
            after(opts.seconds) {
                self.state.expanded = false
                self.after(0.6) { NSApp.terminate(nil) }
            }
        }
    }

    func makeView() -> PrompterView {
        PrompterView(state: state, g: geometry, fontSize: opts.fontSize, spacing: spacing)
    }

    func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

    func startTicking() {
        state.cursor = 0
        var last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date(); let dt = now.timeIntervalSince(last); last = now
            let next = self.state.cursor + dt * self.opts.wpm / 60.0
            self.state.cursor = next >= Double(self.state.words.count) ? 0 : next   // loop for the demo
        }
    }

    // Renders the SwiftUI view on a light "menu bar" backdrop. No permissions needed.
    @MainActor func snapshot(to path: String) {
        let view = makeView().background(Color(white: 0.86))
        let r = ImageRenderer(content: view)
        r.scale = screen.backingScaleFactor
        guard let cg = r.cgImage else { Log.line("snapshot failed"); return }
        write(cg, to: path)
        Log.line("Snapshot written to \(path) (word \(state.currentWord), line \(state.currentLine))")
    }

    // Grabs the real screen through ScreenCaptureKit, like Zoom / Meet / OBS do.
    @MainActor func captureTest(to path: String) async {
        let myID = CGWindowID(panel.windowNumber)
        if let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], myID) as? [[String: Any]], let w = info.first {
            Log.line("Window server sharing state: \(w[kCGWindowSharingState as String] ?? "?") (0 = none, 1 = readOnly)")
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let listed = content.windows.contains { $0.windowID == myID }
            Log.line("Panel listed in SCShareableContent.windows: \(listed)")
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                Log.line("No display found"); return
            }
            let scale = screen.backingScaleFactor
            let cfg = SCStreamConfiguration()
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let pf = panel.frame, sf = screen.frame
            let crop = CGRect(x: (pf.minX - sf.minX - 40) * scale, y: (sf.maxY - pf.maxY) * scale,
                              width: (pf.width + 80) * scale, height: (pf.height + 30) * scale)
            guard let cut = img.cropping(to: crop) else { Log.line("crop failed"); return }
            write(cut, to: path)
            // Text area: if the panel was captured it is mostly pure black.
            let textArea = CGRect(x: (pf.minX - sf.minX + 30) * scale, y: (sf.maxY - pf.maxY + geometry.notchHeight + 8) * scale,
                                  width: (pf.width - 60) * scale, height: (pf.height - geometry.notchHeight - 16) * scale)
            if let t = img.cropping(to: textArea) {
                Log.line(String(format: "Pure-black share of the panel's text area in the capture: %.0f%%", 100 * blackFraction(t)))
            }
            Log.line("Capture written to \(path)")
        } catch {
            Log.line("Capture failed: \(error.localizedDescription)")
        }
    }

    func blackFraction(_ img: CGImage) -> Double {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var black = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] < 12 && px[i + 1] < 12 && px[i + 2] < 12 { black += 1 }
        return Double(black) / Double(w * h)
    }

    func write(_ cg: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
