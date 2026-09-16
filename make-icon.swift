import AppKit

// Two cut glass faces joined into one Korean/English badge.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let outline = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840), xRadius: 190, yRadius: 190)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
        shadow.shadowBlurRadius = 20; shadow.shadowOffset = NSSize(width: 0, height: -8); shadow.set()
        NSColor.white.setFill(); outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSGradient(colors: [NSColor(white: 0.955, alpha: 1), .white])!.draw(in: outline, angle: 90)
        // One shared 10-degree cut clips both backgrounds and both full glyphs.
        func half(_ left: Bool) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 422, y: 0))
            path.line(to: NSPoint(x: 602, y: 1024))
            path.line(to: NSPoint(x: left ? 0 : 1024, y: 1024))
            path.line(to: NSPoint(x: left ? 0 : 1024, y: 0))
            path.close()
            return path
        }
        // A separate rounded badge, not just the rounded app-icon silhouette.
        let badge = NSBezierPath(roundedRect: NSRect(x: 208, y: 244, width: 608, height: 536), xRadius: 86, yRadius: 86)
        NSColor(white: 1, alpha: 0.45).setFill(); badge.fill()
        NSGraphicsContext.saveGraphicsState()
        badge.addClip()
        half(true).addClip()
        NSColor(white: 0.85, alpha: 0.60).setFill(); badge.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Shift each label slightly away from the shared cut for legibility.
        // Left half of 한 + right half of dud meet flush at the same cut edge.
        for (label, fontSize, left) in [("한", CGFloat(338), true), ("dud", CGFloat(222), false)] {
            NSGraphicsContext.saveGraphicsState()
            half(left).addClip()
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor(white: 0.19, alpha: 0.92)
            ])
            let size = text.size()
            let centerX: CGFloat = left ? 446 : 578
            text.draw(at: NSPoint(x: centerX - size.width / 2, y: (1024 - size.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor(white: 0.24, alpha: 0.60).setStroke(); badge.lineWidth = 9; badge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setStroke(); outline.lineWidth = 3; outline.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to:
            destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
