import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 220, yRadius: 220)
NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.78, alpha: 1)])!.draw(in: background, angle: -55)

NSColor.white.withAlphaComponent(0.97).setFill()
NSBezierPath(roundedRect: NSRect(x: 190, y: 280, width: 644, height: 340), xRadius: 72, yRadius: 72).fill()

NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 245, y: 450, width: 534, height: 260), xRadius: 32, yRadius: 32).fill()

NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 295, y: 520, width: 434, height: 285), xRadius: 24, yRadius: 24).fill()

NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.94, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 295, y: 345, width: 434, height: 62), xRadius: 24, yRadius: 24).fill()

NSColor(calibratedRed: 0.25, green: 0.80, blue: 0.44, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 728, y: 525, width: 42, height: 42)).fill()

image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = representation.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
