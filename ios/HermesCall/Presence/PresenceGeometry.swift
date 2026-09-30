import CoreGraphics
import simd

/// The presence's fixed shape, generated once from a seed so it looks the same on every launch:
/// a filament network (the heart) and an orrery of tilted rings made of data blocks.
enum PresenceGeometry {
    struct Node {
        let position: SIMD3<Float>
        let seed: Float
    }

    /// Radius, tilts, base turns per second (sign = direction), blocks, fill, block height.
    struct Ring {
        let radius: Float
        let tiltX: Float
        let tiltZ: Float
        let speed: Float
        let blocks: Int
        let fill: Float
        let height: Float
    }

    static let nodes: [Node] = {
        var random = SeededRandom(seed: 0x4845_524D_4553)
        let count = 230
        return (0..<count).map { index in
            let y = 1 - 2 * (Double(index) + 0.5) / Double(count)
            let ring = (1 - y * y).squareRoot()
            let angle = Double(index) * .pi * (3 - 5.0.squareRoot()) + random.next() * 0.4
            // Most nodes on the outer shell (the silhouette), some inside for depth.
            let radius = random.next() < 0.65 ? 0.84 + random.next() * 0.12 : 0.3 + random.next() * 0.5
            let position = SIMD3(Float(cos(angle) * ring), Float(y), Float(sin(angle) * ring)) * Float(radius)
            return Node(position: position, seed: Float(random.next()))
        }
    }()

    /// Each node linked to its three nearest neighbours.
    static let edges: [(Int, Int)] = {
        var pairs = Set<[Int]>()
        for (index, node) in nodes.enumerated() {
            let nearest = nodes.indices.filter { $0 != index }
                .sorted { simd_distance(nodes[$0].position, node.position) < simd_distance(nodes[$1].position, node.position) }
                .prefix(3)
            for other in nearest { pairs.insert([min(index, other), max(index, other)]) }
        }
        return pairs.map { ($0[0], $0[1]) }.sorted { $0 < $1 }
    }()

    /// Inner to outer. Rings 0–2 carry data (see `PresenceRing`); 3–4 are plain orbits.
    static let rings: [Ring] = [
        Ring(radius: 0.55, tiltX: 1.15, tiltZ: 0.25, speed: 0.05, blocks: 40, fill: 0.6, height: 0.025),
        Ring(radius: 0.7, tiltX: 0.25, tiltZ: -0.6, speed: -0.035, blocks: 72, fill: 0.4, height: 0.018),
        Ring(radius: 1.02, tiltX: 1.45, tiltZ: -0.15, speed: 0.025, blocks: 56, fill: 0.55, height: 0.03),
        Ring(radius: 1.07, tiltX: -0.7, tiltZ: 0.8, speed: -0.02, blocks: 110, fill: 0.3, height: 0.015),
        Ring(radius: 1.12, tiltX: 1.25, tiltZ: 0.05, speed: 0.015, blocks: 64, fill: 0.5, height: 0.022),
    ]

    // MARK: GPU instance data (layouts match Presence.metal)

    static func edgeInstances() -> [SIMD4<Float>] {
        edges.flatMap { a, b in
            [SIMD4(nodes[a].position, nodes[a].seed), SIMD4(nodes[b].position, nodes[b].seed)]
        }
    }

    /// Hairline tracks: 128 segments per ring.
    static func trackInstances() -> [SIMD4<Float>] {
        rings.flatMap { ring -> [SIMD4<Float>] in
            (0..<128).flatMap { step -> [SIMD4<Float>] in
                let a0 = Float(step) / 128 * 2 * .pi, a1 = Float(step + 1) / 128 * 2 * .pi
                return [SIMD4(point(on: ring, angle: a0, radius: ring.radius), 0), SIMD4(point(on: ring, angle: a1, radius: ring.radius), 0)]
            }
        }
    }

    static func blockInstances() -> [SIMD4<Float>] {
        rings.enumerated().flatMap { ringIndex, ring -> [SIMD4<Float>] in
            let span = 2 * Float.pi / Float(ring.blocks)
            return (0..<ring.blocks).flatMap { block -> [SIMD4<Float>] in
                let seed = fract(sin(Float(block) * 12.9898 + Float(ringIndex) * 78.233) * 43758.5453)
                return [SIMD4(Float(ringIndex), Float(block), Float(block) * span, span), SIMD4(seed, Float(ring.blocks), 0, 0)]
            }
        }
    }

    static func ringInstances() -> [SIMD4<Float>] {
        rings.flatMap { [SIMD4($0.radius, $0.tiltX, $0.tiltZ, $0.height), SIMD4(Float($0.blocks), $0.fill, 0, 0)] }
    }

    static func nodeInstances() -> [SIMD4<Float>] {
        nodes.enumerated().compactMap { index, node in index % 2 == 0 ? SIMD4(node.position, node.seed) : nil }
    }

    // MARK: CPU math (hit-testing; same as the shaders)

    static func point(on ring: Ring, angle: Float, radius: Float) -> SIMD3<Float> {
        var p = SIMD3(cos(angle), 0, sin(angle)) * radius
        p = SIMD3(p.x, p.y * cos(ring.tiltX) - p.z * sin(ring.tiltX), p.y * sin(ring.tiltX) + p.z * cos(ring.tiltX))
        return SIMD3(p.x * cos(ring.tiltZ) - p.y * sin(ring.tiltZ), p.x * sin(ring.tiltZ) + p.y * cos(ring.tiltZ), p.z)
    }

    /// World → points in the view, and depth (+ toward the viewer).
    static func project(_ p: SIMD3<Float>, rotation: simd_float3x3, center: CGPoint, radius: CGFloat) -> (CGPoint, Float) {
        let r = rotation * p
        let perspective = 3.2 / (3.2 - r.z * 0.6)
        return (CGPoint(x: center.x + CGFloat(r.x * perspective) * radius, y: center.y - CGFloat(r.y * perspective) * radius), r.z)
    }

    /// The data ring (0–2) whose visible front passes near `point`, if any.
    static func ring(at point: CGPoint, rotation: simd_float3x3, center: CGPoint, radius: CGFloat,
                     tolerance: CGFloat = 22, candidates: Set<Int>) -> Int? {
        var best: (ring: Int, distance: CGFloat)?
        for index in candidates.sorted() where index < rings.count {
            for step in 0..<96 {
                let (screen, depth) = project(PresenceGeometry.point(on: rings[index], angle: Float(step) / 96 * 2 * .pi,
                                                                     radius: rings[index].radius),
                                              rotation: rotation, center: center, radius: radius)
                guard depth > -0.2 else { continue }
                let distance = hypot(screen.x - point.x, screen.y - point.y)
                if distance < tolerance, distance < (best?.distance ?? .infinity) { best = (index, distance) }
            }
        }
        return best?.ring
    }

    private static func fract(_ x: Float) -> Float { x - x.rounded(.down) }
}

/// Small deterministic generator (SplitMix64) so the shape never changes.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
