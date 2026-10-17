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
        let shape = NSBezierPath(roundedRect: NSRect(x: n * 0.08, y: n * 0.08, width: n * 0.84, height: n * 0.84), xRadius: n * 0.19, yRadius: n * 0.19)
        NSGradient(starting: NSColor(calibratedWhite: 0.24, alpha: 1), ending: NSColor(calibratedWhite: 0.09, alpha: 1))!.draw(in: shape, angle: -90)
        NSColor(calibratedWhite: 1, alpha: 0.13).setStroke()
        shape.lineWidth = max(1, n * 0.006)
        shape.stroke()
        let font = NSFont.monospacedSystemFont(ofSize: n * 0.50, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1)]
        let title = "u" as NSString
        let measure = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (n - measure.width) / 2 - n * 0.065, y: (n - measure.height) / 2 + n * 0.025), withAttributes: attributes)
        NSColor(calibratedWhite: 0.70, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: n * 0.59, y: n * 0.29, width: n * 0.17, height: n * 0.045), xRadius: n * 0.01, yRadius: n * 0.01).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(size)x\(size)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
