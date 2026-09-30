import SwiftUI

/// A light presence for small screens (watch face, complications, CarPlay-free places): tilted rings of
/// blocks around a glowing heart, drawn with Canvas. `time` turns the rings; `energy` 0…1 brightens it.
enum PresenceSketch {
    static func draw(_ context: inout GraphicsContext, size: CGSize, time: Double, glow: Color, light: Color, ember: Color,
                     energy: Double = 0.5) {
        let r = min(size.width, size.height) / 2 * 0.92
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.blendMode = .plusLighter
        let rings: [(radius: Double, tilt: Double, squash: Double, blocks: Int, speed: Double)] = [
            (0.62, 1.1, 0.34, 28, 0.05), (0.78, -0.5, 0.5, 36, -0.035), (0.95, 0.25, 0.22, 48, 0.025),
        ]
        for ring in rings {
            let span = 2 * Double.pi / Double(ring.blocks)
            let phase = time * ring.speed * 2 * .pi
            for index in 0..<ring.blocks {
                let angle = Double(index) * span + phase
                let front = sin(angle) > 0
                var path = Path()
                path.addArc(center: .zero, radius: 1, startAngle: .radians(angle), endAngle: .radians(angle + span * 0.6),
                            clockwise: false)
                let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: ring.tilt)
                    .scaledBy(x: r * ring.radius, y: r * ring.radius * ring.squash)
                let color = front ? glow.opacity(0.55 + 0.4 * energy) : ember.opacity(0.9)
                context.stroke(path.applying(transform), with: .color(color), lineWidth: max(1, r * (front ? 0.07 : 0.05)))
            }
        }
        let pulse = 1 + 0.08 * sin(time * 2.2) + 0.25 * energy
        let bloom = r * 0.42 * pulse
        context.fill(Path(ellipseIn: CGRect(x: center.x - bloom, y: center.y - bloom, width: bloom * 2, height: bloom * 2)),
                     with: .radialGradient(Gradient(colors: [.white, light, glow.opacity(0.45), .clear]),
                                           center: center, startRadius: 0, endRadius: bloom))
    }
}
