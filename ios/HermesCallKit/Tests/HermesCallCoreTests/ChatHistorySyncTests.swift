// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HermesCallCore

/// D4: a newly paired phone imports the bridge's recent chat without duplicates.
struct ChatHistorySyncTests {
    static func id(_ n: UInt8) -> String { Base64URL.encode(Data(repeating: n, count: 16)) }

    /// L2: an interrupted import (lost page, app quit) resumes at its cursor, even though the chat is no
    /// longer empty; a chat with messages and no import in progress is left alone.
    @Test func planResumesAnInterruptedImport() {
        #expect(ChatHistorySync.plan(progress: nil, localCount: 0) == .request(before: nil))
        #expect(ChatHistorySync.plan(progress: nil, localCount: 3) == .markSynced)
        #expect(ChatHistorySync.plan(progress: .init(pages: 2, next: 77), localCount: 100) == .request(before: 77))
        #expect(ChatHistorySync.plan(progress: .init(pages: 0, next: nil), localCount: 0) == .request(before: nil))
        #expect(ChatHistorySync.plan(progress: .init(pages: ChatHistorySync.maxPages, next: 5), localCount: 9) == .markSynced)
    }

    /// L3: an agent paired before this app version knew history sync is never filled in (the owner may
    /// have deleted its messages on purpose); an import under way still finishes.
    @Test func agentsPairedBeforeTheSyncExistedAreLeftAlone() {
        #expect(ChatHistorySync.plan(progress: nil, localCount: 0, pairedBeforeSync: true) == .markSynced)
        #expect(ChatHistorySync.plan(progress: .init(pages: 1, next: 3), localCount: 4, pairedBeforeSync: true) == .request(before: 3))
        #expect(ChatHistorySync.plan(progress: nil, localCount: 0, pairedBeforeSync: false) == .request(before: nil))
    }

    @Test func progressPersistsPerAgent() throws {
        let suite = "de.quavon.hermescall.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let one = UUID(), two = UUID()
        #expect(ChatHistorySync.progress(for: one, in: defaults) == nil)
        ChatHistorySync.setProgress(.init(pages: 1, next: 42), for: one, in: defaults)
        ChatHistorySync.setProgress(.init(pages: 0, next: nil), for: two, in: defaults)
        #expect(ChatHistorySync.progress(for: one, in: defaults) == .init(pages: 1, next: 42))
        #expect(ChatHistorySync.progress(for: two, in: defaults) == .init(pages: 0, next: nil))
        ChatHistorySync.setProgress(nil, for: one, in: defaults)
        #expect(ChatHistorySync.progress(for: one, in: defaults) == nil)
        #expect(ChatHistorySync.progress(for: two, in: defaults) != nil)
    }

    @Test func requestsArePaged() {
        #expect(ChatHistorySync.request(before: nil) == ["type": "history_request", "limit": .int(Int64(ChatHistorySync.pageSize))])
        #expect(ChatHistorySync.request(before: 42)["before"] == .int(42))
    }

    @Test func pageBecomesMessagesWithTheirTimes() throws {
        let body: [String: JSON] = [
            "type": "history_page", "more": true, "next": 17,
            "messages": .array([
                .object(["id": .string(Self.id(1)), "role": "agent", "kind": "text", "text": "Sunny.", "ts": 1_790_000_000_000]),
                .object(["id": .string(Self.id(2)), "role": "owner", "kind": "text", "text": "Weather?", "ts": 1_789_999_990_000,
                         "transcript": "weather"]),
                .object(["id": "not-an-id", "role": "agent", "text": "dropped"]),
            ]),
        ]
        let page = try #require(ChatHistorySync.page(from: body))
        #expect(page.more && page.next == 17)
        #expect(page.messages.map(\.text) == ["Sunny.", "Weather?"])
        #expect(page.messages[0].date == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(page.messages[1].role == .owner && page.messages[1].status == .delivered && page.messages[1].transcript == "weather")
        #expect(page.messages[0].status == .received)
        #expect(ChatHistorySync.page(from: ["type": "chat"]) == nil)
    }

    @Test func importKeepsWhatIsThereAndAddsTheRest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(root: root, changedSignal: nil)
        let profile = UUID()
        let local = ChatMessage(id: Self.id(1), role: .agent, text: "kept as it is", status: .received)
        try await store.upsert(local, in: profile)
        let imported = try await store.insertNew([
            ChatMessage(id: Self.id(1), role: .agent, text: "from history", status: .received),
            ChatMessage(id: Self.id(2), role: .owner, text: "older", date: Date(timeIntervalSince1970: 1), status: .delivered),
        ], in: profile)
        #expect(imported.map(\.id) == [Self.id(2)])
        let all = await store.messages(profile)
        #expect(all.map(\.text) == ["older", "kept as it is"])
    }
}
