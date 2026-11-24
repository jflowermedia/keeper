// Draws Keeper's app icon (icon.png, 1024x1024): an SD card with a keep mark, in Catppuccin
// Mocha, with a little glass to it. https://catppuccin.com/palette/
//
// Tweak the numbers below and rerun:
//
//     swift make_icon.swift
//
// Then rebuild with ./build_app.sh --install to put the new icon on the app.
//
// Swift rather than a script needing a package: the Command Line Tools are all this project
// asks for, and the light and shade here want real blurs, which an SVG renderer may not do.

import AppKit
import CoreImage

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: Palette

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat(hex >> 16 & 255) / 255,
                                            CGFloat(hex >> 8 & 255) / 255,
                                            CGFloat(hex & 255) / 255, alpha])!
}

let pink: UInt32 = 0xf5c2e7, mauve: UInt32 = 0xcba6f7, lavender: UInt32 = 0xb4befe
let subtext: UInt32 = 0xbac2de, overlay: UInt32 = 0x7f849c, surface2: UInt32 = 0x585b70
let surface1: UInt32 = 0x45475a, surface0: UInt32 = 0x313244, base: UInt32 = 0x1e1e2e
let mantle: UInt32 = 0x181825, crust: UInt32 = 0x11111b
let white: UInt32 = 0xffffff
/// Mauve, deep enough to be its own shadow. Crust over the card goes grey.
let plum: UInt32 = 0x4a2f6b

// MARK: Drawing

func canvas() -> CGContext {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // y down, so the coordinates read like the design's.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    return context
}

func blurred(_ radius: Double, _ draw: (CGContext) -> Void) -> CGImage {
    let context = canvas()
    draw(context)
    let image = CIImage(cgImage: context.makeImage()!)
    let soft = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
    return CIContext(options: [.workingColorSpace: space])
        .createCGImage(soft, from: image.extent, format: .RGBA8, colorSpace: space)!
}

func put(_ image: CGImage, on context: CGContext, down: CGFloat = 0) {
    context.saveGState()
    context.translateBy(x: 0, y: CGFloat(size) + down)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    context.restoreGState()
}

func fill(_ path: CGPath, on context: CGContext, _ colours: [CGColor], _ stops: [CGFloat],
          from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(CGGradient(colorsSpace: space, colors: colours as CFArray, locations: stops)!,
                               start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func outline(_ path: CGPath, _ width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// Light or shade falling inside a shape from its own edge.
func inside(_ path: CGPath, on context: CGContext, _ tint: CGColor, x: CGFloat = 0, y: CGFloat, soft: Double) {
    let shade = blurred(soft) { c in
        c.setFillColor(tint)
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        c.setBlendMode(.clear)
        c.translateBy(x: x, y: y)
        c.addPath(path)
        c.fillPath()
    }
    context.saveGState()
    context.addPath(path)
    context.clip()
    put(shade, on: context)
    context.restoreGState()
}

func over(_ path: CGPath, on context: CGContext, _ tint: CGColor, x: CGFloat = 0, y: CGFloat) {
    context.saveGState()
    context.translateBy(x: x, y: y)
    context.addPath(path)
    context.setFillColor(tint)
    context.fillPath()
    context.restoreGState()
}

// MARK: Shapes

/// The card is drawn at its own size and scaled up about the middle.
let scale: CGFloat = 1.24
func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: 512 + (x - 512) * scale, y: 512 + (y - 512) * scale)
}

let plate = CGPath(roundedRect: CGRect(x: 92, y: 92, width: 840, height: 840),
                   cornerWidth: 188, cornerHeight: 188, transform: nil)

/// A rounded rectangle with the bevelled top-left corner, softened at both ends of the bevel.
let card: CGPath = {
    let path = CGMutablePath()
    path.move(to: at(412, 268))
    path.addLine(to: at(660, 268))
    path.addQuadCurve(to: at(696, 304), control: at(696, 268))
    path.addLine(to: at(696, 720))
    path.addQuadCurve(to: at(660, 756), control: at(696, 756))
    path.addLine(to: at(364, 756))
    path.addQuadCurve(to: at(328, 720), control: at(328, 756))
    path.addLine(to: at(328, 352))
    path.addQuadCurve(to: at(336, 332), control: at(328, 340))
    path.addLine(to: at(392, 276))
    path.addQuadCurve(to: at(412, 268), control: at(400, 268))
    path.closeSubpath()
    return path
}()

let contacts: CGPath = {
    let path = CGMutablePath()
    for x: CGFloat in [429, 493, 557] {
        path.addPath(CGPath(roundedRect: CGRect(origin: at(x, 304),
                                                size: CGSize(width: 38 * scale, height: 82 * scale)),
                            cornerWidth: 19 * scale, cornerHeight: 19 * scale, transform: nil))
    }
    return path
}()

let tick: CGPath = {
    let line = CGMutablePath()
    line.move(to: at(419.1, 554.6))
    line.addLine(to: at(483.9, 619.4))
    line.addLine(to: at(604.9, 472.6))
    return outline(line, 56 * scale)
}()

// MARK: The icon

let icon = canvas()

// The plate: lighter at the top, with a breath of the card's colours in two corners.
fill(plate, on: icon, [colour(surface0), colour(base)], [0, 1],
     from: CGPoint(x: 0, y: 92), to: CGPoint(x: 0, y: 932))
icon.saveGState()
icon.addPath(plate)
icon.clip()
put(blurred(100) { c in
    for (centre, radius, tint) in [(CGPoint(x: 300, y: 280), CGFloat(190), pink),
                                   (CGPoint(x: 740, y: 780), CGFloat(210), lavender)] {
        c.setFillColor(colour(tint, 0.13))
        c.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                 width: 2 * radius, height: 2 * radius))
    }
}, on: icon)
put(blurred(20) { $0.addPath(card); $0.setFillColor(colour(crust, 0.6)); $0.fillPath() }, on: icon, down: 16)
icon.restoreGState()

