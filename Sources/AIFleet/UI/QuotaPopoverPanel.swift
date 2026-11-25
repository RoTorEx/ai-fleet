import AppKit

struct QuotaPopoverPlacement: Equatable {
    static let cornerRadius: CGFloat = 12
    static let arrowHalfHeight: CGFloat = 7
    private static let arrowWidth: CGFloat = 11
    private static let iconGap: CGFloat = 3
    private static let screenMargin: CGFloat = 8

    let viewport: CGSize
    let frame: CGRect
    let body: CGRect
    let tip: CGPoint
    let arrowOnRight: Bool
    let shoulderY: CGFloat

    init?(anchor: CGRect, screen: CGRect, contentHeight: CGFloat, preferredWidth: CGFloat = 500) {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        guard !anchor.isEmpty, screen.contains(center) else { return nil }
        let inset = screen.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        let left = anchor.minX - Self.iconGap - Self.arrowWidth - inset.minX
        let right = inset.maxX - anchor.maxX - Self.iconGap - Self.arrowWidth
        arrowOnRight = left >= preferredWidth || left >= right
        viewport = CGSize(width: min(preferredWidth, arrowOnRight ? left : right), height: min(600, inset.height))
        guard viewport.width > 0, viewport.height > 0 else { return nil }

        let height = min(viewport.height, max(1, ceil(contentHeight)))
        let bottom = min(max(center.y - height / 2, inset.minY), inset.maxY - height)
        let windowBottom = min(bottom, max(screen.minY, center.y - 0.5))
        let windowTop = max(bottom + height, min(screen.maxY, center.y + 0.5))
        let width = viewport.width + Self.arrowWidth
        let tipX = arrowOnRight ? anchor.minX - Self.iconGap : anchor.maxX + Self.iconGap
        frame = CGRect(x: arrowOnRight ? tipX - width : tipX, y: windowBottom, width: width, height: windowTop - windowBottom)
        body = CGRect(x: arrowOnRight ? 0 : Self.arrowWidth, y: bottom - windowBottom, width: viewport.width, height: height)
        tip = CGPoint(x: arrowOnRight ? width - 0.5 : 0.5, y: center.y - windowBottom)
        let clearance = Self.cornerRadius + Self.arrowHalfHeight + 1
        shoulderY = height >= 2 * clearance
            ? min(max(tip.y, body.minY + clearance), body.maxY - clearance) : body.midY
    }
}

final class QuotaPopoverPanel: NSPanel {
    private let surface = QuotaPopoverSurface()
    private let hostedView: NSView

    init(content: NSView) {
        hostedView = content
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = surface
        surface.addSubview(hostedView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func layout(_ placement: QuotaPopoverPlacement) {
        guard surface.placement != placement else { return }
        if frame != placement.frame { setFrame(placement.frame, display: false) }
        hostedView.frame = placement.body
        surface.placement = placement
        surface.needsDisplay = true
        invalidateShadow()
    }
}

private final class QuotaPopoverSurface: NSView {
    var placement: QuotaPopoverPlacement?

    override func draw(_ dirtyRect: NSRect) {
        guard let placement, let graphics = NSGraphicsContext.current?.cgContext else { return }
        let body = placement.body.insetBy(dx: 0.5, dy: 0.5)
        guard body.height > 0, body.width > 0 else { return }
        let radius = min(QuotaPopoverPlacement.cornerRadius, body.width / 2, body.height / 4)
        let halfArrow = min(QuotaPopoverPlacement.arrowHalfHeight, body.height / 4)
        let bottom = body.minY
        let top = body.maxY
        let left = body.minX
        let right = body.maxX
        let arrow = placement.shoulderY
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: left + radius, y: bottom))
        outline.addLine(to: CGPoint(x: right - radius, y: bottom))
        outline.addQuadCurve(to: CGPoint(x: right, y: bottom + radius), control: CGPoint(x: right, y: bottom))
        if placement.arrowOnRight {
            outline.addLine(to: CGPoint(x: right, y: arrow - halfArrow))
            outline.addLine(to: placement.tip)
            outline.addLine(to: CGPoint(x: right, y: arrow + halfArrow))
        }
        outline.addLine(to: CGPoint(x: right, y: top - radius))
        outline.addQuadCurve(to: CGPoint(x: right - radius, y: top), control: CGPoint(x: right, y: top))
        outline.addLine(to: CGPoint(x: left + radius, y: top))
        outline.addQuadCurve(to: CGPoint(x: left, y: top - radius), control: CGPoint(x: left, y: top))
        if !placement.arrowOnRight {
            outline.addLine(to: CGPoint(x: left, y: arrow + halfArrow))
            outline.addLine(to: placement.tip)
            outline.addLine(to: CGPoint(x: left, y: arrow - halfArrow))
        }
        outline.addLine(to: CGPoint(x: left, y: bottom + radius))
        outline.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
        outline.closeSubpath()
        graphics.addPath(outline)
        graphics.setFillColor(NSColor.windowBackgroundColor.cgColor)
        graphics.setStrokeColor(NSColor.separatorColor.cgColor)
        graphics.setLineWidth(1)
        graphics.drawPath(using: .fillStroke)
    }
}
