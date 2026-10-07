import EventKit
import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

/// Callbacks that system frameworks run on their own threads must not be main-actor closures:
/// Swift 6 checks the executor when such a closure starts and traps (the whole test process dies).
@MainActor
@Suite(.serialized) struct AudioThreadTests {
    static let turn: JSON = .object(["urls": .array(["turn:relay.example.com:3478?transport=udp"]), "username": "u", "credential": "c"])

    /// libwebrtc delivers statistics on its signaling thread.
    @Test func callTelemetryIsCollectedOffTheMainActor() async throws {
        let rtc = try WebRTCCall(turn: Self.turn, relayHost: "relay.example.com")
        defer { rtc.close() }
        let telemetry = await rtc.telemetry()
        #expect(telemetry.rttMs == nil)
    }

    /// NSItemProvider answers on its own queue.
    @Test func droppedTextLoadsOffTheMainActor() async {
        let provider = NSItemProvider(object: "hello" as NSString)
        #expect(await DropLoader.text(provider) == "hello")
    }
}

extension AudioThreadTests {
    /// EventKit answers on its own queue (without access: at once, with nothing).
    @Test func remindersAreCollectedOffTheMainActor() async {
        _ = await PhoneSources.openReminders(EKEventStore(), limit: 5)
    }

    /// A VoIP push is reported to CallKit at once; its completion comes from CallKit.
    @Test func incomingPushCompletesWithoutTrapping() async throws {
        let fixture = try ChatFixture()
        let calls = CallCoordinator(app: fixture.app)
        await withCheckedContinuation { continuation in
            calls.reportIncomingPush(callID: Base64URL.encode(Sodium.randomBytes(16))) { continuation.resume() }
        }
        try? await Task.sleep(for: .milliseconds(300))
        calls.hangUp()
    }

    /// CoreHaptics runs its reset handler on an internal queue.
    @Test func hapticsResetRunsOffTheMainActor() async {
        let handler = PresenceHaptics.resetHandler(for: PresenceHaptics())
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                handler()
                continuation.resume()
            }
        }
    }
}
