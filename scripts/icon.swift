import AppKit
import CoreGraphics

// SpaceMap icon painter: survey ring circling a treemap fragment.
// Usage: swift scripts/icon.swift <output-1024.png>
guard CommandLine.arguments.count == 2 else {
    fputs("usage: icon.swift <output.png>\n", stderr)
    exit(2)
}

let size: CGFloat = 1024
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha).cgColor
}

guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("icon: no context\n", stderr)
    exit(1)
}

let full = CGRect(x: 0, y: 0, width: size, height: size)

// Background: deep-ink rounded square with a vertical lift.
let bg = CGPath(roundedRect: full.insetBy(dx: 8, dy: 8), cornerWidth: 232, cornerHeight: 232, transform: nil)
context.addPath(bg)
context.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x1E2A44), color(0x0C1B26)] as CFArray,
                          locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

// Treemap fragment, lower-left of center.
func fillRounded(_ rect: CGRect, radius: CGFloat) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32) {
    context.setFillColor(color(hex))
    fillRounded(CGRect(x: x, y: y, width: w, height: h), radius: 34)
}
block(196, 210, 300, 320, 0x8E6FD8) // nebula violet
block(516, 210, 308, 190, 0x4C9BE8) // azure
block(516, 420, 308, 110, 0xC96A2C) // ember
block(196, 550, 300, 130, 0x35A37B) // jade

// Survey ring: near-full arc with round caps.
context.setStrokeColor(color(0x4CC3D9))
context.setLineWidth(46)
context.setLineCap(.round)
context.addArc(center: CGPoint(x: 512, y: 512), radius: 348,
               startAngle: CGFloat(-0.35 * Double.pi), endAngle: CGFloat(1.05 * Double.pi), clockwise: false)
context.strokePath()

// Node dot riding the ring's open end.
let dotAngle = CGFloat(-0.35 * Double.pi)
let dot = CGPoint(x: 512 + 348 * cos(dotAngle), y: 512 + 348 * sin(dotAngle))
context.setFillColor(color(0xD9A83C))
context.fillEllipse(in: CGRect(x: dot.x - 56, y: dot.y - 56, width: 112, height: 112))

// Top sheen.
context.setFillColor(color(0xFFFFFF, 0.06))
fillRounded(CGRect(x: 8, y: 512, width: 1008, height: 504), radius: 232)

guard let image = context.makeImage() else { fputs("icon: no image\n", stderr); exit(1) }
let bitmap = NSBitmapImageRep(cgImage: image)
bitmap.size = NSSize(width: 1024, height: 1024)
guard let png = bitmap.representation(using: .png, properties: [:]) else { fputs("icon: no png\n", stderr); exit(1) }
try png.write(to: outURL)
print("wrote \(outURL.path)")
