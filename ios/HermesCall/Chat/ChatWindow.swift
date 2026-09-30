import Foundation
import HermesCallCore

/// The part of a chat's history that is loaded for the screen: the newest page at first, older pages
/// as the owner scrolls up, or the messages around a search hit. The store keeps everything else.
struct ChatWindow: Equatable {
    static let pageSize = 50
    /// Beyond this many loaded messages the oldest are let go again (they reload on scrolling up).
    static let maxLoaded = 400

    private(set) var messages: [ChatMessage] = []
    /// Older messages exist in the store.
    private(set) var hasOlder = false
    /// Newer messages exist in the store (after jumping to a search hit); new arrivals are then not appended.
    private(set) var hasNewer = false

    /// The newest page (`total`: messages in the store).
    mutating func showLatest(_ latest: [ChatMessage], total: Int) {
        messages = latest
        hasOlder = total > latest.count
        hasNewer = false
    }

    /// A search hit with its neighbours; `older`/`newer` were asked for `pageSize / 2` each.
    mutating func showAround(_ hit: ChatMessage, older: [ChatMessage], newer: [ChatMessage]) {
        messages = older + [hit] + newer
        hasOlder = older.count >= Self.pageSize / 2
        hasNewer = newer.count >= Self.pageSize / 2
    }

    mutating func prepend(_ older: [ChatMessage]) {
        messages = older + messages
        hasOlder = older.count >= Self.pageSize
    }

    mutating func append(_ newer: [ChatMessage]) {
        messages += newer
        hasNewer = newer.count >= Self.pageSize
        trimOldest()
    }

    /// A stored or changed message: replaced in place, or inserted by date when it belongs in the window.
    mutating func apply(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
            return
        }
        guard !hasNewer else { return }
        let index = messages.lastIndex { $0.date <= message.date }.map { $0 + 1 } ?? 0
        // Older than everything loaded while more is stored: it shows when the owner scrolls up.
        if index == 0, hasOlder, !messages.isEmpty { return }
        messages.insert(message, at: index)
        trimOldest()
    }

    mutating func remove(_ id: String) {
        messages.removeAll { $0.id == id }
    }

    private mutating func trimOldest() {
        guard messages.count > Self.maxLoaded else { return }
        messages.removeFirst(messages.count - Self.maxLoaded)
        hasOlder = true
    }
}
