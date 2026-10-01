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

    @Test func networkChangeReoffersRightAway() {
        var machine = CallReconnect(supported: true)
        #expect(machine.networkChanged(now: t0) == .reoffer)
        #expect(machine.isReconnecting)
        #expect(machine.networkChanged(now: t0.addingTimeInterval(1)) == .none, "not twice within the retry interval")
        #expect(machine.networkChanged(now: t0.addingTimeInterval(CallReconnect.retryInterval + 0.1)) == .reoffer)
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
