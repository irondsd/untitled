import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let n = CGFloat(pixels)
        let page = NSBezierPath()
        page.move(to: NSPoint(x: n * 0.22, y: n * 0.07))
        page.line(to: NSPoint(x: n * 0.78, y: n * 0.07))
        page.curve(to: NSPoint(x: n * 0.84, y: n * 0.13),
            controlPoint1: NSPoint(x: n * 0.82, y: n * 0.07),
            controlPoint2: NSPoint(x: n * 0.84, y: n * 0.09))
        page.line(to: NSPoint(x: n * 0.84, y: n * 0.72))
        page.line(to: NSPoint(x: n * 0.63, y: n * 0.93))
        page.line(to: NSPoint(x: n * 0.22, y: n * 0.93))
        page.curve(to: NSPoint(x: n * 0.16, y: n * 0.87),
            controlPoint1: NSPoint(x: n * 0.18, y: n * 0.93),
            controlPoint2: NSPoint(x: n * 0.16, y: n * 0.91))
        page.line(to: NSPoint(x: n * 0.16, y: n * 0.13))
        page.curve(to: NSPoint(x: n * 0.22, y: n * 0.07),
            controlPoint1: NSPoint(x: n * 0.16, y: n * 0.09),
            controlPoint2: NSPoint(x: n * 0.18, y: n * 0.07))
        page.close()
        NSGradient(starting: NSColor(calibratedWhite: 0.99, alpha: 1),
            ending: NSColor(calibratedWhite: 0.80, alpha: 1))!.draw(in: page, angle: -90)
        NSColor(calibratedWhite: 0.35, alpha: 0.65).setStroke()
        page.lineWidth = max(0.6, n * 0.008)
        page.stroke()

        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: n * 0.63, y: n * 0.93))
        fold.line(to: NSPoint(x: n * 0.63, y: n * 0.77))
        fold.curve(to: NSPoint(x: n * 0.68, y: n * 0.72),
            controlPoint1: NSPoint(x: n * 0.63, y: n * 0.73),
            controlPoint2: NSPoint(x: n * 0.64, y: n * 0.72))
        fold.line(to: NSPoint(x: n * 0.84, y: n * 0.72))
        fold.close()
        NSColor(calibratedWhite: 0.70, alpha: 1).setFill()
        fold.fill()

        let font = NSFont.monospacedSystemFont(ofSize: n * 0.44, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)
        ]
        let title = "u" as NSString
        let measure = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (n - measure.width) / 2 - n * 0.06,
            y: (n - measure.height) / 2 - n * 0.04), withAttributes: attributes)
        NSColor(calibratedWhite: 0.40, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: n * 0.58, y: n * 0.26,
            width: n * 0.15, height: n * 0.04), xRadius: n * 0.008, yRadius: n * 0.008).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(size)x\(size)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
