// Draws the Deckhand app icon (the "Platter" mark: jog-wheel ring, amber cue notch and spindle) into
// an .iconset directory for `iconutil`. Usage: swift Scripts/make-icon.swift <out.iconset>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(pixels px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // Work in a 1024-point, y-down canvas.
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // Tile on Apple's icon grid: 824 pt rounded square, centered, with a soft drop shadow.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(color(0x24242A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x303038), color(0x1C1C21)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // The mark, drawn in its 200-unit design space and scaled into the tile.
    let m: CGFloat = 570 / 200
    ctx.translateBy(x: 512 - 100 * m, y: 512 - 100 * m)
    ctx.scaleBy(x: m, y: m)
    ctx.setStrokeColor(color(0xECECF0))
    ctx.setLineWidth(18)
    ctx.strokeEllipse(in: CGRect(x: 24, y: 24, width: 152, height: 152))
    ctx.setFillColor(color(0xFFB340))
    ctx.fillEllipse(in: CGRect(x: 74, y: 74, width: 52, height: 52))
    ctx.translateBy(x: 100, y: 100)
    ctx.rotate(by: 38 * .pi / 180)
    ctx.translateBy(x: -100, y: -100)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 93, y: 8, width: 14, height: 40), cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.fillPath()

    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: outDir.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: outDir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
