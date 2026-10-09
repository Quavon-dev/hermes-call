// SPDX-License-Identifier: MIT
import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

/// The app side of the relay's versions, caps and new errors.
@MainActor
struct RelayClientTests {
    @Test func tooManyDevicesHasItsOwnPairingMessage() {
        let limit = AddRelayView.explain(.tooManyDevices, relay: "relay.example.com")
        #expect(limit.contains("as many phones"))
        let others: [PairingFailure] = [.invalidInput, .unreachable, .tlsMismatch, .tlsFailed(-1200), .rateLimited, .relayBusy, .wrongOrExpiredCode, .other]
        #expect(others.allSatisfy { AddRelayView.explain($0, relay: "relay.example.com") != limit })
    }

    @Test func callsKeepTURNSOnTheRelayHost() {
        #expect(WebRTCCall.isRelayTURN("turns:relay.example.com:5349?transport=tcp", host: "relay.example.com"))
        #expect(!WebRTCCall.isRelayTURN("turns:other.example:5349?transport=tcp", host: "relay.example.com"))
    }
}
