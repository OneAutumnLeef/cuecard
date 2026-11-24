// Draws the app icon (a screen top with the island and highlighted text) and writes an .icns file.
//   swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Squircle-ish tile with a soft blue-violet gradient (the "screen").
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.42, blue: 0.95, alpha: 1),
                        NSColor(srgbRed: 0.55, green: 0.33, blue: 0.85, alpha: 1)])!.draw(in: tile, angle: -70)

    // The island hanging from the top edge.
    NSGraphicsContext.current?.saveGraphicsState()
    tile.addClip()
    let island = NSBezierPath(roundedRect: r(212, 520, 600, 420), xRadius: 90 * s, yRadius: 90 * s)
    NSColor.black.setFill()
    island.fill()
    NSBezierPath(rect: r(212, 760, 600, 200)).fill()
    // Text lines: spoken (dim), current word highlighted, upcoming (white).
    NSColor(white: 1, alpha: 0.35).setFill()
    NSBezierPath(roundedRect: r(280, 790, 300, 44), xRadius: 22 * s, yRadius: 22 * s).fill()
    NSColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(600, 790, 150, 44), xRadius: 22 * s, yRadius: 22 * s).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: r(280, 700, 470, 44), xRadius: 22 * s, yRadius: 22 * s).fill()
    NSColor(white: 1, alpha: 0.55).setFill()
    NSBezierPath(roundedRect: r(280, 610, 380, 44), xRadius: 22 * s, yRadius: 22 * s).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(base * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try! p.run()
p.waitUntilExit()
try? fm.removeItem(at: set)
print(p.terminationStatus == 0 ? "Wrote \(out)" : "iconutil failed")
