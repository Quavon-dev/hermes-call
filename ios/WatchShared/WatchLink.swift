import Foundation

/// iPhone ⇄ Apple Watch over WatchConnectivity (encrypted by Apple between the paired devices).
/// The watch holds no relay keys: it shows what the iPhone sends and asks the iPhone to act.
enum WatchLink {
    /// Watch → iPhone `sendMessage` keys.
    static let action = "action"
    static let callAction = "call"
    static let messageAction = "message"
    static let text = "text"
    /// iPhone → watch application context: a JSON-encoded `WatchSnapshot`.
    static let snapshot = "snapshot"
    static let maxText = 2000
    /// iPhone → watch application context: the rendered presence (PNG, ≈ 150 px) in the agent's colour.
    static let still = "still"
}

/// What the watch shows: the active agent and its latest messages.
struct WatchSnapshot: Codable, Equatable, Sendable {
    struct Message: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let fromAgent: Bool
        /// "New message" when the owner hid message text in notifications.
        let text: String
        let date: Date
    }

    var agentName: String
    /// `AgentPalette` raw value.
    var palette: String
    var paired: Bool
    var messages: [Message]

    static let empty = WatchSnapshot(agentName: "Hermes", palette: "gold", paired: false, messages: [])
    static let maxMessages = 12
}
