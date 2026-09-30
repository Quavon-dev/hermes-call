import Foundation
import Testing
@testable import HermesCallCore

@Suite struct CodesTests {
    @Test func parsesTypedCodesWithConfusables() throws {
        let code = try PairingCode(parsing: "r7k-q4mop")
        #expect(code.slot == "R7K" && code.secret == "Q4M0P")
        #expect(try PairingCode(parsing: "ilx 23456").slot == "11X")
    }

    @Test(arguments: ["", "ABC", "ABC-12", "ABC-1234U", "ABC-12345*", String(repeating: "A", count: 30)])
    func rejectsBadCodes(_ text: String) {
        #expect(throws: ProtocolError.self) { try PairingCode(parsing: text) }
    }

    @Test func parsesLinks() throws {
        let pin = String(repeating: "A", count: 43)
        let invite = try PairingInvite(link: "hermescall://pair?v=1&k=device&r=relay.example.com:8443&c=ABC12345&pin=\(pin)")
        #expect(invite.kind == .device && invite.relay == RelayAddress(host: "relay.example.com", port: 8443))
        #expect(invite.pin == pin && invite.code.display == "ABC-12345")
    }

    @Test(arguments: [
        "https://pair?v=1&k=relay&r=a.example&c=ABC12345",
        "hermescall://pair?v=2&k=relay&r=a.example&c=ABC12345",
        "hermescall://pair?v=1&k=admin&r=a.example&c=ABC12345",
        "hermescall://pair?v=1&k=relay&r=evil.example/x&c=ABC12345",
        "hermescall://pair?v=1&k=relay&r=a.example:99999&c=ABC12345",
        "hermescall://pair?v=1&k=relay&r=a.example&c=ABC12345&pin=short",
        "hermescall://pair?v=1&k=relay&r=a.example&c=ABC12345&c=DEF12345",
        "hermescall://pair?v=1&k=relay&r=user@a.example&c=ABC12345",
        "hermescall://pair?v=1&k=relay&r=-bad.example&c=ABC12345",
    ])
    func rejectsBadLinks(_ link: String) {
        #expect(throws: ProtocolError.self) { try PairingInvite(link: link) }
    }

    @Test(arguments: ["relay.example.com:+443", "relay.example.com: 443", "relay.example.com:0443x", "[::1]:+1"])
    func rejectsOddPorts(_ text: String) {
        #expect(throws: ProtocolError.invalidHost) { try RelayAddress(parsing: text) }
    }

    @Test func lowercasesIPv6LikePython() throws {
        #expect(try RelayAddress(parsing: "[2001:DB8::1]:8443").host == "[2001:db8::1]")
    }

    @Test func parsesAddresses() throws {
        #expect(try RelayAddress(parsing: "Relay.Example.COM.") == RelayAddress(host: "relay.example.com", port: 443))
        #expect(try RelayAddress(parsing: "[2001:db8::1]:8443") == RelayAddress(host: "[2001:db8::1]", port: 8443))
        #expect(try RelayAddress(parsing: "203.0.113.7").authority == "203.0.113.7")
    }
}

@Suite struct CryptoTests {
    @Test func base64urlRoundTripAndStrictness() throws {
        let data = Sodium.randomBytes(33)
        #expect(try Base64URL.decode(Base64URL.encode(data)) == data)
        #expect(throws: ProtocolError.self) { try Base64URL.decode("***") }
        #expect(throws: ProtocolError.self) { try Base64URL.decode(Base64URL.encode(data), length: 32) }
    }

    @Test func aeadRejectsTampering() throws {
        let key = Sodium.randomBytes(32)
        var sealed = try Sodium.aeadEncrypt(key: key, plaintext: Data("hi".utf8), ad: Data("ad".utf8))
        #expect(try Sodium.aeadDecrypt(key: key, sealed: sealed, ad: Data("ad".utf8)) == Data("hi".utf8))
        sealed[sealed.count - 1] ^= 1
        #expect(throws: ProtocolError.self) { try Sodium.aeadDecrypt(key: key, sealed: sealed, ad: Data("ad".utf8)) }
    }

    @Test func e2eBindsSenderRecipientAndRejectsReplay() throws {
        let a = try Sodium.boxKeypair(), b = try Sodium.boxKeypair()
        let alice = E2EChannel(myID: "A", secretKey: a.secretKey), bob = E2EChannel(myID: "B", secretKey: b.secretKey)
        let sealed = try alice.seal(to: "B", peerKey: b.publicKey, body: ["type": "offer", "sdp": "x"])
        let body = try bob.open(from: "A", peerKey: a.publicKey, data: sealed)
        #expect(body["sdp"]?.string == "x" && body["ts"]?.int != nil)
        #expect(throws: ProtocolError.self) { try bob.open(from: "A", peerKey: a.publicKey, data: sealed) }
        #expect(throws: ProtocolError.self) {
            try bob.open(from: "A", peerKey: a.publicKey, data: try alice.seal(to: "C", peerKey: b.publicKey, body: ["type": "x"]))
        }
        #expect(throws: ProtocolError.self) { try alice.seal(to: "B", peerKey: b.publicKey, body: ["no": "type"]) }
    }

    @Test func replayProtectionSurvivesARestart() throws {
        let suite = "e2e-test-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let a = try Sodium.boxKeypair(), b = try Sodium.boxKeypair()
        let alice = E2EChannel(myID: "A", secretKey: a.secretKey)
        let sealed = try alice.seal(to: "B", peerKey: b.publicKey, body: ["type": "invite"])
        _ = try E2EChannel(myID: "B", secretKey: b.secretKey, seenStore: store).open(from: "A", peerKey: a.publicKey, data: sealed)
        let restarted = E2EChannel(myID: "B", secretKey: b.secretKey, seenStore: store)
        #expect(throws: ProtocolError.staleOrReplayed) { try restarted.open(from: "A", peerKey: a.publicKey, data: sealed) }
        let fresh = try alice.seal(to: "B", peerKey: b.publicKey, body: ["type": "invite"])
        #expect(try restarted.open(from: "A", peerKey: a.publicKey, data: fresh)["type"]?.string == "invite")
    }

    @Test func signatures() throws {
        let keys = try Sodium.signKeypair()
        let sig = try Sodium.sign(Data("m".utf8), secretKey: keys.secretKey)
        #expect(Sodium.verify(sig, message: Data("m".utf8), publicKey: keys.publicKey))
        #expect(!Sodium.verify(sig, message: Data("n".utf8), publicKey: keys.publicKey))
    }
}

@Suite struct SessionTests {
    @Test(.timeLimit(.minutes(1))) func waitingForAnUnreachableRelayTimesOut() async throws {
        let keys = try DeviceKeys.generate()
        let profile = RelayProfile(id: UUID(), label: "x", relay: RelayAddress(host: "127.0.0.1", port: 9), pin: "",
                                   deviceID: "d", bridgeID: "b", bridgeName: "Hermes",
                                   bridgeBoxKey: Base64URL.encode(Sodium.randomBytes(32)),
                                   bridgeSignKey: Base64URL.encode(Sodium.randomBytes(32)), keys: keys, created: Date())
        let session = try RelaySession(profile: profile)
        let started = Date()
        await #expect(throws: ProtocolError.notConnected) { try await session.waitUntilConnected(timeout: 1) }
        #expect(Date().timeIntervalSince(started) < 5)
        await session.stop()
    }
}
