import AppKit

// Shared character geometry; cream artwork in the app, templates in the menu bar.
enum DudIcon {
    static func drawFace(in context: CGContext, korean: Bool = false) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(18)
        for centerX: CGFloat in [157.6, 354.4] {
            let eye = CGMutablePath()
            if korean {
                // Two horizontal strokes and a circle form each ㅎ eye.
                eye.move(to: CGPoint(x: centerX - 14, y: 190))
                eye.addLine(to: CGPoint(x: centerX + 14, y: 190))
                eye.move(to: CGPoint(x: centerX - 42, y: 218))
                eye.addLine(to: CGPoint(x: centerX + 42, y: 218))
                eye.addEllipse(in: CGRect(x: centerX - 38, y: 244.2, width: 76, height: 76))
            } else {
                eye.move(to: CGPoint(x: centerX + 48, y: 185.8))
                eye.addLine(to: CGPoint(x: centerX + 48, y: 272.2))
                eye.addArc(center: CGPoint(x: centerX, y: 272.2), radius: 48,
                    startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            }
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
    }

    static func drawAppIcon(in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: 512)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(NSColor(srgbRed: 248 / 255, green: 245 / 255, blue: 239 / 255, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 32, y: 32, width: 448, height: 448),
            cornerWidth: 100, cornerHeight: 100, transform: nil))
        context.fillPath()
        context.setStrokeColor(NSColor(srgbRed: 45 / 255, green: 45 / 255, blue: 43 / 255, alpha: 1).cgColor)
        drawFace(in: context)
        context.restoreGState()
    }

    static func badge(korean: Bool) -> NSImage {
        let filled = korean
        let image = NSImage(size: NSSize(width: 22, height: 20), flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 1.25), xRadius: 3, yRadius: 3)
            NSColor.black.set()
            if filled { shape.fill() } else { shape.lineWidth = 0.8; shape.stroke() }
            let face = NSImage(size: rect.size, flipped: false) { bounds in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.saveGState()
                context.translateBy(x: bounds.midX, y: bounds.midY)
                let scale: CGFloat = 16.5 / 310.8
                context.scaleBy(x: scale, y: -scale)
                context.translateBy(x: -256, y: -255.5)
                context.setStrokeColor(NSColor.black.cgColor)
                drawFace(in: context, korean: korean)
                context.restoreGState()
                return true
            }
            // Transparent cutout lets macOS tint the complete template in light/dark menus.
            face.draw(in: rect, from: .zero, operation: filled ? .destinationOut : .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }
}

// The build compiles this entry point only for the iconset generator.
#if ICON_GENERATOR
@main
struct IconGenerator {
    static func main() throws {
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
                DudIcon.drawAppIcon(in: context)
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                try bitmap.representation(using: .png, properties: [:])!.write(to:
                    destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }
    }
}
#endif
