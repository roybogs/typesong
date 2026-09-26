// Draws Typesong's cross-platform icons with plain paths (Apple's SF Symbols can't ship on other platforms).
// Usage: swift draw-icons.swift <out-dir>
import AppKit

func png(_ size: Int, _ path: String, _ draw: (CGContext, CGFloat) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.setShouldAntialias(true)
    draw(cg, CGFloat(size) / 32)   // all shapes are designed on a 32-unit grid
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// An eighth note: tilted oval head, stem, one flag. Origin bottom-left, 32-unit grid.
func notePath(_ s: CGFloat, dx: CGFloat = 0) -> CGPath {
    let p = CGMutablePath()
    var t = CGAffineTransform(translationX: (11 + dx) * s, y: 8 * s).rotated(by: -0.35)
    p.addEllipse(in: CGRect(x: -5.2 * s, y: -3.6 * s, width: 10.4 * s, height: 7.2 * s), transform: t)
    p.addRect(CGRect(x: (14.6 + dx) * s, y: 8.5 * s, width: 2.4 * s, height: 19 * s))
    let f = CGMutablePath()
    f.move(to: CGPoint(x: (17 + dx) * s, y: 27.5 * s))
    f.addCurve(to: CGPoint(x: (23.5 + dx) * s, y: 16 * s), control1: CGPoint(x: (18 + dx) * s, y: 22 * s), control2: CGPoint(x: (26 + dx) * s, y: 21 * s))
    f.addCurve(to: CGPoint(x: (17 + dx) * s, y: 22.5 * s), control1: CGPoint(x: (22 + dx) * s, y: 19.5 * s), control2: CGPoint(x: (19 + dx) * s, y: 21 * s))
    f.closeSubpath()
    p.addPath(f)
    _ = t
    t = .identity
    return p
}

func sparkle(_ s: CGFloat, cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let pts: [(CGFloat, CGFloat)] = [(0, r), (0.28 * r, 0.28 * r), (r, 0), (0.28 * r, -0.28 * r), (0, -r), (-0.28 * r, -0.28 * r), (-r, 0), (-0.28 * r, 0.28 * r)]
    for (i, (x, y)) in pts.enumerated() {
        let q = CGPoint(x: (cx + x) * s, y: (cy + y) * s)
        i == 0 ? p.move(to: q) : p.addLine(to: q)
    }
    p.closeSubpath()
    return p
}

func speaker(_ s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 5 * s, y: 12 * s)); p.addLine(to: CGPoint(x: 10 * s, y: 12 * s)); p.addLine(to: CGPoint(x: 17 * s, y: 6 * s))
    p.addLine(to: CGPoint(x: 17 * s, y: 26 * s)); p.addLine(to: CGPoint(x: 10 * s, y: 20 * s)); p.addLine(to: CGPoint(x: 5 * s, y: 20 * s))
    p.closeSubpath()
    return p
}

let light = NSColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1).cgColor   // reads on dark taskbars
let dark  = NSColor(red: 0.11, green: 0.13, blue: 0.19, alpha: 1).cgColor   // outline keeps it readable on light ones
let teal  = NSColor(red: 0.24, green: 0.78, blue: 0.70, alpha: 1).cgColor

func trayFill(_ cg: CGContext, _ path: CGPath, _ s: CGFloat) {
    cg.addPath(path); cg.setLineWidth(2.2 * s); cg.setStrokeColor(dark); cg.setLineJoin(.round); cg.strokePath()
    cg.addPath(path); cg.setFillColor(light); cg.fillPath()
}

let out = CommandLine.arguments[1]
for px in [32, 64] {
    let sfx = px == 32 ? "" : "@2x"
    png(px, "\(out)/tray-note\(sfx).png") { cg, s in trayFill(cg, notePath(s, dx: 2), s) }
    png(px, "\(out)/tray-agent\(sfx).png") { cg, s in trayFill(cg, notePath(s, dx: -1), s); trayFill(cg, sparkle(s, cx: 26, cy: 26, r: 5.2), s) }
    png(px, "\(out)/tray-mute\(sfx).png") { cg, s in
        trayFill(cg, speaker(s), s)
        let slash = CGMutablePath(); slash.move(to: CGPoint(x: 21 * s, y: 11 * s)); slash.addLine(to: CGPoint(x: 29 * s, y: 21 * s))
        slash.move(to: CGPoint(x: 29 * s, y: 11 * s)); slash.addLine(to: CGPoint(x: 21 * s, y: 21 * s))
        cg.addPath(slash); cg.setLineCap(.round); cg.setLineWidth(5 * s); cg.setStrokeColor(dark); cg.strokePath()
        cg.addPath(slash); cg.setLineWidth(2.6 * s); cg.setStrokeColor(light); cg.strokePath()
    }
    png(px, "\(out)/tray-warning\(sfx).png") { cg, s in
        let tri = CGMutablePath(); tri.move(to: CGPoint(x: 16 * s, y: 29 * s)); tri.addLine(to: CGPoint(x: 30 * s, y: 4 * s)); tri.addLine(to: CGPoint(x: 2 * s, y: 4 * s)); tri.closeSubpath()
        trayFill(cg, tri, s)
        cg.setFillColor(dark); cg.fill(CGRect(x: 14.6 * s, y: 12 * s, width: 2.8 * s, height: 10 * s)); cg.fillEllipse(in: CGRect(x: 14.4 * s, y: 6.5 * s, width: 3.2 * s, height: 3.2 * s))
    }
}
// App icon: a deep ink rounded square with a teal note and a small sparkle.
png(1024, "\(out)/app-icon.png") { cg, s in
    let bg = CGPath(roundedRect: CGRect(x: 1.5 * s, y: 1.5 * s, width: 29 * s, height: 29 * s), cornerWidth: 7 * s, cornerHeight: 7 * s, transform: nil)
    cg.addPath(bg); cg.setFillColor(dark); cg.fillPath()
    cg.saveGState(); cg.translateBy(x: 3.2 * s, y: 2.6 * s); cg.scaleBy(x: 0.78, y: 0.78)
    cg.addPath(notePath(s, dx: 2)); cg.setFillColor(teal); cg.fillPath(); cg.restoreGState()
    cg.addPath(sparkle(s, cx: 23.5, cy: 23.5, r: 3.4)); cg.setFillColor(light); cg.fillPath()
}
print("icons written to \(out)")
