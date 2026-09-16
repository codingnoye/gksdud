import AppKit

// Approved vector geometry: design/dud-icons/v5/dud-balanced.svg.
// Draw at each target resolution so small icons do not depend on raster resizing.
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
        context.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)
        // Use the SVG's top-left coordinate system.
        context.translateBy(x: 0, y: 512)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(NSColor(srgbRed: 248 / 255, green: 245 / 255,
            blue: 239 / 255, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 32, y: 32, width: 448, height: 448),
            cornerWidth: 100, cornerHeight: 100, transform: nil))
        context.fillPath()
        context.setStrokeColor(NSColor(srgbRed: 45 / 255, green: 45 / 255,
            blue: 43 / 255, alpha: 1).cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(18)
        for centerX: CGFloat in [157.6, 354.4] {
            let eye = CGMutablePath()
            eye.move(to: CGPoint(x: centerX + 48, y: 185.8))
            eye.addLine(to: CGPoint(x: centerX + 48, y: 272.2))
            eye.addArc(center: CGPoint(x: centerX, y: 272.2), radius: 48,
                startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            context.addPath(eye)
            context.strokePath()
        }
        let mouth = CGMutablePath()
        mouth.move(to: CGPoint(x: 232, y: 285.4))
        mouth.addLine(to: CGPoint(x: 232, y: 302.2))
        mouth.addArc(center: CGPoint(x: 256, y: 302.2), radius: 24,
            startAngle: .pi, endAngle: 0, clockwise: true)
        mouth.addLine(to: CGPoint(x: 280, y: 285.4))
        context.setLineWidth(16)
        context.addPath(mouth)
        context.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to:
            destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
