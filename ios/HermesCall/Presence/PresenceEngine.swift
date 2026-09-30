import CoreGraphics
import HermesCallCore
import QuartzCore
import simd

/// What a data ring shows (Presence.metal colours lit blocks by kind).
enum PresenceRingKind: Float, Sendable {
    case plain = 0, messages = 1, requests = 2, results = 3, tasks = 4
}

struct PresenceRingState: Equatable, Sendable {
    var kind = PresenceRingKind.plain
    /// Lit blocks (0 = quiet ring).
    var lit = 0
    var focused = false
    /// Tasks ring: a wave runs through the lit blocks while the agent works.
    var active = false
}

/// The presence's live state, stepped once per frame by the renderer. SwiftUI sets the inputs;
/// everything visible moves through springs, so state changes never jump.
@MainActor
final class PresenceEngine {
    // MARK: inputs

    var mood = PresenceMood.State.idle
    /// A call is live: full energy; otherwise the presence rests (dimmer, slower).
    var inCall = false
    var agentLevel = 0.0
    var micLevel = 0.0
    var rings = Array(repeating: PresenceRingState(), count: PresenceGeometry.rings.count)
    var reduceMotion = false
    /// Device tilt for parallax (radians, small), read every frame.
    var tiltSource: (@MainActor () -> SIMD2<Float>)?
    /// Real voice bands (8, 0…1) from the audio that is playing, read every frame; nil = shape them from `agentLevel`.
    var bandSource: (@MainActor () -> [Float]?)?
    /// Voice levels (agent, owner; 0…1) read every frame while `inCall`; nil = the call is still linking
    /// (the presence "thinks"). They set `agentLevel`, `micLevel` and `mood`, so nothing has to poll.
    var levelSource: (@MainActor () -> (agent: Double, mic: Double)?)?
    /// The mood changed (for the labels around the presence).
    var onMood: ((PresenceMood.State) -> Void)?
    /// The agent's voice level, at most `voiceRate` times a second (haptics).
    var onVoice: ((Double) -> Void)?
    static let voiceRate = 15.0
    private var inferred = PresenceMood()
    private var lastVoice: CFTimeInterval = 0
    /// The agent's colour; changes blend over half a second.
    var palette = AgentPalette.gold
    /// Sphere placement in the view, in points (glides to the target set by `place`).
    private(set) var center = CGPoint(x: 200, y: 400)
    private(set) var radius: CGFloat = 160
    private var targetCenter: CGPoint?
    private var targetRadius: CGFloat = 160

    static let assembleSeconds = 1.8
    static let breakSeconds = 1.3
    /// Breaking apart, then the presence forms again (at rest) after this pause.
    static let reformDelay = 0.5

    // MARK: state

    private let start = CACurrentMediaTime()
    private var last: CFTimeInterval?
    private var assemblyStart: CFTimeInterval
    private var breakStart: CFTimeInterval?
    private var flashStart: CFTimeInterval?
    private var doneFlashStart: CFTimeInterval?
    private var absorbUntil: CFTimeInterval = 0
    private var yaw: Float = 0
    private var pitchOffset: Float = 0
    private var spin = SIMD2<Float>(0, 0)
    private var phases = Array(repeating: Float(0), count: PresenceGeometry.rings.count)
    private var smooth = Smoothed()
    private(set) var rotation = matrix_identity_float3x3

    private struct Smoothed {
        var voice: Float = 0, mic: Float = 0, energy: Float = 0.45, thinking: Float = 0, listening: Float = 0
        var speaking: Float = 0, pace: Float = 0.5, pitch: Float = -0.35, room: Float = 0.5
        var bands = [Float](repeating: 0, count: 8)
        var focus = [Float](repeating: 0, count: PresenceGeometry.rings.count)
        var colors = PresenceEngine.colors(.gold)
        var absorb: Float = 0
        var taskWave: Float = 0
    }

    init() {
        assemblyStart = CACurrentMediaTime()
    }

