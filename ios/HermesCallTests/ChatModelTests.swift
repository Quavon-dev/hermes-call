import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

/// A relay connection that records what the chat sends and can confirm it like the bridge.
@MainActor
final class FakeLinks: ChatLinkProvider {
    struct Sent {
        let profile: UUID
        let body: [String: JSON]
    }

    private(set) var sent: [Sent] = []
    private(set) var uploads = 0
    var reachable = true
    /// Answers every sent chat message with `chat_ack` like the bridge.
    var acks = true
    weak var chat: ChatModel?

    func withLink<T: Sendable>(_ profile: RelayProfile, _ work: @escaping (any ChatLink) async throws -> T) async -> T? {
        guard reachable else { return nil }
        return try? await work(FakeLink(profile: profile, owner: self))
    }

    fileprivate func record(_ body: [String: JSON], profile: RelayProfile) {
        sent.append(Sent(profile: profile.id, body: body))
        guard acks, body["type"]?.string == "chat", let id = body["id"]?.string else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            self.chat?.handle(["type": "chat_ack", "id": .string(id)], profile: profile, link: FakeLink(profile: profile, owner: self))
        }
    }

    fileprivate func recordUpload() { uploads += 1 }
}

struct FakeLink: ChatLink {
    let profile: RelayProfile
    let owner: FakeLinks

    func uploadBlob(_ sealed: Data) async throws -> String {
        await owner.recordUpload()
        return Base64URL.encode(Sodium.randomBytes(16))
    }

    func send(_ body: [String: JSON], mail: Bool) async throws { await owner.record(body, profile: profile) }
    func ackMail(_ ids: [String]) async throws {}
    func downloadBlob(_ blobID: String, maxSize: Int) async throws -> Data { throw ProtocolError.notConnected }
    func deleteBlob(_ blobID: String) async throws {}
}

/// A chat with two paired agents, a private store and fake relay connections.
@MainActor
struct ChatFixture {
    let app: AppModel
    let chat: ChatModel
    let store: ChatStore
    let links = FakeLinks()
    let home: RelayProfile
    let office: RelayProfile

    init() throws {
        let service = "de.quavon.hermescall.tests.\(UUID().uuidString)"
        let profiles = [try Self.profile("home"), try Self.profile("office")]
        try ProfileStore(service: service).save(profiles)
        let defaults = UserDefaults(suiteName: "de.quavon.hermescall.tests.\(UUID().uuidString)") ?? .standard
        // The owner agreed to share with their agents (ConsentView); kept out of the real app group.
        let preferences = Preferences(defaults: defaults, shared: defaults)
        preferences.aiConsent = true
        app = AppModel(store: ProfileStore(service: service), preferences: preferences)
        store = ChatStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)"),
                          changedSignal: nil)
        chat = ChatModel(app: app, store: store, links: links, listens: false)
        chat.ackTimeout = .milliseconds(300)
        links.chat = chat
        home = profiles[0]
        office = profiles[1]
    }

    static func profile(_ label: String) throws -> RelayProfile {
        RelayProfile(id: UUID(), label: label, relay: RelayAddress(host: "relay.invalid", port: 443), pin: "",
                     deviceID: "dev-\(label)", bridgeID: "bridge", bridgeName: label.capitalized,
                     bridgeBoxKey: Base64URL.encode(Sodium.randomBytes(32)),
                     bridgeSignKey: Base64URL.encode(Sodium.randomBytes(32)), keys: try DeviceKeys.generate(), created: Date())
    }

    /// Waits until `condition` holds (store writes happen in tasks).
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

@MainActor
@Suite(.serialized) struct ChatModelTests {
    @Test func retrySendsThroughTheMessagesOwnAgent() async throws {
        let fixture = try ChatFixture()
        let failed = ChatMessage(id: E2EChannel.newMessageID(), role: .owner, text: "for the office", status: .failed)
        try await fixture.store.upsert(failed, in: fixture.office.id)
        fixture.app.activate(fixture.office.id)
        await fixture.chat.reload()
        // The owner switched agents; the office chat is still on screen with its failed message.
        fixture.app.activate(fixture.home.id)
        await fixture.chat.retry(failed)
        #expect(fixture.links.sent.map(\.profile) == [fixture.office.id])
        #expect(await fixture.store.message(failed.id, in: fixture.office.id)?.status == .delivered)
    }

    @Test func callEntriesAreStoredStructured() async throws {
        let fixture = try ChatFixture()
        fixture.chat.noteCall(profile: fixture.home.id, duration: 151, incoming: false)
        #expect(await fixture.eventually { await fixture.store.count(fixture.home.id) == 1 })
        let entry = await fixture.store.latest(fixture.home.id, limit: 1).first
        #expect(entry?.call == CallSummary(direction: .outgoing, duration: 151))
        #expect(entry?.systemText == "Outgoing call · 2:31")
    }

    @Test func outboxSendsEveryAgentsWaitingMessagesOnce() async throws {
        let fixture = try ChatFixture()
        let waiting = [(fixture.home, "a"), (fixture.office, "b"), (fixture.home, "c")].map { profile, text in
            (profile.id, ChatMessage(id: E2EChannel.newMessageID(), role: .owner, text: text, status: .pending))
        }
        for (profile, message) in waiting { try await fixture.store.upsert(message, in: profile) }
        // The share extension is sending "c" itself right now.
        #expect(await fixture.store.claim(waiting[2].1.id, in: fixture.home.id, owner: ShareHandoff.claimOwner, for: 60))
        await fixture.chat.drainOutbox()
        #expect(Set(fixture.links.sent.compactMap { $0.body["text"]?.string }) == ["a", "b"])
        #expect(await fixture.store.outbox(now: Date().addingTimeInterval(300)).map(\.message.id) == [waiting[2].1.id])
        await fixture.chat.drainOutbox()
        #expect(fixture.links.sent.count == 2)
    }

