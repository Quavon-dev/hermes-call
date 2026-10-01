import Foundation
import Testing
@testable import HermesCallCore

/// The chat history store (SQLite in the app group): shared by the app and its extensions.
struct ChatStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chatstore-\(UUID().uuidString)")
    let profile = UUID()

    func message(_ index: Int, role: ChatMessage.Role = .agent, text: String? = nil, base: Date = Date(timeIntervalSince1970: 1_000_000))
        -> ChatMessage {
        ChatMessage(id: "m\(index)", role: role, text: text ?? "message \(index)", date: base.addingTimeInterval(Double(index)),
                    status: role == .owner ? .pending : .received)
    }

    @Test func keepsMoreThanThreeThousandMessages() async throws {
        let store = ChatStore(root: root)
        for index in 0..<3100 { try await store.upsert(message(index), in: profile) }
        let all = await ChatStore(root: root).messages(profile)
        #expect(all.count == 3100)
        #expect(all.first?.id == "m0" && all.last?.id == "m3099")
    }

    @Test func twoProcessesWritingAtOnceLoseNothing() async throws {
        // The app and the share extension are separate processes with their own store instance.
        let app = ChatStore(root: root), shareExtension = ChatStore(root: root)
        try await app.upsert(message(0), in: profile)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for index in 1...40 { _ = try? await app.upsert(message(index), in: profile) } }
            group.addTask { for index in 41...80 { _ = try? await shareExtension.upsert(message(index), in: profile) } }
        }
        #expect(await ChatStore(root: root).messages(profile).count == 81)
        #expect(await app.messages(profile).count == 81)
    }

    @Test func migratesTheOldJSONHistoryOnce() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyCall = ChatMessage(id: "c", role: .system, kind: "call", text: "Incoming call · 12:05",
                                     date: Date(timeIntervalSince1970: 1_000_002), status: .received)
        let old = [message(1, role: .owner), legacyCall, message(3)]
        let file = root.appendingPathComponent("\(profile.uuidString).json")
        try JSONEncoder().encode(old).write(to: file)
        let store = ChatStore(root: root)
        let migrated = await store.messages(profile)
        #expect(migrated.map(\.id) == ["m1", "c", "m3"])
        #expect(migrated[1].call == CallSummary(direction: .incoming, duration: 725) && migrated[1].text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await ChatStore(root: root).count(profile) == 3)
    }

    @Test func pagesSearchAndDelete() async throws {
        let store = ChatStore(root: root)
        for index in 0..<50 { try await store.upsert(message(index, text: index == 7 ? "Die Rechnung für **März**" : nil), in: profile) }
        #expect(await store.latest(profile, limit: 5).map(\.id) == ["m45", "m46", "m47", "m48", "m49"])
        #expect(await store.messages(profile, before: "m45", limit: 3).map(\.id) == ["m42", "m43", "m44"])
        #expect(await store.messages(profile, after: "m47", limit: 5).map(\.id) == ["m48", "m49"])
        #expect(await store.messages(profile, before: "nope", limit: 3).isEmpty)
        #expect(await store.search(profile, for: "marz").map(\.id) == ["m7"])
        #expect(await store.search(profile, for: "MESSAGE 4").map(\.id)
            == ["m49", "m48", "m47", "m46", "m45", "m44", "m43", "m42", "m41", "m40", "m4"])
        #expect(await store.search(profile, for: "100%").isEmpty)
        #expect(await store.search(profile, for: "  ").isEmpty)
        #expect(await store.search(UUID(), for: "message").isEmpty)

        var photo = ChatAttachment(kind: .photo, name: "a.jpg", mime: "image/jpeg", size: 1)
        photo.localFile = try await store.saveAttachment(Data("x".utf8), id: photo.id, name: "a.jpg", in: profile)
        var withPhoto = message(60)
        withPhoto.attachments = [photo]
        try await store.upsert(withPhoto, in: profile)
        let file = await store.attachmentDirectory(profile).appendingPathComponent(photo.localFile ?? "")
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await store.delete("m60", in: profile)
        #expect(await store.message("m60", in: profile) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func outboxClaimsKeepTwoSendersApart() async throws {
        let app = ChatStore(root: root), shareExtension = ChatStore(root: root)
        let other = UUID()
        try await app.upsert(message(1, role: .owner), in: profile)
        try await app.upsert(message(2, role: .owner), in: other)
        try await app.upsert(message(3), in: profile)
        #expect(await app.outbox().map(\.message.id) == ["m1", "m2"])
        #expect(await app.outbox(profile).map(\.message.id) == ["m1"])
        #expect(await shareExtension.claim("m1", in: profile, owner: "share", for: 30))
        #expect(await app.claim("m1", in: profile, owner: "app", for: 30) == false)
        #expect(await app.outbox(profile).isEmpty)
        // A crashed sender's claim runs out.
        #expect(await app.claim("m1", in: profile, owner: "app", for: 30, now: Date().addingTimeInterval(60)))
        await app.releaseClaim("m1", in: profile, owner: "app")
        try await app.update("m1", in: profile) { $0.status = .delivered }
        #expect(await shareExtension.outbox(profile).isEmpty)
    }

    @Test func noticesWritesFromOtherInstances() async throws {
        let app = ChatStore(root: root, changedSignal: nil), shareExtension = ChatStore(root: root, changedSignal: nil)
        _ = await app.changedElsewhere()
        try await app.upsert(message(1), in: profile)
        #expect(await app.changedElsewhere() == false)
        try await shareExtension.upsert(message(2), in: profile)
        #expect(await app.changedElsewhere())
        #expect(await app.changedElsewhere() == false)
    }

    @Test func deleteAllWipesDatabaseAndFiles() async throws {
        let store = ChatStore(root: root)
        try await store.upsert(message(1), in: profile)
        _ = try await store.saveAttachment(Data("x".utf8), id: "f", name: "f.txt", in: profile)
        await store.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(await store.messages(profile).isEmpty)
        try await store.upsert(message(2), in: profile)
        #expect(await store.count(profile) == 1)
    }

    @Test func callEntriesAreStructured() {
        #expect(CallSummary(direction: .outgoing, duration: 151).text == "Outgoing call · 2:31")
        #expect(CallSummary(direction: .incoming, duration: 3725).text == "Incoming call · 1:02:05")
        #expect(CallSummary(legacyText: "Outgoing call · 2:31") == CallSummary(direction: .outgoing, duration: 151))
        #expect(CallSummary(legacyText: "Missed call · 2:31") == nil)
        #expect(CallSummary(legacyText: "Outgoing call · x:1") == nil)
        let entry = ChatMessage.callEntry(CallSummary(direction: .incoming, duration: 5), id: "c")
        #expect(entry.preview == "Incoming call · 0:05" && entry.systemText == "Incoming call · 0:05" && entry.text.isEmpty)
    }
}

