// Typesong logo, drawn with clean vector paths on a 100-unit grid (origin bottom-left).
// Usage: swift draw-logo.swift <out.png> <pixels> <avatar|icon>
//   avatar: full-bleed square, artwork sized for a circle crop (no empty corners)
//   icon:   app icon, rounded square with standard margins
import AppKit

let out = CommandLine.arguments[1]
let px = Int(CommandLine.arguments[2])!
let mode = CommandLine.arguments[3]

let ink1 = CGColor(red: 0.13, green: 0.16, blue: 0.24, alpha: 1)    // #212939 top
let ink2 = CGColor(red: 0.06, green: 0.08, blue: 0.13, alpha: 1)    // #0F1421 bottom
let teal1 = CGColor(red: 0.33, green: 0.86, blue: 0.76, alpha: 1)   // #54DBC2
let teal2 = CGColor(red: 0.16, green: 0.66, blue: 0.60, alpha: 1)   // #29A899
let star = CGColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1)

/// An eighth note: the stem rises from the right edge of a tilted oval head, with one swept flag.
/// Returned as separate parts (head, stem, flag): filling overlapping parts as one path can leave hairline
/// seams where their outlines wind in opposite directions, so each part is painted on its own.
func note() -> [CGPath] {
    let p = CGMutablePath()
    let tilt = CGAffineTransform(translationX: 40, y: 28).rotated(by: -0.40)
    p.addEllipse(in: CGRect(x: -15, y: -11, width: 30, height: 22), transform: tilt)
    let stem = CGMutablePath()
    // stem: its right edge runs down to the oval's rightmost point (x 54.46, y 25.4), so the stem's edge flows
    // straight into the head's outline and the note reads as one shape, not a stick resting on a ball
    // stem: its right edge runs down to the oval's rightmost point (x 54.46, y 25.4); kept a hair inside so the
    // oval's own curve forms the corner instead of the rectangle's
    stem.addRect(CGRect(x: 48, y: 25.8, width: 6.4, height: 58.2))
    // flag: grows straight out of the top of the stem, sweeps down, and curls back in; every join is tangent
    let f = CGMutablePath()
    f.move(to: CGPoint(x: 48, y: 84))
    f.addLine(to: CGPoint(x: 54.4, y: 84))
    f.addCurve(to: CGPoint(x: 79, y: 56), control1: CGPoint(x: 58, y: 76), control2: CGPoint(x: 79, y: 71))
    f.addCurve(to: CGPoint(x: 72, y: 38), control1: CGPoint(x: 79, y: 48), control2: CGPoint(x: 76.5, y: 42))
    f.addCurve(to: CGPoint(x: 74.2, y: 55), control1: CGPoint(x: 74.8, y: 44), control2: CGPoint(x: 75.6, y: 50))
    f.addCurve(to: CGPoint(x: 54.4, y: 68), control1: CGPoint(x: 72, y: 62), control2: CGPoint(x: 61, y: 65))
    f.closeSubpath()
    return [p, stem, f]
}

/// A four-point sparkle with softly curved sides.
func sparkle(cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 0.16 * r
    p.move(to: CGPoint(x: cx, y: cy + r))
    p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + k, y: cy + k))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx + k, y: cy - k))
    p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - k, y: cy - k))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx - k, y: cy + k))
    p.closeSubpath()
    return p
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
let s = CGFloat(px) / 100
cg.scaleBy(x: s, y: s)
cg.setShouldAntialias(true)
cg.interpolationQuality = .high

// background
let bg: CGPath = mode == "avatar"
    ? CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
    : CGPath(roundedRect: CGRect(x: 5, y: 5, width: 90, height: 90), cornerWidth: 21, cornerHeight: 21, transform: nil)
cg.saveGState(); cg.addPath(bg); cg.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [ink1, ink2] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 0), options: [])
cg.restoreGState()

// artwork: centered; the avatar keeps it inside the circle a round crop leaves
let fit: CGFloat = mode == "avatar" ? 0.98 : 0.80
cg.saveGState()
cg.translateBy(x: 50, y: 50); cg.scaleBy(x: fit, y: fit); cg.translateBy(x: -55, y: -53)   // art spans about x 25–85, y 17–89
let tg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [teal1, teal2] as CFArray, locations: [0, 1])!
for part in note() {   // one gradient across all parts, so they merge seamlessly
    cg.saveGState(); cg.addPath(part); cg.clip()
    cg.drawLinearGradient(tg, start: CGPoint(x: 0, y: 84), end: CGPoint(x: 0, y: 16), options: [])
    cg.restoreGState()
}
cg.addPath(sparkle(cx: 80, cy: 80, r: 8.5)); cg.setFillColor(star); cg.fillPath()
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