    @Test func unreachableRelayMarksTheMessageFailed() async throws {
        let fixture = try ChatFixture()
        fixture.links.reachable = false
        await fixture.chat.reload()
        let id = try #require(await fixture.chat.send(text: "hello"))
        #expect(await fixture.store.message(id, in: fixture.home.id)?.status == .failed)
        #expect(fixture.chat.messages.last?.status == .failed)
        fixture.links.reachable = true
        fixture.links.acks = false
        await fixture.chat.retry(try #require(fixture.chat.messages.last))
        #expect(fixture.links.sent.count == 1)
        #expect(fixture.chat.messages.last?.status == .failed)
    }

    @Test func attachmentsAreUploadedWithTheMessage() async throws {
        let fixture = try ChatFixture()
        let photo = OutgoingFile(kind: .photo, name: "p.jpg", mime: "image/jpeg", data: Data(repeating: 1, count: 100))
        let id = try #require(await fixture.chat.send(text: "", files: [photo, photo]))
        #expect(fixture.links.uploads == 2)
        guard case .array(let attachments)? = fixture.links.sent.first?.body["attachments"] else {
            Issue.record("no attachments sent")
            return
        }
        #expect(attachments.count == 2)
        #expect(await fixture.store.message(id, in: fixture.home.id)?.status == .delivered)
    }

    @Test func askReturnsTheAgentsQuickAnswer() async throws {
        let fixture = try ChatFixture()
        let answer = Task { await fixture.chat.ask("Weather?", wait: .seconds(5)) }
        #expect(await fixture.eventually { fixture.links.sent.count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        fixture.chat.handle(["type": "chat", "id": .string(E2EChannel.newMessageID()), "role": "agent", "text": "**Sunny**, 24 °C"],
                            profile: fixture.home, link: FakeLink(profile: fixture.home, owner: fixture.links))
        #expect(await answer.value == .answered("Sunny, 24 °C"))
        #expect(fixture.chat.unread == 1)
    }

    @Test func historyPagesSearchesAndDeletes() async throws {
        let fixture = try ChatFixture()
        let base = Date(timeIntervalSince1970: 2_000_000)
        for index in 0..<120 {
            let message = ChatMessage(id: "m\(index)", role: index.isMultiple(of: 2) ? .agent : .owner,
                                      text: index == 10 ? "the invoice" : "note \(index)", date: base.addingTimeInterval(Double(index)),
                                      status: index.isMultiple(of: 2) ? .received : .delivered)
            try await fixture.store.upsert(message, in: fixture.home.id)
        }
        await fixture.chat.reload()
        #expect(fixture.chat.messages.count == ChatWindow.pageSize && fixture.chat.messages.last?.id == "m119")
        #expect(fixture.chat.window.hasOlder)
        await fixture.chat.loadOlder()
        await fixture.chat.loadOlder()
        #expect(fixture.chat.messages.first?.id == "m0" && !fixture.chat.window.hasOlder)

        await fixture.chat.search("INVOICE")
        #expect(fixture.chat.searchResults.map(\.id) == ["m10"])
        #expect(await fixture.chat.reveal("m10"))
        #expect(fixture.chat.messages.contains { $0.id == "m10" } && fixture.chat.window.hasNewer)
        // New arrivals do not jump into a window that does not reach the newest message.
        fixture.chat.noteCall(profile: fixture.home.id, duration: 3, incoming: true)
        #expect(await fixture.eventually { await fixture.store.count(fixture.home.id) == 121 })
        #expect(fixture.chat.messages.allSatisfy { $0.kind != "call" })

        await fixture.chat.delete(try #require(fixture.chat.messages.first { $0.id == "m10" }))
        #expect(fixture.chat.searchResults.isEmpty && !fixture.chat.messages.contains { $0.id == "m10" })
        #expect(await fixture.store.message("m10", in: fixture.home.id) == nil)
    }
}

struct ChatWindowTests {
    func message(_ index: Int) -> ChatMessage {
        ChatMessage(id: "m\(index)", role: .agent, text: "\(index)", date: Date(timeIntervalSince1970: Double(index)), status: .received)
    }

    @Test func appliesArrivalsWhereTheyBelong() {
        var window = ChatWindow()
        window.showLatest((10..<20).map(message), total: 30)
        window.apply(message(25))
        window.apply(message(5))
        #expect(window.messages.map(\.id).last == "m25" && !window.messages.contains { $0.id == "m5" })
        var changed = message(12)
        changed.text = "edited"
        window.apply(changed)
        #expect(window.messages.first { $0.id == "m12" }?.text == "edited" && window.messages.count == 11)
        window.remove("m12")
        #expect(window.messages.count == 10)
    }

    @Test func keepsAtMostMaxLoaded() {
        var window = ChatWindow()
        window.showLatest([], total: 0)
        for index in 0..<(ChatWindow.maxLoaded + 5) { window.apply(message(index)) }
        #expect(window.messages.count == ChatWindow.maxLoaded && window.hasOlder && window.messages.first?.id == "m5")
    }
}
