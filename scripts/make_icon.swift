// Renders the LazyStudio app icon at 1024px.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// macOS-style margins: icon shape is ~82% of the canvas.
let inset: CGFloat = size * 0.09
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius = rect.width * 0.225
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(squircle)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Deep purple → indigo gradient background
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let colors = [
    NSColor(calibratedRed: 0.55, green: 0.27, blue: 0.98, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.24, green: 0.12, blue: 0.58, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

// Subtle top glass highlight
let glass = CGMutablePath()
glass.addEllipse(in: CGRect(x: rect.minX - rect.width * 0.2, y: rect.midY,
                            width: rect.width * 1.4, height: rect.height * 0.9))
ctx.addPath(glass)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
ctx.fillPath()

// White record ring
let center = CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.02)
let ringRadius = rect.width * 0.30
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(rect.width * 0.055)
ctx.addEllipse(in: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                          width: ringRadius * 2, height: ringRadius * 2))
ctx.strokePath()

// Red record dot with glow
let dotRadius = rect.width * 0.175
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: size * 0.04,
              color: NSColor(calibratedRed: 1, green: 0.23, blue: 0.29, alpha: 0.8).cgColor)
ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.27, blue: 0.31, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                           width: dotRadius * 2, height: dotRadius * 2))
ctx.restoreGState()

// AI sparkle (four-point star), top right
func sparkle(at p: CGPoint, r: CGFloat, color: NSColor) {
    let path = CGMutablePath()
    let pinch = r * 0.28
    path.move(to: CGPoint(x: p.x, y: p.y + r))
    path.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: CGPoint(x: p.x + pinch, y: p.y + pinch))
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: CGPoint(x: p.x + pinch, y: p.y - pinch))
    path.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: CGPoint(x: p.x - pinch, y: p.y - pinch))
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: CGPoint(x: p.x - pinch, y: p.y + pinch))
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: size * 0.025,
              color: NSColor(calibratedRed: 1, green: 0.85, blue: 0.3, alpha: 0.9).cgColor)
sparkle(at: CGPoint(x: rect.maxX - rect.width * 0.20, y: rect.maxY - rect.height * 0.20),
        r: rect.width * 0.11, color: NSColor(calibratedRed: 1, green: 0.87, blue: 0.35, alpha: 1))
sparkle(at: CGPoint(x: rect.maxX - rect.width * 0.31, y: rect.maxY - rect.height * 0.115),
        r: rect.width * 0.045, color: NSColor(calibratedRed: 1, green: 0.92, blue: 0.55, alpha: 1))
ctx.restoreGState()

image.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
