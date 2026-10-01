import Foundation
import Testing
@testable import HermesCallCore

/// Runs the Swift client against the real Python relay + bridge (see Tests/interop_server.py).
@Suite(.serialized) struct InteropTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Server {
        let process: Process
        let stdin: Pipe
        let info: [String: Any]
    }

    static func startServer() throws -> Server? {
        let python = repo.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
        let process = Process()
        process.executableURL = python
        process.arguments = [repo.appendingPathComponent("ios/HermesCallKit/Tests/interop_server.py").path]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        try process.run()
        let line = stdout.fileHandleForReading.availableLine()
        let info = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
        return Server(process: process, stdin: stdin, info: info)
    }

    @Test func pairsAuthenticatesAndTalksToThePythonBridge() async throws {
        guard let server = try Self.startServer() else { return }
        defer {
            try? server.stdin.fileHandleForWriting.close()
            server.process.terminate()
        }
        let port = server.info["port"] as! Int
        let code = try PairingCode(parsing: server.info["code"] as! String)
        let unpinned = PairingInvite(kind: .device, relay: RelayAddress(host: "127.0.0.1", port: port), pin: "", code: code)
        await #expect(throws: ProtocolError.selfSignedRelay(server.info["pin"] as! String)) {
            _ = try await DevicePairing.pair(invite: unpinned, deviceName: "Swift test")
        }
        let invite = PairingInvite(kind: .device, relay: unpinned.relay, pin: server.info["pin"] as! String, code: code)
        let profile = try await DevicePairing.pair(invite: invite, deviceName: "Swift test")
        #expect(profile.pin == server.info["pin"] as? String)
        #expect(profile.bridgeName == "Hermes")

        let session = try RelaySession(profile: profile, hello: AppHello.body(appVersion: "test"))
        try await session.waitUntilConnected()
        // The bridge answers the app's `hello` with its version and caps.
        for _ in 0..<50 where await session.bridgeInfo == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(await session.bridgeInfo?.bridgeVersion != nil)
        #expect(await session.bridgeInfo?.supports("unsupported") == true)
        let turn = try await session.request(["t": "turn"])
        #expect(turn["urls"] != nil)
        // The relay names its version and caps and answers unknown request types without dropping the session.
        let info = await session.relayInfo
        #expect(info?.relayVersion != nil)
        #expect(info?.supports("unsupported") == true)
        await #expect(throws: ProtocolError.relay("unsupported")) { try await session.request(["t": "no_such_request"]) }
        await #expect(throws: ProtocolError.relay("unsupported")) {
            try await session.request(["t": "turn"], requires: "no_such_cap")
        }
        #expect(await session.isConnected)
        let callID = Base64URL.encode(Sodium.randomBytes(16))
        try await session.send(["type": "invite_query", "call_id": .string(callID)])
        var reply: [String: JSON]?
        for await message in session.messages {
            reply = message
            break
        }
        #expect(reply?["type"]?.string == "cancel")
        #expect(reply?["call_id"]?.string == callID)
        #expect(reply?["why"]?.string == "unknown_call")
        // History sync (D4): the Python bridge answers a page, empty for a fresh bridge.
        #expect(await session.bridgeInfo?.supports(ChatHistorySync.cap) == true)
        try await session.send(ChatHistorySync.request(before: nil))
        var page: ChatHistorySync.Page?
        for await message in session.messages {
            page = ChatHistorySync.page(from: message)
            break
        }
        #expect(page == ChatHistorySync.Page(messages: [], more: false, next: nil))
        await session.stop()
    }

    /// The agent rings: the phone registers for pushes, gets the invite, confirms it with `invite_query`
    /// (what it does after a VoIP push) and declines; the bridge's API reports the outcome.
    @Test func ringIsConfirmedAndDeclined() async throws {
        guard let server = try Self.startServer() else { return }
        defer {
            try? server.stdin.fileHandleForWriting.close()
            server.process.terminate()
        }
        let invite = PairingInvite(kind: .device, relay: RelayAddress(host: "127.0.0.1", port: server.info["port"] as! Int),
                                   pin: server.info["pin"] as! String, code: try PairingCode(parsing: server.info["code"] as! String))
        let session = try RelaySession(profile: try await DevicePairing.pair(invite: invite, deviceName: "Swift test"))
        defer { Task { await session.stop() } }
        let token = String(repeating: "ab", count: 32)
        let registered = try await session.request(["t": "register_push", "token": .string(token), "env": "sandbox"])
        #expect(registered["t"]?.string == "push_registered")

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.info["api_port"] as! Int)/v1/calls")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(server.info["api_token"] as! String)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"reason":"backup failed","first_message":"Hi, Hermes here."}"#.utf8)
        let ring = Task { try await URLSession.shared.data(for: request).0 }

        var messages = session.messages.makeAsyncIterator()
        let pushed = await messages.next()
        #expect(pushed?["type"]?.string == "invite" && pushed?["reason"]?.string == "backup failed")
        let callID = try #require(pushed?["call_id"]?.string)
        try await session.send(["type": "invite_query", "call_id": .string(callID)])
        #expect(await messages.next()?["type"]?.string == "invite")
        try await session.send(["type": "decline", "call_id": .string(callID)])
        let result = try JSONSerialization.jsonObject(with: try await ring.value) as? [String: Any]
        #expect(result?["status"] as? String == "declined" && result?["call_id"] as? String == callID)
        #expect(result?["messaged"] as? Bool == true)
    }

    static func api(_ server: Server, _ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.info["api_port"] as! Int)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(server.info["api_token"] as! String)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try JSONSerialization.jsonObject(with: try await URLSession.shared.data(for: request).0) as? [String: Any] ?? [:]
    }

    /// Chat both ways through the real relay mailbox and blob store, with the bridge's Hermes-side API.
    @Test func chatWithAttachmentsBothWays() async throws {
        guard let server = try Self.startServer() else { return }
        defer {
            try? server.stdin.fileHandleForWriting.close()
            server.process.terminate()
        }
        let invite = PairingInvite(kind: .device, relay: RelayAddress(host: "127.0.0.1", port: server.info["port"] as! Int),
                                   pin: server.info["pin"] as! String, code: try PairingCode(parsing: server.info["code"] as! String))
        let profile = try await DevicePairing.pair(invite: invite, deviceName: "Swift test")
        let mailStore = UserDefaults(suiteName: "hermescall.tests.\(UUID().uuidString)")
        let session = try RelaySession(profile: profile, mailStore: mailStore)
        defer { Task { await session.stop() } }
        try await session.waitUntilConnected()

        // Phone → agent, with an encrypted photo.
        let photo = Sodium.randomBytes(50_000)
        let (key, sealed) = try Blob.seal(photo)
        let blobID = try await session.uploadBlob(sealed)
        let outgoing = ChatMessage(id: E2EChannel.newMessageID(), role: .owner, text: "look **at** this", status: .pending)
        let attachment = ChatAttachment(kind: .photo, name: "IMG_1.jpg", mime: "image/jpeg", size: photo.count)
        try await session.send(ChatWire.body(for: outgoing, uploads: [(attachment, blobID, key)]), mail: true)
        var messages = session.messages.makeAsyncIterator()
        let ack = await messages.next()
        #expect(ack?["type"]?.string == "chat_ack" && ack?["id"]?.string == outgoing.id && ack?["state"]?.string == "delivered")
        let events = try await Self.api(server, "GET", "/v1/chat/events?cursor=0&wait=5")["events"] as? [[String: Any]]
        #expect(events?.first?["text"] as? String == "look **at** this")
        let sent = (events?.first?["attachments"] as? [[String: Any]])?.first
        #expect(sent?["data"] as? String == Base64URL.encode(photo))

        // Agent → phone: text and a file, through the mailbox.
        _ = try await Self.api(server, "POST", "/v1/chat/messages", ["text": "Done ✅"])
        let reply = try #require(await messages.next())
        let message = try #require(ChatWire.message(from: reply))
        #expect(message.role == .agent && message.text == "Done ✅" && reply["mail_id"]?.string != nil)
        try await session.ackMail([reply["mail_id"]!.string!])

        let report = Data("%PDF report".utf8)
        _ = try await Self.api(server, "POST", "/v1/chat/files",
                               ["kind": "file", "name": "r.pdf", "mime": "application/pdf", "data": Base64URL.encode(report)])
        let fileBody = try #require(await messages.next())
        let ref = try #require(ChatWire.message(from: fileBody)?.attachments.first)
        let downloaded = try await session.downloadBlob(ref.blobID!)
        #expect(try Blob.open(downloaded, key: Base64URL.decode(ref.key!, length: 32)) == report)
        try await session.deleteBlob(ref.blobID!)
    }

    @Test func stoppedSessionStaysStoppedAndEndsItsStream() async throws {
        guard let server = try Self.startServer() else { return }
        defer {
            try? server.stdin.fileHandleForWriting.close()
            server.process.terminate()
        }
        let invite = PairingInvite(kind: .device, relay: RelayAddress(host: "127.0.0.1", port: server.info["port"] as! Int),
                                   pin: server.info["pin"] as! String, code: try PairingCode(parsing: server.info["code"] as! String))
        let session = try RelaySession(profile: try await DevicePairing.pair(invite: invite, deviceName: "Swift test"))
        try await session.waitUntilConnected()
        await session.stop()
        for await _ in session.messages {}
        await #expect(throws: ProtocolError.notConnected) { try await session.send(["type": "hangup"]) }
        #expect(await session.isConnected == false)
    }

    /// M1: after a network change during a call the socket may still look open on the dead path; a forced
    /// reconnect drops it and connects again at once (no backoff), and requests work on the new connection.
    @Test func forcedReconnectReplacesAnOpenSocketAtOnce() async throws {
        guard let server = try Self.startServer() else { return }
        defer {
            try? server.stdin.fileHandleForWriting.close()
            server.process.terminate()
        }
        let invite = PairingInvite(kind: .device, relay: RelayAddress(host: "127.0.0.1", port: server.info["port"] as! Int),
                                   pin: server.info["pin"] as! String, code: try PairingCode(parsing: server.info["code"] as! String))
        let connects = Counter()
        let session = try RelaySession(profile: try await DevicePairing.pair(invite: invite, deviceName: "Swift test"),
                                       onStatus: { if $0 == .connected { connects.add() } })
        defer { Task { await session.stop() } }
        try await session.waitUntilConnected()
        #expect(connects.value == 1)
        await session.reconnectNow()
        try await Task.sleep(for: .milliseconds(300))
        #expect(connects.value == 1, "an open socket is kept without force")
        await session.reconnectNow(force: true)
        for _ in 0..<40 where connects.value < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(connects.value == 2, "reconnected within 2 s, without the backoff")
        let turn = try await session.request(["t": "turn"], timeout: 5)
        #expect(turn["urls"] != nil)
    }

    @Test func wrongCodeFailsAndPinnedLinkRejectsOtherKeys() async throws {
        guard let server = try Self.startServer() else { return }
        defer {
            try? server.stdin.fileHandleForWriting.close()
            server.process.terminate()
        }
        let port = server.info["port"] as! Int
        let real = try PairingCode(parsing: server.info["code"] as! String)
        let wrong = try PairingCode(parsing: real.slot + (real.secret.first == "A" ? "B" : "A") + real.secret.dropFirst())
        let relay = RelayAddress(host: "127.0.0.1", port: port)
        await #expect(throws: ProtocolError.self) {
            _ = try await DevicePairing.pair(invite: PairingInvite(kind: .device, relay: relay, pin: server.info["pin"] as! String, code: wrong), deviceName: "x")
        }
        let otherPin = Base64URL.encode(Sodium.randomBytes(32))
        await #expect(throws: (any Error).self) {
            _ = try await DevicePairing.pair(invite: PairingInvite(kind: .device, relay: relay, pin: otherPin, code: real), deviceName: "x")
        }
    }
}

private extension FileHandle {
    func availableLine() -> String {
        var data = Data()
        while true {
            let byte = readData(ofLength: 1)
            if byte.isEmpty || byte == Data("\n".utf8) { break }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Thread-safe count for status callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
