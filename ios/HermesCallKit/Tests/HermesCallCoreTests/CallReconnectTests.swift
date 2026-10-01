// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HermesCallCore

/// C1: the call's reconnect state machine (network handover → re-offer for the same call id).
struct CallReconnectTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func failedMediaReoffersAtOnceWhenTheBridgeCanResume() {
        var machine = CallReconnect(supported: true)
        #expect(machine.mediaFailed(now: t0) == .reoffer)
        #expect(machine.isReconnecting)
        #expect(machine.mediaConnected() == .recovered)
        #expect(!machine.isReconnecting)
    }

    @Test func withoutTheCapAFailureEndsTheCallAsBefore() {
        var machine = CallReconnect(supported: false)
        #expect(machine.mediaDisconnected(now: t0) == .none)
        #expect(!machine.isReconnecting)
        #expect(machine.networkChanged(now: t0) == .none)
        #expect(machine.mediaFailed(now: t0) == .end(.mediaFailed))
    }

    @Test func aShortDisconnectMayHealByItself() {
        var machine = CallReconnect(supported: true)
        #expect(machine.mediaDisconnected(now: t0) == .none)
        #expect(machine.isReconnecting, "the call screen says Reconnecting… at once")
        #expect(machine.tick(now: t0.addingTimeInterval(1)) == .none)
        #expect(machine.mediaConnected() == .recovered)
        #expect(machine.tick(now: t0.addingTimeInterval(5)) == .none)
    }

    @Test func aLongerDisconnectReoffersAfterTheGrace() {
        var machine = CallReconnect(supported: true)
        _ = machine.mediaDisconnected(now: t0)
        #expect(machine.tick(now: t0.addingTimeInterval(CallReconnect.disconnectGrace + 0.1)) == .reoffer)
        #expect(machine.tick(now: t0.addingTimeInterval(CallReconnect.disconnectGrace + 0.2)) == .none, "one offer at a time")
    }

    @Test func aNetworkChangeLeavesAHealthyCallAlone() {
        // The bridge closes its connection when a re-offer arrives: re-offering a working call would break it.
        var machine = CallReconnect(supported: true)
        #expect(machine.networkChanged(now: t0) == .none)
        #expect(!machine.isReconnecting)
        #expect(machine.needsClock, "the health is checked after the grace")
        #expect(machine.tick(now: t0.addingTimeInterval(1), healthy: false) == .none, "not before the grace")
        #expect(machine.tick(now: t0.addingTimeInterval(CallReconnect.disconnectGrace + 0.1), healthy: true) == .none)
        #expect(!machine.isReconnecting && !machine.needsClock)
        #expect(machine.tick(now: t0.addingTimeInterval(CallReconnect.window + 1), healthy: true) == .none)
    }

    @Test func aNetworkChangeThatBrokeTheAudioReoffersAfterTheGrace() {
        var machine = CallReconnect(supported: true)
        #expect(machine.networkChanged(now: t0) == .none)
        let checked = t0.addingTimeInterval(CallReconnect.disconnectGrace + 0.1)
        #expect(machine.tick(now: checked, healthy: false) == .reoffer)
        #expect(machine.isReconnecting)
        #expect(machine.networkChanged(now: checked.addingTimeInterval(1)) == .none)
        #expect(machine.tick(now: checked.addingTimeInterval(1), healthy: false) == .none, "not twice within the retry interval")
        #expect(machine.tick(now: checked.addingTimeInterval(CallReconnect.retryInterval + 0.1), healthy: false) == .reoffer)
    }

    @Test func aBrokenCallWhoseAudioFlowsAgainRecoversInsteadOfEnding() {
        // E.g. the re-offer could not be sent but the old connection kept working.
        var machine = CallReconnect(supported: true)
        _ = machine.mediaFailed(now: t0)
        _ = machine.reofferFailed(now: t0.addingTimeInterval(1))
        #expect(machine.tick(now: t0.addingTimeInterval(2), healthy: true) == .recovered)
        #expect(!machine.isReconnecting)
        #expect(machine.tick(now: t0.addingTimeInterval(CallReconnect.window + 1), healthy: true) == .none, "never ends a call with audio")
    }

    @Test func aReofferWaitsForItsAnswerLessThanTheRetryInterval() {
        #expect(CallReconnect.answerTimeout < CallReconnect.retryInterval)
        #expect(CallReconnect.answerTimeout + CallReconnect.retryAfterFailure <= CallReconnect.retryInterval)
    }

    @Test func aFailedReofferIsRetriedSoonSoTheWindowHoldsSeveralAttempts() {
        var machine = CallReconnect(supported: true)
        #expect(machine.mediaFailed(now: t0) == .reoffer)
        // No answer within the answer timeout.
        let failed = t0.addingTimeInterval(CallReconnect.answerTimeout + 0.5)
        #expect(machine.reofferFailed(now: failed) == .none)
        #expect(machine.tick(now: failed.addingTimeInterval(CallReconnect.retryAfterFailure + 0.1)) == .reoffer)
        var offers = 1
        var now = failed.addingTimeInterval(CallReconnect.retryAfterFailure + 0.1)
        while now.timeIntervalSince(t0) < CallReconnect.window - 1 {
            now = now.addingTimeInterval(1)
            if machine.tick(now: now) == .reoffer { offers += 1 }
        }
        #expect(offers >= 3, "at least three attempts before giving up (got \(offers))")
    }

    @Test func aReofferThatGetsNoMediaIsRepeatedThenGivenUp() {
        var machine = CallReconnect(supported: true)
        _ = machine.mediaFailed(now: t0)
        #expect(machine.tick(now: t0.addingTimeInterval(CallReconnect.retryInterval + 0.1)) == .reoffer)
        #expect(machine.tick(now: t0.addingTimeInterval(CallReconnect.window + 0.1)) == .end(.connectionLost))
        #expect(machine.tick(now: t0.addingTimeInterval(CallReconnect.window + 1)) == .none, "ends once")
    }

    @Test func aFailedReofferCountsAsNoMedia() {
        var machine = CallReconnect(supported: true)
        _ = machine.mediaFailed(now: t0)
        #expect(machine.reofferFailed(now: t0.addingTimeInterval(1)) == .none)
        #expect(machine.tick(now: t0.addingTimeInterval(CallReconnect.retryInterval + 1.1)) == .reoffer)
    }

    @Test func endReasonsAreReadable() {
        #expect(CallReconnect.EndReason.connectionLost.text == "Connection lost. The call could not be resumed.")
        #expect(CallReconnect.EndReason.mediaFailed.text == "The audio connection failed.")
    }
}
