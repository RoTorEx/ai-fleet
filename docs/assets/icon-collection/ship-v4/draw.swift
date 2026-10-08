import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("design.json"))) as! [String: Any]
let paths = spec["paths"] as! [[String: Any]]

func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    let n = UInt32(hex, radix: 16)!
    return CGColor(red: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255,
                   blue: CGFloat(n & 255) / 255, alpha: alpha)
}
func path(_ commands: [[Any]]) -> CGPath {
    let p = CGMutablePath()
    func number(_ c: [Any], _ i: Int) -> CGFloat { (c[i] as! NSNumber).doubleValue }
    for c in commands {
        switch c[0] as! String {
        case "M": p.move(to: CGPoint(x: number(c,1), y: number(c,2)))
        case "L": p.addLine(to: CGPoint(x: number(c,1), y: number(c,2)))
        case "C": p.addCurve(to: CGPoint(x: number(c,5), y: number(c,6)), control1: CGPoint(x: number(c,1), y: number(c,2)), control2: CGPoint(x: number(c,3), y: number(c,4)))
        case "Q": p.addQuadCurve(to: CGPoint(x: number(c,3), y: number(c,4)), control: CGPoint(x: number(c,1), y: number(c,2)))
        case "Z": p.closeSubpath()
        default: fatalError("Unknown command")
        }
    }
    return p
}
func ship(_ ctx: CGContext, x: CGFloat, y: CGFloat, scale: CGFloat, ink: String, app: Bool = false) {
    ctx.saveGState(); defer { ctx.restoreGState() }
    ctx.translateBy(x: x, y: y); ctx.scaleBy(x: scale, y: scale)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for item in paths {
        let role = item["role"] as! String
        ctx.saveGState()
        if role != "wave" {
            ctx.addPath(path(spec["waveClip"] as! [[Any]])); ctx.clip()
        }
        if role == "hullFill" {
            if app { ctx.addPath(path(item["commands"] as! [[Any]])); ctx.setFillColor(color("36D8CE", alpha: 0.16)); ctx.fillPath() }
            ctx.restoreGState()
            continue
        }
        ctx.setStrokeColor(color(app && role == "wave" ? "55E3D0" : ink))
        ctx.setLineWidth(app ? 3.2 : 3.6)
        ctx.addPath(path(item["commands"] as! [[Any]])); ctx.strokePath()
        ctx.restoreGState()
    }
}
func tile(_ ctx: CGContext, rect: CGRect) {
    ctx.saveGState(); defer { ctx.restoreGState() }
    let outline = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.235, cornerHeight: rect.height * 0.235, transform: nil)
    ctx.addPath(outline); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color("17394D"), color("0A152B"), color("080F20")] as CFArray, locations: [0,0.6,1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color("2AC9C7", alpha: 0.24), color("2AC9C7", alpha: 0)] as CFArray, locations: [0,1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.12), startRadius: 0, endCenter: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.12), endRadius: rect.width * 0.9, options: [])
    ctx.addPath(outline); ctx.setStrokeColor(color("FFFFFF", alpha: 0.12)); ctx.setLineWidth(rect.width / 500); ctx.strokePath()
}
func render(size: Int, file: String, draw: (CGContext) -> Void) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(file))
}
for size in [16,32,64,128,256,512,1024] {
    try render(size: size, file: "app-icon-\(size).png") { ctx in
        tile(ctx, rect: CGRect(x: 48, y: 48, width: 928, height: 928))
        ship(ctx, x: 96, y: 90, scale: 13, ink: "F0FAFF", app: true)
    }
}
for (size, suffix) in [(18,""),(36,"@2x"),(54,"@3x"),(512,"-preview")] {
    try render(size: size, file: "menu-bar\(suffix).png") { ctx in
        ship(ctx, x: 0, y: 0, scale: 16, ink: "000000")
    }
}
try render(size: 1600, file: "Preview.png") { ctx in
    ctx.setFillColor(color("F0F2F5")); ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, ink: String, weight: NSFont.Weight = .regular) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.translateBy(x: x, y: y + size * 1.25); ctx.scaleBy(x: 1, y: -1)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        (string as NSString).draw(at: .zero, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(cgColor: color(ink))!])
        NSGraphicsContext.restoreGraphicsState()
    }
    text("AI FLEET", x: 62, y: 45, size: 18, ink: "526378", weight: .semibold)
    text("Держим курс.", x: 60, y: 78, size: 52, ink: "122037", weight: .bold)
    text("Один корабль. Две иконки.", x: 62, y: 146, size: 20, ink: "64748B")
    ctx.setFillColor(color("FFFFFF")); ctx.addPath(CGPath(roundedRect: CGRect(x: 52, y: 220, width: 570, height: 570), cornerWidth: 28, cornerHeight: 28, transform: nil)); ctx.fillPath()
    tile(ctx, rect: CGRect(x: 102, y: 252, width: 470, height: 470))
    ship(ctx, x: 126.3, y: 273.3, scale: 6.58, ink: "F0FAFF", app: true)
    text("ПРИЛОЖЕНИЕ", x: 90, y: 742, size: 15, ink: "64748B", weight: .semibold)
    ctx.setFillColor(color("FFFFFF")); ctx.addPath(CGPath(roundedRect: CGRect(x: 646, y: 220, width: 326, height: 570), cornerWidth: 28, cornerHeight: 28, transform: nil)); ctx.fillPath()
    ship(ctx, x: 690, y: 274, scale: 3.7, ink: "142238")
    text("МЕНЮ-БАР", x: 686, y: 532, size: 15, ink: "64748B", weight: .semibold)
    ctx.setFillColor(color("22252B")); ctx.addPath(CGPath(roundedRect: CGRect(x: 680, y: 582, width: 256, height: 58), cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.fillPath()
    ship(ctx, x: 708, y: 596, scale: 0.47, ink: "FFFFFF")
    text("AI Fleet", x: 751, y: 598, size: 19, ink: "F5F7FA", weight: .medium)
    ctx.setFillColor(color("EEF1F5")); ctx.addPath(CGPath(roundedRect: CGRect(x: 680, y: 658, width: 256, height: 58), cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.fillPath()
    ship(ctx, x: 708, y: 672, scale: 0.47, ink: "162337")
    text("AI Fleet", x: 751, y: 674, size: 19, ink: "162337", weight: .medium)
    text("Крупно и в маленьком размере.", x: 64, y: 855, size: 22, ink: "142238", weight: .semibold)
    for (i, s) in [64.0,48,32,24,18].enumerated() {
        ship(ctx, x: 64 + CGFloat(i) * 120, y: 915, scale: s / 64, ink: "142238")
    }
}
print("Rendered app icons, template icons, and preview")
