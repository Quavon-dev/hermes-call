import Foundation

/// The owner's emergency stop: the chat message `/stop`, which Hermes' gateway turns into a real interrupt of
/// the running turn (the session stays). The bridge also cuts off a call's turn and ends the task on the
/// phones (docs/protocol.md, "Stop"). On this phone it shows as a small "Stop requested" line, not a bubble.
public enum StopCommand {
    public static let text = "/stop"
    /// `ChatMessage.kind` of a stop request (local only: on the wire it is a plain `chat` message).
    public static let kind = "stop"
    public static let label = "Stop requested"

    /// The whole message is the command (any case, surrounding whitespace), like the bridge checks it.
    public static func matches(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.text
    }

    /// The stop request as stored before it is sent.
    public static func message(id: String, date: Date = Date()) -> ChatMessage {
        ChatMessage(id: id, role: .owner, kind: kind, text: text, date: date, status: .pending)
    }

    /// Whether the agent is visibly busy (typing, or a task still running): the chat then offers Stop.
    public static func agentIsWorking(typing: Bool, task: TaskUpdate?) -> Bool {
        typing || task?.state == .running
    }
}

extension ChatMessage {
    /// An owner `/stop` (sent here, mirrored from another phone or from the history).
    public var isStopRequest: Bool { role == .owner && (kind == StopCommand.kind || StopCommand.matches(text)) }
}
