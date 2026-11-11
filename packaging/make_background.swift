// Draws the DMG window background: app slot on the left, arrow, Applications slot on the right.
// Usage: swift make_background.swift <out.png> <scale> "<title>"
import AppKit

let args = CommandLine.arguments
let out = args[1]
let scale = CGFloat(Double(args[2]) ?? 1)
let title = args.count > 3 ? args[3] : "Install"

let W: CGFloat = 640, H: CGFloat = 400
let px = NSSize(width: W * scale, height: H * scale)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background gradient (fixed light colors: Finder draws this as-is in both themes).
NSGradient(starting: NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
           ending: NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.97, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// Coordinates below are bottom-left origin; icons sit at y=180 from the top (220 from bottom).
let iconCenterY = H - 190

// Soft slots behind the two icons.
for x in [170.0, 470.0] {
    let r = NSRect(x: x - 78, y: iconCenterY - 88, width: 156, height: 156)
    NSColor(calibratedWhite: 1, alpha: 0.65).setFill()
    NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26).fill()
    NSColor(calibratedRed: 0.75, green: 0.80, blue: 0.90, alpha: 1).setStroke()
    let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 26, yRadius: 26)
    border.lineWidth = 1
    border.setLineDash([6, 4], count: 2, phase: 0)
    border.stroke()
}

// Arrow.
let accent = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1)
accent.setStroke(); accent.setFill()
let y = iconCenterY + 10
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 268, y: y))
shaft.line(to: NSPoint(x: 356, y: y))
shaft.lineWidth = 7
shaft.lineCapStyle = .round
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 376, y: y))
head.line(to: NSPoint(x: 350, y: y + 17))
head.line(to: NSPoint(x: 350, y: y - 17))
head.close()
head.fill()

// Text.
func draw(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p,
    ]
    NSAttributedString(string: s, attributes: attrs).draw(in: NSRect(x: 0, y: y, width: W, height: size * 1.4))
}
draw(title, size: 22, weight: .semibold, color: NSColor(calibratedWhite: 0.12, alpha: 1), y: H - 62)
draw("Drag the app onto the Applications folder to install", size: 13, weight: .regular,
     color: NSColor(calibratedWhite: 0.38, alpha: 1), y: H - 88)
draw("First launch: if macOS can't verify the app, open System Settings → Privacy & Security → Open Anyway",
     size: 11, weight: .regular, color: NSColor(calibratedWhite: 0.45, alpha: 1), y: 34)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
