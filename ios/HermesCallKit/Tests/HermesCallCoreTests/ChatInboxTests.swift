// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HermesCallCore

struct UnreadCountsTests {
    let atlas = UUID(), nova = UUID()

    @Test func countsPerAgentAndTotal() {
        var counts = UnreadCounts()
        counts.add(atlas)
        counts.add(atlas)
        counts.add(nova)
        #expect(counts.count(atlas) == 2)
        #expect(counts.count(nova) == 1)
        #expect(counts.total == 3)
        counts.clear(atlas)
        #expect(counts.count(atlas) == 0)
        #expect(counts.total == 1)
    }

    @Test func removedAgentsDropOut() {
        var counts = UnreadCounts()
        counts.add(atlas)
        counts.add(nova)
        counts.keep(only: [nova])
        #expect(counts.count(atlas) == 0)
        #expect(counts.total == 1)
    }

    @Test func persistsInTheAppGroup() throws {
        let defaults = try #require(UserDefaults(suiteName: "unread-\(UUID().uuidString)"))
        var counts = UnreadCounts()
        counts.add(atlas)
        counts.add(nova)
        counts.add(nova)
        counts.save(defaults: defaults)
        #expect(UnreadCounts.load(defaults: defaults) == counts)
        #expect(UnreadCounts.load(defaults: defaults).total == 3)
        #expect(UnreadCounts.load(defaults: try #require(UserDefaults(suiteName: "unread-\(UUID().uuidString)"))).total == 0)
    }

    @Test func counterNeverGoesNegativeOrOverflowsTheBadge() {
        var counts = UnreadCounts()
        counts.clear(atlas)
        #expect(counts.total == 0)
        for _ in 0..<(UnreadCounts.maximum + 10) { counts.add(atlas) }
        #expect(counts.count(atlas) == UnreadCounts.maximum)
    }
}

struct ChatInboxTests {
    func profile(_ name: String, palette: AgentPalette) throws -> RelayProfile {
        var profile = RelayProfile(id: UUID(), label: name, relay: RelayAddress(host: "relay.example.com", port: 443), pin: "",
                                   deviceID: "dev", bridgeID: "bridge", bridgeName: name,
                                   bridgeBoxKey: Base64URL.encode(Sodium.randomBytes(32)),
                                   bridgeSignKey: Base64URL.encode(Sodium.randomBytes(32)), keys: try DeviceKeys.generate(), created: Date())
        profile.palette = palette
        return profile
    }

    func message(_ text: String, at seconds: TimeInterval) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: .agent, text: text, date: Date(timeIntervalSince1970: seconds), status: .delivered)
    }

    /// Newest conversation first; agents without messages keep their order at the end.
    @Test func rowsAreOrderedByLatestMessage() throws {
        let atlas = try profile("Atlas", palette: .gold), nova = try profile("Nova", palette: .emerald), iris = try profile("Iris", palette: .ice)
        var unread = UnreadCounts()
        unread.add(nova.id)
        let rows = ChatInbox.rows(profiles: [atlas, nova, iris],
                                  latest: [atlas.id: message("old", at: 100), nova.id: message("new", at: 200)], unread: unread)
        #expect(rows.map(\.name) == ["Nova", "Atlas", "Iris"])
        #expect(rows[0].unread == 1 && rows[1].unread == 0)
        #expect(rows[0].palette == .emerald)
        #expect(rows[0].preview == "new")
        #expect(rows[2].latest == nil)
    }
}
