import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let outer = NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 205, yRadius: 205)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill(); outer.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.96, green: 0.99, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.76, green: 0.89, blue: 0.87, alpha: 1)])!.draw(in: outer, angle: -65)
    NSColor.white.withAlphaComponent(0.72).setStroke(); outer.lineWidth = 3; outer.stroke()

    let disk = NSBezierPath(roundedRect: NSRect(x: 218, y: 257, width: 588, height: 190), xRadius: 62, yRadius: 62)
    NSGraphicsContext.saveGraphicsState()
    let diskShadow = NSShadow(); diskShadow.shadowColor = NSColor(calibratedRed: 0.12, green: 0.37, blue: 0.34, alpha: 0.25)
    diskShadow.shadowBlurRadius = 38; diskShadow.shadowOffset = NSSize(width: 0, height: -18); diskShadow.set()
    NSGradient(colors: [.white, NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.90, alpha: 1)])!.draw(in: disk, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.85).setStroke(); disk.lineWidth = 3; disk.stroke()
    NSColor(calibratedRed: 0.15, green: 0.57, blue: 0.48, alpha: 0.8).setFill()
    NSBezierPath(ovalIn: NSRect(x: 727, y: 315, width: 17, height: 17)).fill()

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 512, y: 756))
    arrow.curve(to: NSPoint(x: 533, y: 744), controlPoint1: NSPoint(x: 520, y: 756), controlPoint2: NSPoint(x: 527, y: 751))
    arrow.line(to: NSPoint(x: 683, y: 559))
    arrow.curve(to: NSPoint(x: 665, y: 523), controlPoint1: NSPoint(x: 698, y: 540), controlPoint2: NSPoint(x: 687, y: 523))
    arrow.line(to: NSPoint(x: 359, y: 523))
    arrow.curve(to: NSPoint(x: 341, y: 559), controlPoint1: NSPoint(x: 337, y: 523), controlPoint2: NSPoint(x: 326, y: 540))
    arrow.line(to: NSPoint(x: 491, y: 744))
    arrow.curve(to: NSPoint(x: 512, y: 756), controlPoint1: NSPoint(x: 497, y: 751), controlPoint2: NSPoint(x: 504, y: 756))
    arrow.close()
    NSGradient(colors: [NSColor(calibratedRed: 0.19, green: 0.66, blue: 0.57, alpha: 1),
                        NSColor(calibratedRed: 0.08, green: 0.40, blue: 0.37, alpha: 1)])!.draw(in: arrow, angle: -90)
    NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.40, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 357, y: 467, width: 310, height: 35), xRadius: 15, yRadius: 15).fill()
    return true
}
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
