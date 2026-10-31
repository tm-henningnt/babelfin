import AppKit

@main struct ExportMenuBarSymbol {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for scale in [1, 2] {
            for active in [false, true] {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28 * scale, pixelsHigh: 20 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                let glyph = MenuBarSymbol.make(active: active)
                glyph.isTemplate = false
                glyph.draw(in: NSRect(x: 0, y: 0, width: 28, height: 20))
                NSGraphicsContext.restoreGraphicsState()
                let name = "menubar-\(active ? "live" : "idle")\(scale == 2 ? "@2x" : "").png"
                try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
            }
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 180, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (index, dark) in [false, true].enumerated() {
            let x = CGFloat(index * 320)
            (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
            NSRect(x: x, y: 0, width: 320, height: 180).fill()
            let color: NSColor = dark ? .white : .black
            let glyph = MenuBarSymbol.make(active: false, tint: color)
            glyph.isTemplate = false
            glyph.draw(in: NSRect(x: x + 42, y: 90, width: 28, height: 20))
            glyph.draw(in: NSRect(x: x + 130, y: 50, width: 140, height: 100))
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]
            ("Babelfin · menu-bar symbol" as NSString).draw(at: NSPoint(x: x + 24, y: 20), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("menubar-preview.png"))
    }
}
