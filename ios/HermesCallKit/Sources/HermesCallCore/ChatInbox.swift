// SPDX-License-Identifier: MIT
import Foundation

/// Unread agent messages per agent. Their sum is the app icon badge; the app keeps it in the app group.
public struct UnreadCounts: Equatable, Sendable {
    static let key = "badge.unreadByAgent"
    /// More would not fit a badge anyway.
    public static let maximum = 999

    public private(set) var byAgent: [UUID: Int] = [:]

    public init() {}

    public var total: Int { byAgent.values.reduce(0, +) }

    public func count(_ agent: UUID) -> Int { byAgent[agent] ?? 0 }

    public mutating func add(_ agent: UUID) {
        byAgent[agent] = min(count(agent) + 1, Self.maximum)
    }

    public mutating func clear(_ agent: UUID) {
        byAgent[agent] = nil
    }

    /// Forgets agents that were removed.
    public mutating func keep(only agents: Set<UUID>) {
        byAgent = byAgent.filter { agents.contains($0.key) }
    }

    public static func load(defaults: UserDefaults = SharedContainer.defaults) -> UnreadCounts {
        var counts = UnreadCounts()
        let stored = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        for (id, count) in stored {
            guard let agent = UUID(uuidString: id), count > 0 else { continue }
            counts.byAgent[agent] = min(count, maximum)
        }
        return counts
    }

    public func save(defaults: UserDefaults = SharedContainer.defaults) {
        defaults.set(Dictionary(uniqueKeysWithValues: byAgent.map { ($0.key.uuidString, $0.value) }), forKey: Self.key)
    }
}

/// One conversation in the chat list.
public struct InboxRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let palette: AgentPalette
    public let latest: ChatMessage?
    public let unread: Int

    public var preview: String { latest.map { ChatText.plain($0.preview, limit: 200) } ?? "" }
}

/// The combined chat list: every agent with its newest message and unread count.
public enum ChatInbox {
    /// Newest conversation first; agents without messages follow in the given order.
    public static func rows(profiles: [RelayProfile], latest: [UUID: ChatMessage], unread: UnreadCounts) -> [InboxRow] {
        let rows = profiles.map { profile in
            InboxRow(id: profile.id, name: profile.bridgeName, palette: profile.agentPalette, latest: latest[profile.id],
                     unread: unread.count(profile.id))
        }
        let order = Dictionary(uniqueKeysWithValues: profiles.enumerated().map { ($1.id, $0) })
        return rows.sorted { left, right in
            switch (left.latest?.date, right.latest?.date) {
            case let (l?, r?) where l != r: l > r
            case (.some, nil): true
            case (nil, .some): false
            default: order[left.id, default: 0] < order[right.id, default: 0]
            }
        }
    }
}
