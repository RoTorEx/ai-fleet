import AppKit

// Exact menu-bar drawing used through v1.2.9. Kept for recovery.
enum LegacyFleetIcon {
    static func makeStatusImage() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            let scale = min(rect.width, rect.height) / 64
            let scaleTransform = AffineTransform(scaleByX: scale, byY: scale)
            let translateTransform = AffineTransform(
                translationByX: rect.midX - 32 * scale,
                byY: rect.midY - 32 * scale
            )

            for path in makeClipperPaths() {
                path.transform(using: scaleTransform)
                path.transform(using: translateTransform)
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func makeClipperPaths() -> [NSBezierPath] {
        [
            polygon([
                svgPoint(x: 31, y: 5),
                svgPoint(x: 34, y: 5),
                svgPoint(x: 34, y: 43),
                svgPoint(x: 58, y: 43),
                svgPoint(x: 47, y: 56),
                svgPoint(x: 17, y: 56),
                svgPoint(x: 6, y: 43),
                svgPoint(x: 31, y: 43)
            ]),
            polygon([
                svgPoint(x: 37, y: 14),
                svgPoint(x: 37, y: 27),
                svgPoint(x: 53, y: 27)
            ]),
            polygon([
                svgPoint(x: 37, y: 31),
                svgPoint(x: 37, y: 40),
                svgPoint(x: 55, y: 40),
                svgPoint(x: 48, y: 31)
            ]),
            polygon([
                svgPoint(x: 28, y: 13),
                svgPoint(x: 10, y: 40),
                svgPoint(x: 28, y: 40)
            ]),
            polygon([
                svgPoint(x: 19, y: 47),
                svgPoint(x: 22, y: 51),
                svgPoint(x: 42, y: 51),
                svgPoint(x: 46, y: 47)
            ])
        ]
    }

    private static func svgPoint(x: CGFloat, y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: 64 - y)
    }

    private static func polygon(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.close()
        return path
    }
}