    /// Where the sphere sits; `animated: false` jumps (first layout).
    func place(center: CGPoint, radius: CGFloat, animated: Bool) {
        if !animated || targetCenter == nil {
            self.center = center
            self.radius = radius
        }
        targetCenter = center
        targetRadius = radius
    }

    // MARK: lifecycle and gestures

    /// Blocks stream in from everywhere and lock into place, then the heart ignites.
    func assemble() {
        breakStart = nil
        assemblyStart = CACurrentMediaTime()
    }

    /// The heart flares (a call starts, the owner interrupts).
    func ignite() { flashStart = CACurrentMediaTime() }

    /// Something flows into the presence (a photo it is shown): motes stream into the heart for a moment.
    func absorb(seconds: Double = 1.4) {
        absorbUntil = CACurrentMediaTime() + seconds
        ignite()
    }

    /// Stills: the energy of a live call at once (brighter heart, full room light).
    func energize() {
        inCall = true
        smooth.energy = 1
        smooth.room = 1
    }

    /// Stills: no room light behind the sphere (it would show as a square).
    var roomLight = true

    /// Fully formed at once (stills for widgets).
    func settle() {
        breakStart = nil
        assemblyStart = CACurrentMediaTime() - Self.assembleSeconds * 2
    }

    /// Jumps to `palette` without blending (first appearance).
    func snapPalette() { smooth.colors = Self.colors(palette) }

    /// The tasks ring flashes white once (the agent finished).
    func taskFinished() { doneFlashStart = CACurrentMediaTime() }

    /// The rings unravel and drift off; the room goes dark last. Re-forms at rest afterwards.
    func breakApart() {
        guard breakStart == nil else { return }
        breakStart = CACurrentMediaTime()
    }

    var isBroken: Bool { breakStart != nil }

    /// Dragging turns the orrery; releasing lets it spin down.
    func drag(by translation: CGSize, scale: CGFloat) {
        let k = Float(1 / max(scale, 1)) * 1.6
        yaw += Float(translation.width) * k
        pitchOffset = max(-1.1, min(1.1, pitchOffset + Float(translation.height) * k))
        spin = .zero
    }

    func fling(velocity: CGSize, scale: CGFloat) {
        let k = Float(1 / max(scale, 1)) * 1.6
        spin = SIMD2(Float(velocity.width) * k, Float(velocity.height) * k * 0.4)
    }

    // MARK: per frame

