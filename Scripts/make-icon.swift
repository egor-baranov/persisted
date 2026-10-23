import AppKit
import Foundation

// Reproducible native vector drawing. No external image or font dependencies.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/Persisted.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 190, yRadius: 190)
        NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.35, alpha: 1).setFill(); tile.fill()
        let monitors = [NSRect(x: 156, y: 340, width: 315, height: 360), NSRect(x: 517, y: 340, width: 350, height: 360)]
        for rect in monitors {
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 23, yRadius: 23)
            border.lineWidth = 22; border.stroke()
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: rect.midX, y: rect.minY)); stand.line(to: NSPoint(x: rect.midX, y: 270))
            stand.move(to: NSPoint(x: rect.midX - 65, y: 270)); stand.line(to: NSPoint(x: rect.midX + 65, y: 270))
            stand.lineWidth = 22; stand.lineCapStyle = .round; stand.stroke()
        }
        NSColor(calibratedRed: 0.35, green: 0.75, blue: 0.95, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 188, y: 379, width: 115, height: 278), xRadius: 10, yRadius: 10).fill()
        NSColor(calibratedRed: 0.58, green: 0.84, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 324, y: 493, width: 111, height: 164), xRadius: 10, yRadius: 10).fill()
        NSBezierPath(roundedRect: NSRect(x: 554, y: 379, width: 275, height: 278), xRadius: 10, yRadius: 10).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
