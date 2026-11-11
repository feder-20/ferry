import AppKit

// Genera Resources/AppIcon.icns: barco negro sobre baldosa blanca (estilo macOS).
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tile = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGraphicsContext.current?.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor(white: 0, alpha: 0.30)
    sh.shadowBlurRadius = s * 0.025
    sh.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    sh.set()
    NSColor.white.setFill(); path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor(white: 0, alpha: 0.10).setStroke(); path.lineWidth = max(1, s * 0.003); path.stroke()
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
    if let base = NSImage(systemSymbolName: "ferry.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let black = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r); NSColor.black.set(); r.fill(using: .sourceIn); return true
        }
        black.draw(in: NSRect(x: (s - black.size.width) / 2, y: (s - black.size.height) / 2,
                              width: black.size.width, height: black.size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, px) in sizes {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
