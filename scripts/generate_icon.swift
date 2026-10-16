import AppKit
import Darwin

_ = NSApplication.shared
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size, flipped: false) { rect in
    let inset = rect.insetBy(dx: 72, dy: 72)
    let background = NSBezierPath(roundedRect: inset, xRadius: 220, yRadius: 220)
    NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
    background.fill()

    let glassRect = NSRect(x: 300, y: 400, width: 300, height: 300)
    let glass = NSBezierPath(ovalIn: glassRect)
    glass.lineWidth = 64
    NSColor.white.setStroke()
    glass.stroke()

    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: 540, y: 420))
    handle.line(to: NSPoint(x: 700, y: 250))
    handle.lineWidth = 72
    handle.lineCapStyle = .round
    NSColor.white.setStroke()
    handle.stroke()
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
    fputs("Could not render icon bitmap\n", stderr)
    exit(1)
}
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode PNG\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("Could not write \(outputPath): \(error)\n", stderr)
    exit(1)
}
