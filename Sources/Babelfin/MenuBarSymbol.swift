import AppKit

/// A template glyph, drawn as geometry so the menu bar can tint it for either appearance.
/// The capsule is the fish body; two broad negative-space slots also read as microphone grille/gills.
enum MenuBarSymbol {
    static let idle = make(active: false)
    static let live = make(active: true)

    static func make(active: Bool, tint: NSColor = .black) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 20), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(tint.cgColor)
            let tail = CGMutablePath()
            tail.move(to: CGPoint(x: 1, y: 4))
            tail.addLine(to: CGPoint(x: 9, y: 8))
            tail.addLine(to: CGPoint(x: 9, y: 12))
            tail.addLine(to: CGPoint(x: 1, y: 16))
            tail.addLine(to: CGPoint(x: 3, y: 10))
            tail.closeSubpath()
            context.addPath(tail)
            context.fillPath()
            let fin = CGMutablePath()
            fin.move(to: CGPoint(x: 11, y: 15))
            fin.addLine(to: CGPoint(x: 15, y: 19))
            fin.addLine(to: CGPoint(x: 19, y: 15))
            fin.closeSubpath()
            context.addPath(fin)
            context.fillPath()
            context.fillEllipse(in: CGRect(x: 6, y: 3, width: 19, height: 14))
            if active { context.fillEllipse(in: CGRect(x: 25, y: 16, width: 3, height: 3)) }
            context.setBlendMode(.clear)
            for x: CGFloat in [11, 14] {
                context.addPath(CGPath(roundedRect: CGRect(x: x, y: 6, width: 1.5, height: 8), cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
                context.fillPath()
            }
            context.fillEllipse(in: CGRect(x: 20, y: 11, width: 2, height: 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Babelfin"
        return image
    }
}
