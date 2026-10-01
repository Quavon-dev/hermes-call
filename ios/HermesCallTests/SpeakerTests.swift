import AVFoundation
import Foundation
import Testing
@testable import HermesCall

/// The presence (HUD) speaks out loud: its calls start on the loudspeaker unless something else
/// (AirPods, headphones, a car) already carries the audio.
@MainActor
struct SpeakerTests {
    @Test func presenceCallsUseTheLoudspeakerWhenOnlyTheEarpieceWouldPlay() {
        #expect(CallAudioRoute.prefersSpeaker(appearance: .hud, enabled: true, outputs: [.builtInReceiver]))
    }

    @Test func otherOutputsAndTheStandardLookKeepTheirRoute() {
        #expect(!CallAudioRoute.prefersSpeaker(appearance: .standard, enabled: true, outputs: [.builtInReceiver]))
        #expect(!CallAudioRoute.prefersSpeaker(appearance: .hud, enabled: false, outputs: [.builtInReceiver]))
        #expect(!CallAudioRoute.prefersSpeaker(appearance: .hud, enabled: true, outputs: [.bluetoothHFP]))
        #expect(!CallAudioRoute.prefersSpeaker(appearance: .hud, enabled: true, outputs: [.headphones]))
        #expect(!CallAudioRoute.prefersSpeaker(appearance: .hud, enabled: true, outputs: [.carAudio]))
        #expect(!CallAudioRoute.prefersSpeaker(appearance: .hud, enabled: true, outputs: [.builtInSpeaker]))
    }

    @Test func theSettingDefaultsToOnAndIsReset() throws {
        let suite = "speaker-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let shared = try #require(UserDefaults(suiteName: suite + ".shared"))
        let preferences = Preferences(defaults: defaults, shared: shared)
        #expect(preferences.presenceSpeaker)
        preferences.presenceSpeaker = false
        #expect(!Preferences(defaults: defaults, shared: shared).presenceSpeaker)
        preferences.reset()
        #expect(Preferences(defaults: defaults, shared: shared).presenceSpeaker)
    }
}
