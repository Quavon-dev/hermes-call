// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HermesCallCore

struct RelayVersionAndCapsTests {
    @Test func authCarriesVersionAndCaps() throws {
        let body = RelayAuth.body(role: "device", identity: "dev", signature: "sig")
        #expect(body["t"]?.string == "auth")
        #expect(body["v"]?.int == Int64(RelayAuth.protocolVersion))
        guard case .array(let caps)? = body["caps"] else { throw ProtocolError.invalidField }
        let names = caps.compactMap(\.string)
        #expect(!names.isEmpty && names.count <= 32)
        #expect(names.allSatisfy(RelayCaps.isValidName))
        #expect(names.contains("unsupported"))
    }

    @Test func capNamesFollowTheRelayRules() {
        #expect(RelayCaps.isValidName("live_activity"))
        #expect(RelayCaps.isValidName("turns"))
        #expect(!RelayCaps.isValidName(""))
        #expect(!RelayCaps.isValidName("Mail"))
        #expect(!RelayCaps.isValidName("a-b"))
        #expect(!RelayCaps.isValidName(String(repeating: "a", count: 33)))
    }

    @Test func readyWithCapsIsParsed() {
        let ready: JSON = ["t": "ready", "v": 1, "relay": "0.7.0", "caps": ["unsupported", "mail", "blobs", "turns", "Bad-Name"]]
        let info = RelayInfo(ready: ready)
        #expect(info.protocolVersion == 1)
        #expect(info.relayVersion == "0.7.0")
        #expect(info.supports("turns"))
        #expect(info.supports("unsupported"))
        #expect(!info.supports("Bad-Name"))
        #expect(!info.supports("live_activity"))
    }

    /// Relays up to 0.6.2 answer a bare `ready`: none of the optional features.
    @Test func bareReadyMeansNoCaps() {
        let info = RelayInfo(ready: ["t": "ready"])
        #expect(info.protocolVersion == nil)
        #expect(info.relayVersion == nil)
        #expect(info.caps.isEmpty)
        #expect(!info.supports("unsupported"))
        #expect(info.displayVersion == "0.6.2 or older")
    }

    @Test func overlongRelayVersionIsCut() {
        let info = RelayInfo(ready: ["t": "ready", "v": 1, "relay": .string(String(repeating: "9", count: 100))])
        #expect((info.relayVersion?.count ?? 0) <= 32)
    }

    /// A new request type goes out only when the relay listed its cap; otherwise it fails locally.
    @Test func requestsNeedingACapAreRefusedWithoutIt() {
        let old = RelayInfo(ready: ["t": "ready"])
        let new = RelayInfo(ready: ["t": "ready", "v": 1, "caps": ["unsupported", "mail"]])
        #expect(old.check(requires: "mail") == .relay("unsupported"))
        #expect(new.check(requires: "mail") == nil)
        #expect(new.check(requires: nil) == nil)
        #expect(new.check(requires: "live_activity") == .relay("unsupported"))
    }

    @Test func unsupportedReplyIsAnError() {
        let reply: JSON = ["t": "error", "code": "unsupported", "type": "future_thing", "rid": 7]
        #expect(RelayReply.error(in: reply) == .relay("unsupported"))
        #expect(RelayReply.error(in: ["t": "turn", "rid": 7]) == nil)
        #expect(ProtocolError.relay("unsupported").isUnsupported)
        #expect(!ProtocolError.relay("offline").isUnsupported)
    }
}

struct RelayReconnectTests {
    /// The relay closes with 1001 when it shuts down (restart, update): come back quickly, not after the max backoff.
    @Test func goingAwayReconnectsPromptly() {
        let step = RelayBackoff.after(closeCode: 1001, backoff: 30)
        #expect(step.pause <= 3)
        #expect(step.next == 1)
    }

    @Test func otherFailuresBackOffUpToThirtySeconds() {
        let first = RelayBackoff.after(closeCode: nil, backoff: 1)
        #expect(first.pause >= 1 && first.pause <= 1.5)
        #expect(first.next == 2)
        #expect(RelayBackoff.after(closeCode: 1006, backoff: 30).next == 30)
        #expect(RelayBackoff.after(closeCode: 1006, backoff: 16).next == 30)
    }
}