    /// Uniform slots for Presence.metal (see its header), for a drawable of `size` pixels.
    func step(drawable size: CGSize, scale: CGFloat) -> [SIMD4<Float>] {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, now - (last ?? now)))
        last = now
        let t = Float((now - start).truncatingRemainder(dividingBy: 3600))

        var assembly = Float(min(1, max(0, (now - assemblyStart) / Self.assembleSeconds)))
        var breakup: Float = 0
        if let breakStart {
            breakup = Float(min(1, max(0, (now - breakStart) / Self.breakSeconds)))
            if now - breakStart > Self.breakSeconds + Self.reformDelay {
                self.breakStart = nil
                assemblyStart = now
                assembly = 0
                breakup = 0
            }
        }
        if reduceMotion {
            // No flying blocks: just fade in and out.
            let fade = breakup
            breakup = 0
            assembly = min(assembly * 2, 1) * (1 - fade)
        }
        let flash = flashStart.map { Float(max(0, 1 - (now - $0) / 0.6)) } ?? 0
        readLevels(now: now)

        let thinking: Float = mood == .thinking ? 1 : 0
        let listening: Float = mood == .listening ? 1 : 0
        let speaking: Float = mood == .speaking ? 1 : 0
        approach(&smooth.voice, Float(min(1, agentLevel * 2)), rate: 14, dt)
        approach(&smooth.mic, Float(min(1, micLevel * 2)), rate: 14, dt)
        approach(&smooth.energy, inCall ? 1 : 0.45, rate: 2.5, dt)
        approach(&smooth.thinking, thinking, rate: 3, dt)
        approach(&smooth.listening, listening, rate: 4, dt)
        approach(&smooth.speaking, speaking, rate: 5, dt)
        if !roomLight { smooth.room = 0 }
        approach(&smooth.room, !roomLight ? 0 : breakStart == nil ? (inCall ? 1 : 0.55) : 0, rate: breakStart == nil ? 1.5 : 0.8, dt)
        // Listening: the rings slow and turn toward you; thinking: slow, counter-rotating.
        let pace = (inCall ? 1 : 0.45) * (1 - smooth.listening * 0.55) * (1 - smooth.thinking * 0.3) * (1 + smooth.voice * 1.5)
        approach(&smooth.pace, pace, rate: 3, dt)
        approach(&smooth.pitch, -0.35 * (1 - smooth.listening * 0.8) + 0.05 * sin(t * 0.3), rate: 2, dt)
        let live = bandSource?()
        for index in 0..<8 {
            if let live, live.count == 8 {
                // The real spectrum of what is playing (already smoothed by the analyzer).
                smooth.bands[index] = live[index]
            } else {
                // Voice bands: the agent's level shaped into a moving spectrum.
                let shape = 0.55 + 0.45 * sin(t * (3 + Float(index) * 1.7) + Float(index) * 2.1)
                approach(&smooth.bands[index], smooth.voice * shape, rate: 18, dt)
            }
        }
        let target = Self.colors(palette)
        for index in smooth.colors.indices {
            smooth.colors[index] += (target[index] - smooth.colors[index]) * (1 - exp(-6 * dt))
        }
        approach(&smooth.absorb, now < absorbUntil ? 1 : 0, rate: now < absorbUntil ? 6 : 2.5, dt)
        approach(&smooth.taskWave, rings.contains { $0.kind == .tasks && $0.active } ? 1 : 0, rate: 3, dt)
        let doneFlash = doneFlashStart.map { Float(max(0, 1 - (now - $0) / 0.9)) } ?? 0
        for index in rings.indices { approach(&smooth.focus[index], rings[index].focused ? 1 : 0, rate: 8, dt) }

        // Spin: base drift plus the owner's fling, decaying.
        yaw += (0.12 * smooth.pace + spin.x) * dt
        pitchOffset = max(-1.1, min(1.1, pitchOffset + spin.y * dt))
        spin *= max(0, 1 - dt * 1.8)
        pitchOffset *= spin == .zero ? max(0, 1 - dt * 0.6) : 1
        for (index, ring) in PresenceGeometry.rings.enumerated() {
            let direction: Float = index % 2 == 1 ? (1 - 2 * smooth.thinking) : 1
            phases[index] += ring.speed * 2 * .pi * smooth.pace * direction * (1 + smooth.thinking * 0.6) * dt
            phases[index] = phases[index].truncatingRemainder(dividingBy: 2 * .pi)
        }
        let tilt = reduceMotion ? SIMD2<Float>(0, 0) : (tiltSource?() ?? .zero)
        rotation = Self.rotation(yaw: yaw + tilt.x, pitch: smooth.pitch + pitchOffset + tilt.y)
        if let targetCenter {
            let k = CGFloat(1 - exp(-6 * dt))
            center = CGPoint(x: center.x + (targetCenter.x - center.x) * k, y: center.y + (targetCenter.y - center.y) * k)
            radius += (targetRadius - radius) * k
        }

        let formed = Self.ease(min(1, assembly * 1.3)) * (1 - breakup) * (reduceMotion ? assembly : 1)
        let ignition = Self.ease((assembly - 0.55) / 0.45)
        let px = Float(scale)
        var u = [SIMD4<Float>](repeating: .zero, count: Self.uniformCount)
        u[0] = SIMD4(Float(size.width), Float(size.height), Float(radius) * px, t)
        u[1] = SIMD4(Float(center.x) * px, Float(center.y) * px, px, smooth.energy)
        u[2] = SIMD4(smooth.voice, smooth.mic, assembly, breakup)
        u[3] = SIMD4(smooth.thinking, smooth.listening, smooth.speaking, ignition)
        u[4] = SIMD4(rotation[0][0], rotation[1][0], rotation[2][0], 0)
        u[5] = SIMD4(rotation[0][1], rotation[1][1], rotation[2][1], 0)
        u[6] = SIMD4(rotation[0][2], rotation[1][2], rotation[2][2], 0)
        u[7] = SIMD4(phases[0], phases[1], phases[2], phases[3])
        u[8] = SIMD4(phases[4], flash, smooth.room, formed)
        for index in 0..<min(5, rings.count) {
            // z: the tasks ring's running wave (0…1) plus its done flash (+1…2).
            let pulse = rings[index].kind == .tasks ? smooth.taskWave + (doneFlash > 0 ? 1 + doneFlash : 0) : 0
            u[9 + index] = SIMD4(Float(rings[index].lit), rings[index].kind.rawValue, pulse, smooth.focus[index])
        }
        u[14] = SIMD4(smooth.bands[0], smooth.bands[1], smooth.bands[2], smooth.bands[3])
        u[15] = SIMD4(smooth.bands[4], smooth.bands[5], smooth.bands[6], smooth.bands[7])
        for index in 0..<4 { u[16 + index] = SIMD4(smooth.colors[index], 0) }
        u[20] = SIMD4(smooth.absorb, 0, 0, 0)
        return u
    }

    /// Voice levels and mood from `levelSource`, once per frame.
    private func readLevels(now: CFTimeInterval) {
        guard let levelSource else { return }
        let previous = mood
        if inCall, let levels = levelSource() {
            agentLevel = levels.agent
            micLevel = levels.mic
            inferred.update(agent: levels.agent, mic: levels.mic, muted: false)
            mood = inferred.state
            if now - lastVoice >= 1 / Self.voiceRate {
                lastVoice = now
                onVoice?(levels.agent)
            }
        } else if inCall {
            mood = .thinking
        } else {
            inferred = PresenceMood()
            mood = .idle
            agentLevel = 0
            micLevel = 0
        }
        if mood != previous { onMood?(mood) }
    }

    /// Slots in `step`'s result (Presence.metal's header documents them).
    static let uniformCount = 21

    /// glow, light, alert, ember.
    nonisolated static func colors(_ palette: AgentPalette) -> [SIMD3<Float>] {
        [palette.glow, palette.light, palette.alert, palette.ember].map { SIMD3($0.r, $0.g, $0.b) }
    }

    /// Pitch about x after yaw about y (M·p, as the shaders' rows).
    static func rotation(yaw: Float, pitch: Float) -> simd_float3x3 {
        let (sy, cy) = (sin(yaw), cos(yaw)), (sx, cx) = (sin(pitch), cos(pitch))
        let ry = simd_float3x3(rows: [SIMD3(cy, 0, sy), SIMD3(0, 1, 0), SIMD3(-sy, 0, cy)])
        let rx = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cx, -sx), SIMD3(0, sx, cx)])
        return rx * ry
    }

    static func ease(_ x: Float) -> Float {
        let v = min(1, max(0, x))
        return v * v * (3 - 2 * v)
    }

    /// Critically damped approach, frame-rate independent.
    private func approach(_ value: inout Float, _ target: Float, rate: Float, _ dt: Float) {
        value += (target - value) * (1 - exp(-rate * dt))
    }

    // MARK: hit-testing (points in the view)

    func isInHeart(_ point: CGPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) < radius * 0.5
    }

    func isOnSphere(_ point: CGPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) < radius * 1.15
    }

    /// The data ring touched at `point` (only rings that show something).
    func ring(at point: CGPoint) -> Int? {
        let candidates = Set(rings.indices.filter { rings[$0].kind != .plain && rings[$0].lit > 0 })
        guard !candidates.isEmpty else { return nil }
        return PresenceGeometry.ring(at: point, rotation: rotation, center: center, radius: radius, candidates: candidates)
    }
}
