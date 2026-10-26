// Draws the machen app icon (a red raised fist on white) and writes Support/AppIcon.icns.
// Run from the project folder:  swift Support/make-icon.swift
//
// The fist is Font Awesome Free's hand-fist (CC BY 4.0; Apple's license doesn't allow SF Symbols
// in app icons), drawn on Apple's 1024 pt icon grid: an 824 pt rounded square with a soft shadow.
import AppKit

let support = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func drawIcon() {
    // White tile with a faint vertical shade so it reads on white backgrounds
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = color(0x000000, 0.25)
    tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.shadowBlurRadius = 24
    tileShadow.set()
    NSColor.white.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xFFFFFF), ending: color(0xEFEDEA))!.draw(in: tilePath, angle: -90)

    // Raised fist: Font Awesome Free "hand-fist" (CC BY 4.0, see Support/hand-fist.svg), tinted red
    let fist = NSImage(contentsOf: support.appendingPathComponent("hand-fist.svg"))!
    let height: CGFloat = 560
    let width = height * fist.size.width / fist.size.height
    let fistRect = NSRect(x: 512 - width / 2, y: 512 - height / 2 - 8, width: width, height: height)
    let tinted = NSImage(size: fistRect.size, flipped: false) { rect in
        fist.draw(in: rect)
        color(0xD7261E).set()
        rect.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: fistRect)
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try! png(size: 1024).write(to: support.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", support.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Support/AppIcon.icns and Support/AppIcon.png" : "iconutil failed")
