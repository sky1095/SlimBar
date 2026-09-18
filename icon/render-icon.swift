// SlimBar's app icon, drawn rather than stored as flat artwork so every slot in
// the iconset is rendered natively instead of resampled from one master.
// The mark reuses the app's own language: a device outline, and the green dot
// that marks a running simulator in the menu.
import AppKit

func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
}

func device(_ s: CGFloat, width: CGFloat, height: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: (512 - width/2)*s, y: (512 - height/2)*s, width: width*s, height: height*s),
                 xRadius: 62*s, yRadius: 62*s)
}

func drawIcon(_ size: CGFloat) {
    let s = size / 1024
    // macOS icon grid: an 824pt rounded square centred in a 1024pt canvas.
    let squircle = NSBezierPath(roundedRect: NSRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s),
                                xRadius: 185.4*s, yRadius: 185.4*s)
    NSGradient(starting: color(0x11141A), ending: color(0x3A4048))!.draw(in: squircle, angle: 90)

    // At 16pt the outline is a fraction of a pixel and collapses into a smear,
    // so the smallest slot carries a filled silhouette instead. The floors below
    // only bind at 32pt; above it everything stays proportional.
    let dot: CGFloat
    if size < 32 {
        NSColor.white.setFill()
        device(s, width: 300, height: 500).fill()
        dot = max(110*s, 2)
    } else {
        let outline = device(s, width: 310, height: 520)
        outline.lineWidth = max(46*s, 2)
        NSColor.white.setStroke()
        outline.stroke()
        dot = max(96*s, 3.5)
    }
    color(0x32D74B).setFill()
    NSBezierPath(ovalIn: NSRect(x: size/2 - dot/2, y: size/2 - dot/2, width: dot, height: dot)).fill()
}

let out = CommandLine.arguments[1]
for size in [16, 32, 64, 128, 256, 512, 1024] as [CGFloat] {
    let raw = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: raw)
    drawIcon(size)
    NSGraphicsContext.restoreGraphicsState()
    try raw.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(Int(size)).png"))
}
