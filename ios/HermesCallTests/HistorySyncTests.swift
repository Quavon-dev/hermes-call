// SPDX-License-Identifier: MIT
import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

/// D4: the app asks a bridge with `history` for the recent chat once, and only while the chat is empty.
@MainActor
@Suite(.serialized) struct HistorySyncTests {
    static let bridge = BridgeInfo(hello: ["type": "hello", "bridge": "0.7.0", "caps": ["history"]])

    func requests(_ fixture: ChatFixture) -> [[String: JSON]] {
        fixture.links.sent.map(\.body).filter { $0["type"]?.string == "history_request" }
    }

    static func page(_ texts: [String], more: Bool, next: Int64?, base: Int64 = 1_790_000_000_000) -> [String: JSON] {
        let messages: [JSON] = texts.enumerated().map { index, text in
            .object(["id": .string(Base64URL.encode(Sodium.randomBytes(16))), "role": "agent", "kind": "text",
                     "text": .string(text), "ts": .int(base - Int64(index) * 1000)])
        }
        var body: [String: JSON] = ["type": "history_page", "messages": .array(messages), "more": .bool(more)]
        if let next { body["next"] = .int(next) }
        return body
    }

    @Test func emptyChatAsksPageByPageAndImports() async throws {
        let fixture = try ChatFixture()
        let info = try #require(Self.bridge)
        fixture.chat.bridgeHello(fixture.home.id, info)
        #expect(await fixture.eventually { requests(fixture).count == 1 })
        #expect(requests(fixture)[0]["before"] == nil)
        await fixture.chat.receiveHistory(Self.page(["newest", "older"], more: true, next: 9), profile: fixture.home, session: FakeLink(profile: fixture.home, owner: fixture.links))
        #expect(await fixture.eventually { requests(fixture).count == 2 })
        #expect(requests(fixture)[1]["before"] == .int(9))
        await fixture.chat.receiveHistory(Self.page(["oldest"], more: false, next: nil, base: 1_789_000_000_000), profile: fixture.home, session: FakeLink(profile: fixture.home, owner: fixture.links))
        #expect(await fixture.store.messages(fixture.home.id).map(\.text) == ["oldest", "older", "newest"])
        #expect(fixture.chat.historySynced(fixture.home.id))
        #expect(fixture.chat.unread(for: fixture.home.id) == 0, "history is not new mail")
        fixture.chat.bridgeHello(fixture.home.id, info)
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests(fixture).count == 2, "once per agent")
    }

    /// L2: a page that never arrives does not block the sync forever: after the page timeout the next
    /// `hello` (a reconnect) asks again.
    @Test func aLostPageIsAskedForAgainOnTheNextHello() async throws {
        let fixture = try ChatFixture()
        fixture.chat.historyPageTimeout = .milliseconds(100)
        let info = try #require(Self.bridge)
        fixture.chat.bridgeHello(fixture.home.id, info)
        #expect(await fixture.eventually { requests(fixture).count == 1 })
        fixture.chat.bridgeHello(fixture.home.id, info)
        try await Task.sleep(for: .milliseconds(50))
        #expect(requests(fixture).count == 1, "not twice while a page is on its way")
        try await Task.sleep(for: .milliseconds(200))
        fixture.chat.bridgeHello(fixture.home.id, info)
        #expect(await fixture.eventually { requests(fixture).count == 2 })
        #expect(requests(fixture)[1]["before"] == nil)
        #expect(!fixture.chat.historySynced(fixture.home.id))
    }

    /// L2: an import cut short (app quit after the first page) continues at its cursor on the next launch,
    /// although the chat is no longer empty.
    @Test func aPartialImportResumesAfterARestart() async throws {
        let fixture = try ChatFixture()
        let info = try #require(Self.bridge)
        fixture.chat.bridgeHello(fixture.home.id, info)
        #expect(await fixture.eventually { requests(fixture).count == 1 })
        await fixture.chat.receiveHistory(Self.page(["newest", "older"], more: true, next: 9), profile: fixture.home,
                                          session: FakeLink(profile: fixture.home, owner: fixture.links))
        #expect(await fixture.eventually { requests(fixture).count == 2 })
        // Restart: a new chat model over the same store and settings; the second page never came.
        let relaunched = ChatModel(app: fixture.app, store: fixture.store, links: fixture.links, listens: false,
                                   unreadDefaults: fixture.defaults)
        fixture.links.chat = relaunched
        #expect(!relaunched.historySynced(fixture.home.id))
        relaunched.bridgeHello(fixture.home.id, info)
        #expect(await fixture.eventually { requests(fixture).count == 3 })
        #expect(requests(fixture)[2]["before"] == .int(9))
        await relaunched.receiveHistory(Self.page(["oldest"], more: false, next: nil, base: 1_789_000_000_000), profile: fixture.home,
                                        session: FakeLink(profile: fixture.home, owner: fixture.links))
        #expect(await fixture.store.messages(fixture.home.id).map(\.text) == ["oldest", "older", "newest"])
        #expect(relaunched.historySynced(fixture.home.id))
    }

    @Test func aChatWithMessagesIsLeftAlone() async throws {
        let fixture = try ChatFixture()
        try await fixture.store.upsert(ChatMessage(id: E2EChannel.newMessageID(), role: .owner, text: "mine", status: .delivered),
                                       in: fixture.home.id)
        fixture.chat.bridgeHello(fixture.home.id, try #require(Self.bridge))
        #expect(await fixture.eventually { fixture.chat.historySynced(fixture.home.id) })
        #expect(requests(fixture).isEmpty)
    }

    /// L3: an owner who emptied a chat before updating to a version with history sync does not get the
    /// messages back: agents paired before this version first ran count as synced.
    @Test func agentsPairedBeforeTheUpdateAreNotFilledIn() async throws {
        let fixture = try ChatFixture()
        fixture.defaults.removeObject(forKey: ChatModel.historySinceKey)  // the first launch of this version
        let updated = ChatModel(app: fixture.app, store: fixture.store, links: fixture.links, listens: false,
                                unreadDefaults: fixture.defaults)
        updated.bridgeHello(fixture.home.id, try #require(Self.bridge))
        #expect(await fixture.eventually { updated.historySynced(fixture.home.id) })
        #expect(requests(fixture).isEmpty)
    }

    @Test func oldBridgesAreNotAsked() async throws {
        let fixture = try ChatFixture()
        fixture.chat.bridgeHello(fixture.home.id, try #require(BridgeInfo(hello: ["type": "hello", "caps": []])))
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests(fixture).isEmpty)
        // An unasked page is ignored.
        await fixture.chat.receiveHistory(Self.page(["x"], more: false, next: nil), profile: fixture.home, session: FakeLink(profile: fixture.home, owner: fixture.links))
        #expect(await fixture.store.messages(fixture.home.id).isEmpty)
    }
}
