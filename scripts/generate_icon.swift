import AppKit
import Darwin

/// Draws the Lumos app icon: a wand whose tip lights up a night-blue tile.
/// Coordinates are in a 1024-point canvas with the origin at the bottom left.

struct Vector {
    let x: CGFloat
    let y: CGFloat

    static func + (left: Vector, right: Vector) -> Vector { Vector(x: left.x + right.x, y: left.y + right.y) }
    static func - (left: Vector, right: Vector) -> Vector { Vector(x: left.x - right.x, y: left.y - right.y) }
    static func * (left: Vector, scale: CGFloat) -> Vector { Vector(x: left.x * scale, y: left.y * scale) }

    var point: CGPoint { CGPoint(x: x, y: y) }
    var length: CGFloat { (x * x + y * y).squareRoot() }
    var unit: Vector { self * (1 / length) }
    var perpendicular: Vector { Vector(x: -y, y: x) }
}

func color(_ hex: UInt32, _ alpha: CGFloat) -> CGColor {
    let red = CGFloat((hex >> 16) & 0xFF) / 255
    let green = CGFloat((hex >> 8) & 0xFF) / 255
    let blue = CGFloat(hex & 0xFF) / 255
    return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    guard let made = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: stops.map(\.0) as CFArray,
        locations: stops.map(\.1)
    ) else {
        fputs("Could not create gradient\n", stderr)
        exit(1)
    }
    return made
}

/// Quadrilateral from `start` to `end`, `startHalf` / `endHalf` wide on each side.
func taperedBar(_ start: Vector, _ end: Vector, startHalf: CGFloat, endHalf: CGFloat) -> CGPath {
    let side = (end - start).unit.perpendicular
    let path = CGMutablePath()
    path.move(to: (start + side * startHalf).point)
    path.addLine(to: (end + side * endHalf).point)
    path.addLine(to: (end - side * endHalf).point)
    path.addLine(to: (start - side * startHalf).point)
    path.closeSubpath()
    return path
}

/// Fills `path` with a gradient running across the wand, so it reads as round.
func fillAcross(_ context: CGContext, _ path: CGPath, center: Vector, side: Vector, half: CGFloat, colors: CGGradient) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        colors,
        start: (center + side * half).point,
        end: (center - side * half).point,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()
}

/// Four-pointed sparkle with concave sides.
func sparkle(_ center: Vector, arm: CGFloat, waist: CGFloat, rotation: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let points = (0..<4).map { index -> Vector in
        let angle = rotation + CGFloat(index) * .pi / 2
        return center + Vector(x: cos(angle), y: sin(angle)) * arm
    }
    path.move(to: points[0].point)
    for index in 0..<4 {
        let next = points[(index + 1) % 4]
        let angle = rotation + (CGFloat(index) + 0.5) * .pi / 2
        let control = center + Vector(x: cos(angle), y: sin(angle)) * waist
        path.addQuadCurve(to: next.point, control: control.point)
    }
    path.closeSubpath()
    return path
}

func drawGlow(_ context: CGContext, at center: Vector, radius: CGFloat, stops: [(CGColor, CGFloat)]) {
    context.drawRadialGradient(
        gradient(stops),
        startCenter: center.point,
        startRadius: 0,
        endCenter: center.point,
        endRadius: radius,
        options: []
    )
}