struct SharedSignalTests {
    func names() -> (String, String, URL) {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signals-\(id)")
        return ("hermescall.tests.ping.\(id)", "hermescall.tests.pong.\(id)", directory)
    }

    @Test func probeSeesARunningResponder() async {
        let (ping, pong, directory) = names()
        #expect(await SharedSignal.probe(ping: ping, pong: pong, timeout: .milliseconds(200), handshake: directory) == false)
        let responder = Task {
            for await _ in SharedSignal.observe(ping) { SharedSignal.answer(pong: pong, handshake: directory) }
        }
        defer { responder.cancel() }
        try? await Task.sleep(for: .milliseconds(50))
        async let first = SharedSignal.probe(ping: ping, pong: pong, timeout: .seconds(2), handshake: directory)
        async let second = SharedSignal.probe(ping: ping, pong: pong, timeout: .seconds(2), handshake: directory)
        let answered = await (first, second)
        #expect(answered == (true, true), "two extensions asking at once both get their answer")
    }

    /// Darwin notifications are global: any app can post `appPong`. Only an answer written into the app
    /// group (which other apps cannot reach) for this probe's own nonce counts.
    @Test func aSpoofedPongIsNotAnAnswer() async {
        let (ping, pong, directory) = names()
        let spoofer = Task {
            for await _ in SharedSignal.observe(ping) { SharedSignal.post(pong) }
        }
        defer { spoofer.cancel() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await SharedSignal.probe(ping: ping, pong: pong, timeout: .milliseconds(400), handshake: directory) == false)
    }
}
