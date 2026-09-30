import Foundation

/// The Live Activity's state (ActivityKit `ContentState`, docs/protocol.md "Tasks"). The same JSON
/// arrives in ActivityKit pushes from the relay, so field names and types are part of the protocol:
/// `startedAt` is Unix seconds (not a `Date`, whose default coding differs between encoders).
public struct TaskContentState: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case running, done, failed }

    public var step: Int
    public var total: Int?
    public var label: String
    public var state: State
    public var startedAt: Double

    public init(step: Int, total: Int? = nil, label: String, state: State, startedAt: Double) {
        self.step = step
        self.total = total
        self.label = label
        self.state = state
        self.startedAt = startedAt
    }

    public var startDate: Date { Date(timeIntervalSince1970: startedAt) }

    /// Progress 0…1 when the total is known.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(step) / Double(total))
    }
}

/// A bridge `task` message (docs/protocol.md "Tasks"): the agent's progress on the current turn.
public struct TaskUpdate: Sendable, Equatable {
    public let turnID: String
    public let step: Int
    public let total: Int?
    public let tool: String
    public let label: String
    public let preview: String?
    public let state: TaskContentState.State
    /// Milliseconds since 1970 of the turn's first step.
    public let startedAt: Int64

    public init(turnID: String, step: Int, total: Int?, tool: String, label: String, preview: String?,
                state: TaskContentState.State, startedAt: Int64) {
        self.turnID = turnID
        self.step = step
        self.total = total
        self.tool = tool
        self.label = label
        self.preview = preview
        self.state = state
        self.startedAt = startedAt
    }

    /// Validates a decrypted `task` body; nil when anything is off.
    public static func parse(_ body: [String: JSON]) -> TaskUpdate? {
        guard body["type"]?.string == "task", let turnID = body["turn_id"]?.string, !turnID.isEmpty, turnID.count <= 64,
              let step = body["step"]?.int, (0...999).contains(step),
              let stateName = body["state"]?.string, let state = TaskContentState.State(rawValue: stateName),
              let startedAt = body["started_at"]?.int, startedAt > 0
        else { return nil }
        let total = body["total"]?.int.flatMap { (1...999).contains($0) ? Int($0) : nil }
        let tool = String((body["tool"]?.string ?? "").prefix(64))
        let label = String((body["label"]?.string ?? "Working").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let preview = body["preview"]?.string.map { String($0.prefix(200)) }
        return TaskUpdate(turnID: turnID, step: Int(step), total: total, tool: tool, label: label.isEmpty ? "Working" : label,
                          preview: preview, state: state, startedAt: startedAt)
    }

    /// The Live Activity state for this update; `details` false replaces the label with a generic one.
    public func contentState(details: Bool = true) -> TaskContentState {
        TaskContentState(step: step, total: total, label: details ? label : "Working…", state: state,
                         startedAt: Double(startedAt) / 1000)
    }
}
