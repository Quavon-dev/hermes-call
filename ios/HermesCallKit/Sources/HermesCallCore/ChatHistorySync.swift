// SPDX-License-Identifier: MIT
import Foundation

/// The recent chat for a newly paired phone (docs/protocol.md, "Chat history"): when the bridge lists
/// `history` and this agent's chat is still empty, the app asks for `history_page`s, newest first, and
/// stores the messages it does not have (by id). Messages deleted on a phone stay deleted there: the app
/// only asks while its chat with that agent is empty.
public enum ChatHistorySync {
    public static let cap = "history"
    public static let pageSize = 50
    /// The bridge keeps 200 messages; pages are smaller when messages are long.
    public static let maxPages = 12

    public struct Page: Sendable, Equatable {
        public let messages: [ChatMessage]
        public let more: Bool
        public let next: Int64?
    }

    /// How long the app waits for a requested page (the bridge uploads its attachments first) before the
    /// next `hello` may ask again.
    public static let pageTimeout: TimeInterval = 120
    static let progressKey = "historyProgress"

    /// An import under way, kept across launches: pages imported so far and the cursor of the next one.
    public struct Progress: Codable, Sendable, Equatable {
        public var pages: Int
        public var next: Int64?

        public init(pages: Int, next: Int64?) {
            self.pages = pages
            self.next = next
        }
    }

    public enum Plan: Sendable, Equatable {
        case request(before: Int64?)
        case markSynced
    }

    /// What to do when a bridge with `history` says hello and the agent is not synced yet: resume an import
    /// under way (the chat is no longer empty then), start one for an empty chat, else leave the chat alone.
    public static func plan(progress: Progress?, localCount: Int) -> Plan {
        if let progress { return progress.pages < maxPages ? .request(before: progress.next) : .markSynced }
        return localCount == 0 ? .request(before: nil) : .markSynced
    }

    public static func progress(for agent: UUID, in defaults: UserDefaults) -> Progress? {
        guard let data = (defaults.dictionary(forKey: progressKey) as? [String: Data])?[agent.uuidString] else { return nil }
        return try? JSONDecoder().decode(Progress.self, from: data)
    }

    /// nil: no import under way (finished or never started).
    public static func setProgress(_ progress: Progress?, for agent: UUID, in defaults: UserDefaults) {
        var all = defaults.dictionary(forKey: progressKey) as? [String: Data] ?? [:]
        all[agent.uuidString] = progress.flatMap { try? JSONEncoder().encode($0) }
        defaults.set(all, forKey: progressKey)
    }

    public static func request(before: Int64?) -> [String: JSON] {
        var body: [String: JSON] = ["type": "history_request", "limit": .int(Int64(pageSize))]
        if let before { body["before"] = .int(before) }
        return body
    }

    /// nil when `body` is no `history_page`; entries that do not parse are left out.
    public static func page(from body: [String: JSON]) -> Page? {
        guard body["type"]?.string == "history_page" else { return nil }
        var messages: [ChatMessage] = []
        if case .array(let items)? = body["messages"] {
            for case .object(var item) in items.prefix(pageSize) {
                let ms = item["ts"]?.int ?? 0
                item["type"] = "chat"
                let date = ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000) : Date()
                guard var message = ChatWire.message(from: item, date: date) else { continue }
                message.transcript = item["transcript"]?.string.map { String($0.prefix(ChatWire.maxText)) }
                messages.append(message)
            }
        }
        return Page(messages: messages, more: body["more"]?.bool == true, next: body["next"]?.int)
    }
}
