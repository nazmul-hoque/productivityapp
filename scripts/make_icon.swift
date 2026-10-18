// Renders the app icon: a white check box on the accent blue, plus dark and tinted variants.
// Usage: swift scripts/make_icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

enum Variant { case light, dark, tinted }

func render(_ variant: Variant, to name: String) {
    // The light icon must be opaque; dark and tinted ones are drawn on transparency.
    let alpha: CGImageAlphaInfo = variant == .light ? .noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: alpha.rawValue)!
    let s = CGFloat(size)

    if variant == .light {
        let gradient = CGGradient(colorsSpace: space,
                                  colors: [color(0.33, 0.60, 1.00), color(0.16, 0.40, 0.86)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }

    let box: CGColor
    let check: CGColor
    switch variant {
    case .light: (box, check) = (color(1, 1, 1), color(0.18, 0.44, 0.90))
    case .dark: (box, check) = (color(0.35, 0.60, 1.00), color(1, 1, 1))
    case .tinted: (box, check) = (color(1, 1, 1), color(0, 0, 0, 1))
    }

    // Rounded check box, slightly above centre.
    let side = s * 0.50
    let rect = CGRect(x: (s - side) / 2, y: (s - side) / 2 + s * 0.02, width: side, height: side)
    let path = CGPath(roundedRect: rect, cornerWidth: side * 0.24, cornerHeight: side * 0.24, transform: nil)
    if variant == .light {
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.04, color: color(0, 0, 0, 0.25))
    }
    ctx.addPath(path)
    ctx.setFillColor(box)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)

    // Check mark.
    let mark = CGMutablePath()
    mark.move(to: CGPoint(x: rect.minX + side * 0.24, y: rect.minY + side * 0.52))
    mark.addLine(to: CGPoint(x: rect.minX + side * 0.43, y: rect.minY + side * 0.32))
    mark.addLine(to: CGPoint(x: rect.minX + side * 0.78, y: rect.minY + side * 0.72))
    ctx.addPath(mark)
    ctx.setLineWidth(side * 0.13)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    if variant == .tinted {
        // Punch the mark out of the box so the system tint shows through.
        ctx.setBlendMode(.clear)
    }
    ctx.setStrokeColor(check)
    ctx.strokePath()

    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

render(.light, to: "AppIcon.png")
render(.dark, to: "AppIcon-Dark.png")
render(.tinted, to: "AppIcon-Tinted.png")
