// Draws the app icon: "MULTI / RBX" in pixel letters on a dark tile, in the style of the AntiAFK-RBX logo.
// Usage: swift packaging/make_icon.swift Resources/AppIcon.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let S: CGFloat = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// 5-row pixel glyphs, top row first.
let glyphs: [Character: [String]] = [
    "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"],
    "U": ["#...#", "#...#", "#...#", "#...#", ".###."],
    "L": ["#....", "#....", "#....", "#....", "#####"],
    "T": ["#####", "..#..", "..#..", "..#..", "..#.."],
    "I": ["###", ".#.", ".#.", ".#.", "###"],
    "R": ["####.", "#...#", "####.", "#..#.", "#...#"],
    "B": ["####.", "#...#", "####.", "#...#", "####."],
    "X": ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
]

/// Path for `text` in pixel letters. `origin` is the bottom-left corner; `cell` is one pixel's size.
func pixelText(_ text: String, origin: NSPoint, cell: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    var x = origin.x
    for ch in text {
        let rows = glyphs[ch]!
        for (r, row) in rows.enumerated() {
            for (c, on) in row.enumerated() where on == "#" {
                let y = origin.y + CGFloat(rows.count - 1 - r) * cell
                path.append(NSBezierPath(rect: NSRect(x: x + CGFloat(c) * cell, y: y, width: cell, height: cell)))
            }
        }
        x += CGFloat(rows[0].count + 1) * cell
    }
    return path
}

func fill(_ path: NSBezierPath, _ gradient: NSGradient, angle: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    gradient.draw(in: path.bounds, angle: angle)
    NSGraphicsContext.restoreGraphicsState()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background tile on Apple's macOS icon grid (824pt tile on a 1024 canvas), with a drop shadow.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.set()
rgb(0x111114).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: rgb(0x26262E), ending: rgb(0x0C0C10))!.draw(in: tile, angle: -60)

// Thin light edge so the dark tile stands out on dark backgrounds.
let edge = NSBezierPath(roundedRect: NSRect(x: 103, y: 103, width: 818, height: 818), xRadius: 182, yRadius: 182)
edge.lineWidth = 6
rgb(0xFFFFFF, 0.12).setStroke()
edge.stroke()

NSGraphicsContext.saveGraphicsState()
tile.addClip()
let left: CGFloat = 180
fill(pixelText("MULTI", origin: NSPoint(x: left, y: 420), cell: 22),
     NSGradient(starting: rgb(0xF4F4F8), ending: rgb(0x9A9AA8))!, angle: -90)
fill(pixelText("RBX", origin: NSPoint(x: left, y: 190), cell: 40),
     NSGradient(starting: rgb(0xFF4136), ending: rgb(0xD0170F))!, angle: -60)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
