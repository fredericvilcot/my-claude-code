// Renders the app icon (clay starburst on a cream tile) into an .iconset directory.
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let lengths: [CGFloat] = [1.0, 0.74, 0.93, 0.69, 0.98, 0.78, 0.9, 0.7, 1.0, 0.76, 0.94, 0.72]
let jitter: [CGFloat] = [0, 4, -3, 2, -2, 5, 0, -4, 3, -1, 2, -3]
func spark(in r: CGRect) -> CGPath {
    let path = CGMutablePath()
    for k in 0..<12 {
        let a = (CGFloat(k) * 30 + jitter[k] + 8) * .pi / 180
        let len = 0.5 * lengths[k]
        let d = CGPoint(x: cos(a), y: sin(a)), n = CGPoint(x: -d.y, y: d.x)
        func p(_ rr: CGFloat, _ w: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + (0.5 + d.x * rr + n.x * w) * r.width, y: r.minY + (0.5 + d.y * rr + n.y * w) * r.height)
        }
        path.addLines(between: [p(0, 0.06), p(len - 0.022, 0.022), p(len, 0), p(len - 0.022, -0.022), p(0, -0.06)])
        path.closeSubpath()
    }
    return path
}
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(spark(in: rect.insetBy(dx: rect.width * 0.17, dy: rect.height * 0.17)))
    ctx.setFillColor(NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor)
    ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