// Light along the plate's top edge, fading. Without it the plate is lost on a dark Dock.
fill(outline(CGPath(roundedRect: CGRect(x: 94.5, y: 94.5, width: 835, height: 835),
                    cornerWidth: 185.5, cornerHeight: 185.5, transform: nil), 5),
     on: icon, [colour(overlay), colour(surface2, 0.35), colour(surface1, 0.25)], [0, 0.45, 1],
     from: CGPoint(x: 0, y: 92), to: CGPoint(x: 0, y: 932))

// The card: lit from above, a little from below, and round its edge.
fill(card, on: icon, [colour(pink), colour(mauve)], [0, 1], from: at(328, 268), to: at(696, 756))
fill(card, on: icon, [colour(white, 0.20), colour(white, 0)], [0, 1], from: at(0, 268), to: at(0, 440))
fill(card, on: icon, [colour(white, 0), colour(white, 0.10)], [0, 1], from: at(0, 660), to: at(0, 756))
icon.saveGState()
icon.addPath(card)
icon.clip()
put(blurred(6) { $0.addPath(outline(card, 12)); $0.setFillColor(colour(white, 0.5)); $0.fillPath() }, on: icon)
fill(outline(card, 7), on: icon, [colour(white, 0.9), colour(white, 0.11), colour(white, 0.5)], [0, 0.5, 1],
     from: at(328, 268), to: at(696, 756))
icon.restoreGState()

// The contacts are cut in, softly: a lit lower lip, and shade under the top edge.
let top = contacts.boundingBox
over(contacts, on: icon, colour(white, 0.42), x: 1, y: 3.5)
fill(contacts, on: icon, [colour(base), colour(surface0)], [0, 1],
     from: CGPoint(x: 0, y: top.minY), to: CGPoint(x: 0, y: top.maxY))
inside(contacts, on: icon, colour(crust, 0.85), x: 1, y: 8, soft: 7)

// The tick is raised, very softly: a plum shadow on the card, and a thread of light on top.
icon.saveGState()
icon.addPath(card)
icon.clip()
put(blurred(8) { $0.addPath(tick); $0.setFillColor(colour(plum, 0.34)); $0.fillPath() }, on: icon, down: 8)
icon.restoreGState()
let box = tick.boundingBox
fill(tick, on: icon, [colour(0x2a2b3d), colour(base), colour(mantle)], [0, 0.6, 1],
     from: CGPoint(x: 0, y: box.minY), to: CGPoint(x: 0, y: box.maxY))
inside(tick, on: icon, colour(subtext, 0.30), y: 3.5, soft: 2.5)

let path = CommandLine.arguments.dropFirst().first ?? "icon.png"
try! NSBitmapImageRep(cgImage: icon.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: path))
print("wrote \(path)")