func drawIcon(_ context: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let handleEnd = Vector(x: 268, y: 262)
    let tip = Vector(x: 640, y: 636)
    let direction = (tip - handleEnd).unit
    let side = direction.perpendicular
    let gripEnd = handleEnd + direction * 170

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    // Night sky, lit from the wand tip.
    context.drawLinearGradient(
        gradient([(color(0x2B2378, 1), 0), (color(0x120F3A, 1), 0.6), (color(0x07071A, 1), 1)]),
        start: CGPoint(x: 820, y: 924),
        end: CGPoint(x: 200, y: 100),
        options: []
    )
    drawGlow(context, at: tip, radius: 560, stops: [
        (color(0xFFD27A, 0.55), 0),
        (color(0xC98BFF, 0.22), 0.45),
        (color(0x2B2378, 0), 1)
    ])

    // Faint background stars.
    for (x, y, radius) in [(250, 760, 6.0), (330, 840, 4.0), (790, 300, 5.0), (860, 420, 3.5), (200, 560, 3.5), (720, 210, 3.0)] {
        context.setFillColor(color(0xFFFFFF, 0.55))
        context.fillEllipse(in: CGRect(x: CGFloat(x) - radius, y: CGFloat(y) - radius, width: radius * 2, height: radius * 2))
    }

    // Wand shadow, offset down and right.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 10, height: -14), blur: 26, color: color(0x000000, 0.55))
    context.addPath(taperedBar(handleEnd, tip, startHalf: 40, endHalf: 13))
    context.setFillColor(color(0x3A2414, 1))
    context.fillPath()
    context.restoreGState()

    // Shaft: polished wood, lighter along the top edge.
    let wood = gradient([(color(0xC8925A, 1), 0), (color(0x8A5630, 1), 0.45), (color(0x4A2A14, 1), 1)])
    let shaftStart = gripEnd - direction * 6
    fillAcross(context, taperedBar(shaftStart, tip, startHalf: 25, endHalf: 12), center: (shaftStart + tip) * 0.5, side: side, half: 25, colors: wood)

    // Grip: darker, thicker, with a rounded butt.
    let grip = gradient([(color(0x7A4B2A, 1), 0), (color(0x4B2C16, 1), 0.5), (color(0x24130A, 1), 1)])
    let gripPath = CGMutablePath()
    gripPath.addPath(taperedBar(handleEnd, gripEnd, startHalf: 40, endHalf: 33))
    gripPath.addEllipse(in: CGRect(x: handleEnd.x - 40, y: handleEnd.y - 40, width: 80, height: 80))
    fillAcross(context, gripPath, center: (handleEnd + gripEnd) * 0.5, side: side, half: 40, colors: grip)

    // Gold bands where the grip meets the shaft and near the butt.
    let gold = gradient([(color(0xFFF1B8, 1), 0), (color(0xE2B04A, 1), 0.5), (color(0x8C6420, 1), 1)])
    for (position, half, width) in [(170.0, 36.0, 18.0), (40.0, 41.0, 12.0)] {
        let center = handleEnd + direction * CGFloat(position)
        let band = taperedBar(center - direction * CGFloat(width / 2), center + direction * CGFloat(width / 2), startHalf: CGFloat(half), endHalf: CGFloat(half))
        fillAcross(context, band, center: center, side: side, half: CGFloat(half), colors: gold)
    }

    // The light at the tip.
    drawGlow(context, at: tip, radius: 250, stops: [
        (color(0xFFFFFF, 1), 0),
        (color(0xFFF4C8, 0.95), 0.16),
        (color(0xFFD06A, 0.55), 0.42),
        (color(0xFFB347, 0), 1)
    ])
    context.setFillColor(color(0xFFFFFF, 1))
    context.addPath(sparkle(tip, arm: 190, waist: 20, rotation: .pi / 2))
    context.fillPath()
    context.setFillColor(color(0xFFF6D6, 0.55))
    context.addPath(sparkle(tip, arm: 70, waist: 6, rotation: .pi / 4))
    context.fillPath()

    // Sparks drifting off the light.
    for (x, y, arm) in [(800, 760, 44.0), (520, 800, 28.0), (790, 560, 22.0)] {
        context.setFillColor(color(0xFFF4C8, 0.95))
        context.addPath(sparkle(Vector(x: CGFloat(x), y: CGFloat(y)), arm: CGFloat(arm), waist: CGFloat(arm) * 0.14, rotation: .pi / 2))
        context.fillPath()
    }

    context.restoreGState()
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_icon OUTPUT.png\n", stderr)
    exit(2)
}
let outputPath = CommandLine.arguments[1]
let pixels = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create the icon bitmap\n", stderr)
    exit(1)
}
NSGraphicsContext.current = graphics
drawIcon(graphics.cgContext)
graphics.flushGraphics()
NSGraphicsContext.current = nil
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode PNG\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("Could not write \(outputPath): \(error.localizedDescription)\n", stderr)
    exit(1)
}
