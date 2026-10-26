import AppKit

@main enum SpyIconGenerator {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            try drawIcon(size: size, name: "icon_\(size)x\(size).png", folder: folder)
            try drawIcon(size: size * 2, name: "icon_\(size)x\(size)@2x.png", folder: folder)
        }
    }
    static func drawIcon(size: Int, name: String, folder: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        let background = NSBezierPath(roundedRect: CGRect(x: 50, y: 50, width: 924, height: 924), xRadius: 212, yRadius: 212)
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.135, alpha: 1).setFill(); background.fill()
        NSColor(white: 0.3, alpha: 0.6).setStroke(); background.lineWidth = 3; background.stroke()
        // Keep the shared top-down glyph upright in the bitmap context.
        context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
        context.addPath(SpiderGlyph.path(in: CGRect(x: 150, y: 145, width: 724, height: 724)))
        context.setFillColor(SpiderGlyph.accentCGColor)
        context.fillPath()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
