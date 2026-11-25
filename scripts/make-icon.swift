// Renders Support/AppIcon.icns.  Usage: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824 pt body centred on a 1024 canvas.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Night sky fading into a warm horizon.
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.07, green: 0.08, blue: 0.24, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.20, green: 0.15, blue: 0.42, alpha: 1), 0.45),
        (NSColor(srgbRed: 0.86, green: 0.38, blue: 0.27, alpha: 1), 0.82),
        (NSColor(srgbRed: 1.00, green: 0.66, blue: 0.30, alpha: 1), 1.0)
    )!.draw(in: body, angle: -90)

    // A few stars.
    NSColor.white.withAlphaComponent(0.85).setFill()
    for (x, y, r) in [(300.0, 760.0, 9.0), (420, 840, 6), (690, 820, 7), (780, 700, 5), (250, 600, 5), (560, 880, 4)] {
        NSBezierPath(ovalIn: NSRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)).fill()
    }

    // Crescent moon: a disc, clipped to everything outside an offset disc.
    let moon = NSBezierPath(ovalIn: NSRect(x: 330 * s, y: 330 * s, width: 380 * s, height: 380 * s))
    let outsideBite = NSBezierPath(rect: body)
    outsideBite.appendOval(in: NSRect(x: 450 * s, y: 410 * s, width: 340 * s, height: 340 * s))
    outsideBite.windingRule = .evenOdd
    outsideBite.addClip()
    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 1, green: 0.8, blue: 0.5, alpha: 0.8)
    glow.shadowBlurRadius = 40 * s
    glow.set()
    NSColor(srgbRed: 1.0, green: 0.93, blue: 0.80, alpha: 1).setFill()
    moon.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
try render(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("docs/icon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Support/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Support/AppIcon.icns and docs/icon.png" : "iconutil failed")
