import AppKit

// Geometry matches docs/assets/icon-collection/ship-v4/design.json.
// Native vector drawing stays sharp at every backing scale and needs no external resource bundle.
enum FleetIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / 64, y: rect.height / 64)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(3.6)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.saveGState()
            context.addPath(waveClip())
            context.clip()
            for path in [mast(), bridge(), hull(), bow()] {
                context.addPath(path)
                context.strokePath()
            }
            context.restoreGState()
            context.addPath(wave())
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func mast() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 32, y: 16))
        path.addLine(to: CGPoint(x: 32, y: 22))
        return path
    }

    private static func bridge() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 20.5, y: 34.5))
        path.addLine(to: CGPoint(x: 21.5, y: 24))
        path.addQuadCurve(to: CGPoint(x: 24.5, y: 22), control: CGPoint(x: 21.5, y: 22))
        path.addLine(to: CGPoint(x: 39.5, y: 22))
        path.addQuadCurve(to: CGPoint(x: 42.5, y: 24), control: CGPoint(x: 42.5, y: 22))
        path.addLine(to: CGPoint(x: 43.5, y: 34.5))
        return path
    }

    private static func hull() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 20, y: 57))
        path.addCurve(to: CGPoint(x: 14, y: 38), control1: CGPoint(x: 17, y: 51), control2: CGPoint(x: 15, y: 45))
        path.addQuadCurve(to: CGPoint(x: 32, y: 31), control: CGPoint(x: 23, y: 35))
        path.addQuadCurve(to: CGPoint(x: 50, y: 38), control: CGPoint(x: 41, y: 35))
        path.addCurve(to: CGPoint(x: 44, y: 57), control1: CGPoint(x: 49, y: 45), control2: CGPoint(x: 47, y: 51))
        return path
    }

    private static func bow() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 32, y: 31))
        path.addLine(to: CGPoint(x: 32, y: 57))
        return path
    }

    private static func wave() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 10, y: 49))
        path.addQuadCurve(to: CGPoint(x: 21, y: 50), control: CGPoint(x: 15.5, y: 55))
        path.addQuadCurve(to: CGPoint(x: 32, y: 50), control: CGPoint(x: 26.5, y: 45))
        path.addQuadCurve(to: CGPoint(x: 43, y: 50), control: CGPoint(x: 37.5, y: 55))
        path.addQuadCurve(to: CGPoint(x: 54, y: 50), control: CGPoint(x: 48.5, y: 45))
        return path
    }

    private static func waveClip() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 64, y: 0))
        path.addLine(to: CGPoint(x: 64, y: 50))
        path.addLine(to: CGPoint(x: 54, y: 50))
        path.addQuadCurve(to: CGPoint(x: 43, y: 50), control: CGPoint(x: 48.5, y: 45))
        path.addQuadCurve(to: CGPoint(x: 32, y: 50), control: CGPoint(x: 37.5, y: 55))
        path.addQuadCurve(to: CGPoint(x: 21, y: 50), control: CGPoint(x: 26.5, y: 45))
        path.addQuadCurve(to: CGPoint(x: 10, y: 49), control: CGPoint(x: 15.5, y: 55))
        path.addLine(to: CGPoint(x: 0, y: 49))
        path.closeSubpath()
        return path
    }
}
