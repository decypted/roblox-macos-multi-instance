// Draws the README banner from the app icon.
// Usage: swift packaging/make_banner.swift Resources/AppIcon.png .github/assets/banner.png
import AppKit

let args = CommandLine.arguments
let icon = NSImage(contentsOfFile: args[1])!
let out = args[2]
let W: CGFloat = 1600, H: CGFloat = 480

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Rounded background with the icon's dark gradient.
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: W, height: H), xRadius: 36, yRadius: 36)
NSGradient(starting: rgb(0x26262E), ending: rgb(0x0C0C10))!.draw(in: bg, angle: -25)

// App icon on the left.
icon.draw(in: NSRect(x: 70, y: 50, width: 380, height: 380))

// Title and tagline.
// "RBX" in the icon's red, the rest in white.
let title = NSMutableAttributedString(string: "RBX Multi-Instance", attributes: [
    .font: NSFont.systemFont(ofSize: 92, weight: .bold), .foregroundColor: NSColor.white,
])
title.addAttribute(.foregroundColor, value: rgb(0xFF3B30), range: NSRange(location: 0, length: 3))
title.draw(at: NSPoint(x: 480, y: 250))
let tagline = NSAttributedString(string: "Multiple Roblox accounts and Anti-AFK on macOS", attributes: [
    .font: NSFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.7),
])
tagline.draw(at: NSPoint(x: 484, y: 180))

NSGraphicsContext.restoreGraphicsState()
try! FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