struct BlobBusyRetryTests {
    actor Attempts {
        var statuses: [Int]
        var calls = 0
        var sleeps: [Duration] = []
        init(_ statuses: [Int]) { self.statuses = statuses }
        func next() -> Int {
            calls += 1
            return statuses.isEmpty ? 200 : statuses.removeFirst()
        }
        func slept(_ duration: Duration) { sleeps.append(duration) }
    }

    @Test func busyUploadIsRetriedWithTheSameTicket() async throws {
        let attempts = Attempts([503, 503, 200])
        let data = try await BlobRetry.run(maxAttempts: 5, sleep: { await attempts.slept($0) }) {
            (Data("ok".utf8), await attempts.next())
        }
        #expect(data == Data("ok".utf8))
        #expect(await attempts.calls == 3)
        let sleeps = await attempts.sleeps
        #expect(sleeps.count == 2)
        #expect(sleeps[1] > sleeps[0])
    }

    @Test func busyForeverGivesUpAfterMaxAttempts() async {
        let attempts = Attempts(Array(repeating: 503, count: 10))
        await #expect(throws: ProtocolError.relay("busy")) {
            _ = try await BlobRetry.run(maxAttempts: 3, sleep: { await attempts.slept($0) }) {
                (Data(), await attempts.next())
            }
        }
        #expect(await attempts.calls == 3)
    }

    @Test func otherStatusesFailAtOnce() async {
        let attempts = Attempts([403])
        await #expect(throws: ProtocolError.unexpected("blob HTTP 403")) {
            _ = try await BlobRetry.run(maxAttempts: 5, sleep: { await attempts.slept($0) }) {
                (Data(), await attempts.next())
            }
        }
        #expect(await attempts.calls == 1)
    }

    @Test func pausesStayWithinTheTicketLifetime() {
        let total = (1...BlobRetry.maxUploadAttempts).map { BlobRetry.pause(before: $0) }
            .reduce(Duration.zero, +)
        #expect(total < .seconds(Int(BlobRetry.deadline)))
        #expect(BlobRetry.deadline == 300)
        #expect(BlobRetry.downloadUsesPerTicket == 3)
    }
}

struct TURNServerTests {
    @Test func allRelayURLsIncludingTURNSReachICE() throws {
        let reply: JSON = ["t": "turn", "urls": ["turn:relay.example.com:3478?transport=udp", "turn:relay.example.com:3478?transport=tcp",
                                                 "turns:relay.example.com:5349?transport=tcp", "turn:evil.example:3478"],
                           "username": "u", "credential": "c", "ttl": 5400]
        let servers = try TURNServers(reply: reply, relayHost: "relay.example.com")
        #expect(servers.urls == ["turn:relay.example.com:3478?transport=udp", "turn:relay.example.com:3478?transport=tcp",
                                 "turns:relay.example.com:5349?transport=tcp"])
        #expect(servers.username == "u")
        #expect(servers.credential == "c")
        #expect(servers.ttl == 5400)
    }

    @Test func noURLOnTheRelayHostIsRefused() {
        let reply: JSON = ["t": "turn", "urls": ["turn:evil.example:3478"], "username": "u", "credential": "c"]
        #expect(throws: ProtocolError.self) { try TURNServers(reply: reply, relayHost: "relay.example.com") }
        #expect(throws: ProtocolError.self) { try TURNServers(reply: ["t": "turn"], relayHost: "relay.example.com") }
    }

    @Test func hostMatchingIsStrict() {
        #expect(TURNServers.isRelayTURN("turns:Relay.Example.com:5349?transport=tcp", host: "relay.example.com"))
        #expect(TURNServers.isRelayTURN("turn:[2001:db8::1]:3478", host: "[2001:db8::1]"))
        #expect(!TURNServers.isRelayTURN("stun:relay.example.com:3478", host: "relay.example.com"))
        #expect(!TURNServers.isRelayTURN("turn:relay.example.com.evil.example:3478", host: "relay.example.com"))
    }
}

struct PairingDeviceLimitTests {
    @Test func tooManyDevicesIsItsOwnFailure() {
        #expect(PairingFailure.classify(ProtocolError.relay("too_many_devices")) == .tooManyDevices)
    }
}
