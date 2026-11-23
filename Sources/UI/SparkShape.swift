import AppKit
import SwiftUI

/// Starburst glyph: twelve tapered rays of irregular length radiating from the centre.
enum SparkGeometry {
    private static let lengths: [CGFloat] = [1.0, 0.74, 0.93, 0.69, 0.98, 0.78, 0.9, 0.7, 1.0, 0.76, 0.94, 0.72]
    private static let jitter: [CGFloat] = [0, 4, -3, 2, -2, 5, 0, -4, 3, -1, 2, -3]

    /// One closed polygon per ray, in a unit square centred on (0.5, 0.5).
    static func rays() -> [[CGPoint]] {
        (0..<12).map { k in
            let angle = (CGFloat(k) * 30 + jitter[k] + 8) * .pi / 180
            let length = 0.5 * lengths[k]
            let inner: CGFloat = 0, baseHalf: CGFloat = 0.06, tipHalf: CGFloat = 0.022
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let normal = CGPoint(x: -dir.y, y: dir.x)
            func p(_ r: CGFloat, _ w: CGFloat) -> CGPoint {
                CGPoint(x: 0.5 + dir.x * r + normal.x * w, y: 0.5 + dir.y * r + normal.y * w)
            }
            return [p(inner, baseHalf), p(length - tipHalf, tipHalf), p(length, 0), p(length - tipHalf, -tipHalf), p(inner, -baseHalf)]
        }
    }

    static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for ray in rays() {
            let pts = ray.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            path.addLines(between: pts)
            path.closeSubpath()
        }
        return path
    }
}

struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path { Path(SparkGeometry.path(in: rect)) }
}

/// Clay starburst used in the header.
struct SparkGlyph: View {
    var size: CGFloat
    var color: Color = Theme.clay
    var body: some View {
        SparkShape().fill(color, style: FillStyle(eoFill: false)).frame(width: size, height: size)
    }
}

extension SparkIcon {
    static func starburst(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(SparkGeometry.path(in: rect.insetBy(dx: 0.5, dy: 0.5)))
            ctx.setFillColor(active ? NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor : NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = !active
        return image
    }
}
