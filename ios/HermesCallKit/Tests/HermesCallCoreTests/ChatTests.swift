import Foundation
import Testing
@testable import HermesCallCore

struct ChatTests {
    let bridgeKeys = try! Sodium.boxKeypair()
    let deviceKeys = try! Sodium.boxKeypair()

    func channels(mailStore: UserDefaults? = nil) -> (bridge: E2EChannel, device: E2EChannel) {
        (E2EChannel(myID: "B", secretKey: bridgeKeys.secretKey),
         E2EChannel(myID: "D", secretKey: deviceKeys.secretKey, mailStore: mailStore))
    }

    @Test func mailIsAcceptedOnceInAnyOrder() throws {
        let (bridge, device) = channels()
        let first = try bridge.seal(to: "D", peerKey: deviceKeys.publicKey, body: ["type": "chat"], mid: E2EChannel.newMessageID())
        let second = try bridge.seal(to: "D", peerKey: deviceKeys.publicKey, body: ["type": "chat"], mid: E2EChannel.newMessageID())
        _ = try device.open(from: "B", peerKey: bridgeKeys.publicKey, data: second)
        _ = try device.open(from: "B", peerKey: bridgeKeys.publicKey, data: first)
        #expect(throws: ProtocolError.staleOrReplayed) { try device.open(from: "B", peerKey: bridgeKeys.publicKey, data: first) }
    }

    @Test func peekDoesNotConsumeButSeesReplays() throws {
        let store = UserDefaults(suiteName: "hermescall.tests.\(UUID().uuidString)")!
        let (bridge, device) = channels(mailStore: store)
        let sealed = try bridge.seal(to: "D", peerKey: deviceKeys.publicKey, body: ["type": "chat", "text": "hi"],
                                     mid: E2EChannel.newMessageID())
        let extensionChannel = E2EChannel(myID: "D", secretKey: deviceKeys.secretKey, mailStore: store)
        #expect(try extensionChannel.peekMail(from: "B", peerKey: bridgeKeys.publicKey, data: sealed)["text"]?.string == "hi")
        _ = try device.open(from: "B", peerKey: bridgeKeys.publicKey, data: sealed)
        #expect(throws: ProtocolError.staleOrReplayed) {
            try extensionChannel.peekMail(from: "B", peerKey: bridgeKeys.publicKey, data: sealed)
        }
        // A restarted app still rejects it.
        let restarted = E2EChannel(myID: "D", secretKey: deviceKeys.secretKey, mailStore: store)
        #expect(throws: ProtocolError.staleOrReplayed) { try restarted.open(from: "B", peerKey: bridgeKeys.publicKey, data: sealed) }
    }

    @Test func mailIsOnlyConsumedWhenMarked() throws {
        let store = UserDefaults(suiteName: "hermescall.tests.\(UUID().uuidString)")!
        let (bridge, _) = channels()
        let device = E2EChannel(myID: "D", secretKey: deviceKeys.secretKey, mailStore: store)
        let mid = E2EChannel.newMessageID()
        let sealed = try bridge.seal(to: "D", peerKey: deviceKeys.publicKey, body: ["type": "chat"], mid: mid)
        let body = try device.peekMail(from: "B", peerKey: bridgeKeys.publicKey, data: sealed)
        // The app died before storing it: the redelivered copy is still accepted.
        let restarted = E2EChannel(myID: "D", secretKey: deviceKeys.secretKey, mailStore: store)
        _ = try restarted.peekMail(from: "B", peerKey: bridgeKeys.publicKey, data: sealed)
        restarted.markMailSeen(mid: mid, ts: body["ts"]!.int!)
        #expect(throws: ProtocolError.staleOrReplayed) { try restarted.peekMail(from: "B", peerKey: bridgeKeys.publicKey, data: sealed) }
    }

    @Test func liveMessagesKeepTheirTimestampRule() throws {
        let (bridge, device) = channels()
        let live = try bridge.seal(to: "D", peerKey: deviceKeys.publicKey, body: ["type": "typing"])
        _ = try device.open(from: "B", peerKey: bridgeKeys.publicKey, data: live)
        #expect(throws: ProtocolError.staleOrReplayed) { try device.open(from: "B", peerKey: bridgeKeys.publicKey, data: live) }
    }

    @Test func blobRoundTripAndTamper() throws {
        let data = Sodium.randomBytes(1000)
        var (key, sealed) = try Blob.seal(data)
        #expect(try Blob.open(sealed, key: key) == data)
        sealed[sealed.count - 1] ^= 1
        #expect(throws: ProtocolError.cryptoFailure) { try Blob.open(sealed, key: key) }
        key = Sodium.randomBytes(32)
        #expect(throws: ProtocolError.self) { try Blob.open(sealed, key: key) }
    }

    @Test func wireParsesAgentMessagesAndRejectsJunk() {
        let id = E2EChannel.newMessageID()
        let key = Base64URL.encode(Sodium.randomBytes(32))
        let body: [String: JSON] = [
            "type": "chat", "id": .string(id), "role": "agent", "kind": "missed_call", "text": "Server down",
            "attachments": .array([
                ["kind": "photo", "blob_id": .string(E2EChannel.newMessageID()), "key": .string(key), "name": "a.png"],
                ["kind": "exe", "blob_id": "x", "key": .string(key)],
            ]),
        ]
        let message = ChatWire.message(from: body)
        #expect(message?.role == .agent && message?.kind == "missed_call" && message?.attachments.count == 1)
        #expect(message?.preview == "Missed call: Server down")
        #expect(ChatWire.message(from: ["type": "chat", "id": "short", "text": "x"]) == nil)
        #expect(ChatWire.message(from: ["type": "chat", "id": .string(id), "text": ""]) == nil)
        #expect(ChatWire.message(from: ["type": "chat", "id": .string(id), "kind": "evil", "text": "x"])?.kind == "text")
    }

    @Test func previewStripsMarkdown() {
        #expect(ChatText.plain("**Build** finished\nsee `log`") == "Build finished see log")
        #expect(ChatText.plain(String(repeating: "a", count: 400)).count == 280)
    }

    @Test func storeKeepsOrderDedupsAndTrims() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChatStore(root: root)
        let profile = UUID()
        let now = Date()
        let late = ChatMessage(id: "b", role: .agent, text: "2", date: now, status: .received)
        let early = ChatMessage(id: "a", role: .owner, text: "1", date: now.addingTimeInterval(-10), status: .pending)
        #expect(try await store.upsert(late, in: profile))
        #expect(try await store.upsert(early, in: profile))
        #expect(try await store.upsert(early, in: profile) == false)
        try await store.update("a", in: profile) { $0.status = .delivered }
        let reloaded = await ChatStore(root: root).messages(profile)
        #expect(reloaded.map(\.id) == ["a", "b"] && reloaded[0].status == .delivered)
        let file = try await store.saveAttachment(Data("x".utf8), id: "att", name: "photo.JPG", in: profile)
        #expect(file == "att.JPG")
        await store.deleteChat(profile)
        #expect(await ChatStore(root: root).messages(profile).isEmpty)
    }
}

struct ChatStoreSharingTests {
    @Test func secondWriterIsSeen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = ChatStore(root: root), shareExtension = ChatStore(root: root)
        let profile = UUID()
        try await app.upsert(ChatMessage(id: "a", role: .owner, text: "1", status: .delivered), in: profile)
        try await Task.sleep(for: .milliseconds(20))
        try await shareExtension.upsert(ChatMessage(id: "b", role: .owner, text: "2", status: .pending), in: profile)
        #expect(await app.messages(profile).map(\.id) == ["a", "b"])
    }
}
