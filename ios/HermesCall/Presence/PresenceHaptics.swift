import AVFoundation
import CoreHaptics
import CoreMotion
import os

/// Touch ticks, and during a call a soft continuous buzz that follows the agent's voice
/// (one continuous event whose intensity is updated, never a new player per frame).
@MainActor
final class PresenceHaptics {
    private var engine: CHHapticEngine?
    private var voice: CHHapticAdvancedPatternPlayer?
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "haptics")

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
        engine?.resetHandler = Self.resetHandler(for: self)
    }

    /// CoreHaptics calls this on its own queue: built outside the main actor, so it is not main-actor code
    /// (Swift 6 traps when another thread runs a closure written in a main-actor context).
    nonisolated static func resetHandler(for haptics: PresenceHaptics) -> @Sendable () -> Void {
        { [weak haptics] in Task { @MainActor in haptics?.voice = nil } }
    }

    func tick(sharpness: Float = 0.7, intensity: Float = 0.6) {
        guard let engine else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0)
        do {
            try engine.start()
            try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {
            log.debug("haptic tick failed")
        }
    }

    /// Starts the voice buzz (call connected); `level` 0…1 from the agent's audio.
    func follow(voice level: Double) {
        guard let engine else { return }
        if voice == nil {
            // A call holds a recording audio session; haptics must be allowed explicitly then.
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
            ], relativeTime: 0, duration: 3600)
            do {
                try engine.start()
                let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                try player.start(atTime: CHHapticTimeImmediate)
                voice = player
            } catch {
                log.debug("voice haptics unavailable")
                return
            }
        }
        let intensity = Float(min(1, max(0, level * 1.6))) * 0.55
        try? voice?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)],
                                   atTime: CHHapticTimeImmediate)
    }

    func stopVoice() {
        try? voice?.stop(atTime: CHHapticTimeImmediate)
        voice = nil
    }
}

/// A few degrees of tilt from the phone's attitude, so the presence feels physical.
@MainActor
final class PresenceMotion {
    private let manager = CMMotionManager()
    private var reference: CMAttitude?
    private(set) var tilt = SIMD2<Float>(0, 0)

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            MainActor.assumeIsolated {
                guard let self, let attitude = motion?.attitude.copy() as? CMAttitude else { return }
                if let reference = self.reference { attitude.multiply(byInverseOf: reference) } else { self.reference = attitude }
                let clamp = { (value: Double) in Float(max(-0.35, min(0.35, value))) * 0.35 }
                self.tilt = SIMD2(clamp(attitude.roll), clamp(attitude.pitch))
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        reference = nil
        tilt = .zero
    }
}
