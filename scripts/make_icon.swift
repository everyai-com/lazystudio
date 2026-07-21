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

// Warm charcoal studio background
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let colors = [
    NSColor(calibratedRed: 0.16, green: 0.145, blue: 0.125, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.055, green: 0.05, blue: 0.045, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

// Tungsten key light falling from the top
let keyLight = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(calibratedRed: 0.89, green: 0.65, blue: 0.29, alpha: 0.22).cgColor,
        NSColor.clear.cgColor,
    ] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(keyLight,
    startCenter: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.1), startRadius: 0,
    endCenter: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.1),
    endRadius: rect.height * 0.9, options: [])

// Cream record ring
let center = CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.02)
let ringRadius = rect.width * 0.30
ctx.setStrokeColor(NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.87, alpha: 1).cgColor)
ctx.setLineWidth(rect.width * 0.05)
ctx.addEllipse(in: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                          width: ringRadius * 2, height: ringRadius * 2))
ctx.strokePath()

// Warm red record dot with a soft tungsten glow
let dotRadius = rect.width * 0.165
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: size * 0.045,
              color: NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.2, alpha: 0.75).cgColor)
ctx.setFillColor(NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.25, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                           width: dotRadius * 2, height: dotRadius * 2))
ctx.restoreGState()

// No sparkles — restraint is the taste. The ring and the glow carry it.

image.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
