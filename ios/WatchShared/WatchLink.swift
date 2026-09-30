import Foundation

/// iPhone ⇄ Apple Watch over WatchConnectivity (encrypted by Apple between the paired devices).
/// The watch holds no relay keys: it shows what the iPhone sends and asks the iPhone to act.
enum WatchLink {
    /// Watch → iPhone keys (`sendMessage`, `transferUserInfo`, `transferFile` metadata).
    static let action = "action"
    static let callAction = "call"
    static let messageAction = "message"
    static let voiceAction = "voice"
    static let denyAction = "deny"
    static let text = "text"
    /// Every request carries an id, so one that arrives twice (live and queued) is done once.
    static let requestID = "id"
    static let approvalID = "approval"
    static let duration = "duration"
    /// iPhone → watch application context: a JSON-encoded `WatchSnapshot`.
    static let snapshot = "snapshot"
    static let maxText = 2000
    /// iPhone → watch application context: the rendered presence (PNG, ≈ 150 px) in the agent's colour.
    static let still = "still"
    /// iPhone → watch `sendMessage` while the watch app is open: the call's state, for haptics.
    static let callState = "callState"
}

/// What the watch asks the iPhone to do.
struct WatchRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case call
        case message(String)
        /// Deny a pending approval (approving needs Face ID on the iPhone).
        case deny(approvalID: String)
        /// A recorded voice note arrives as a file; this is its metadata.
        case voice(duration: Double)
    }

    let id: String
    let kind: Kind

    init(id: String = UUID().uuidString, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    init?(_ dictionary: [String: Any]) {
        guard let id = dictionary[WatchLink.requestID] as? String, !id.isEmpty, id.count <= 64 else { return nil }
        self.id = id
        switch dictionary[WatchLink.action] as? String {
        case WatchLink.callAction:
            kind = .call
        case WatchLink.messageAction:
            guard let text = (dictionary[WatchLink.text] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= WatchLink.maxText else { return nil }
            kind = .message(text)
        case WatchLink.denyAction:
            guard let approval = dictionary[WatchLink.approvalID] as? String, !approval.isEmpty else { return nil }
            kind = .deny(approvalID: approval)
        case WatchLink.voiceAction:
            let duration = dictionary[WatchLink.duration] as? Double ?? 0
            guard duration >= 0.5, duration <= 300 else { return nil }
            kind = .voice(duration: duration)
        default:
            return nil
        }
    }

    var dictionary: [String: Any] {
        var dictionary: [String: Any] = [WatchLink.requestID: id]
        switch kind {
        case .call: dictionary[WatchLink.action] = WatchLink.callAction
        case .message(let text):
            dictionary[WatchLink.action] = WatchLink.messageAction
            dictionary[WatchLink.text] = text
        case .deny(let approval):
            dictionary[WatchLink.action] = WatchLink.denyAction
            dictionary[WatchLink.approvalID] = approval
        case .voice(let duration):
            dictionary[WatchLink.action] = WatchLink.voiceAction
            dictionary[WatchLink.duration] = duration
        }
        return dictionary
    }

    /// Calls only make sense right now; messages and denials can wait in WatchConnectivity's queue.
    var canWait: Bool { kind != .call }
}

/// How the watch sends a request.
enum WatchRoute: Equatable {
    /// `sendMessage`: the iPhone app answers at once.
    case live
    /// `transferUserInfo`: delivered when the iPhone app runs next.
    case queued
    case unavailable
}

extension WatchRequest {
    func route(activated: Bool, reachable: Bool) -> WatchRoute {
        guard activated else { return .unavailable }
        if reachable { return .live }
        return canWait ? .queued : .unavailable
    }
}

/// Request ids the iPhone already handled (a live request whose reply was lost is queued again).
struct HandledRequests: Equatable {
    static let limit = 100
    private(set) var ids: [String] = []

    /// True the first time an id is seen.
    mutating func insert(_ id: String) -> Bool {
        guard !ids.contains(id) else { return false }
        ids = Array((ids + [id]).suffix(Self.limit))
        return true
    }
}

/// What the watch shows: the active agent, its latest messages, a pending approval and the call's state.
struct WatchSnapshot: Codable, Equatable, Sendable {
    struct Message: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let fromAgent: Bool
        /// "New message" when the owner hid message text in notifications.
        let text: String
        let date: Date
    }

    struct Approval: Codable, Equatable, Sendable, Identifiable {
        let id: String
        /// The command, shortened for the small screen (the iPhone shows all of it).
        let command: String
    }

    enum CallState: String, Codable, Sendable { case ringing, connecting, connected }

    var agentName: String
    /// `AgentPalette` raw value.
    var palette: String
    var paired: Bool
    var messages: [Message]
    var approval: Approval?
    var call: CallState?

    init(agentName: String, palette: String, paired: Bool, messages: [Message], approval: Approval? = nil, call: CallState? = nil) {
        self.agentName = agentName
        self.palette = palette
        self.paired = paired
        self.messages = messages
        self.approval = approval
        self.call = call
    }

    static let empty = WatchSnapshot(agentName: "Hermes", palette: "gold", paired: false, messages: [])
    static let maxMessages = 12
    static let maxCommand = 160

    static func approval(id: String, command: String) -> Approval {
        Approval(id: id, command: command.count > maxCommand ? String(command.prefix(maxCommand - 1)) + "…" : command)
    }
}

/// Wrist haptics for the call's state (the call itself runs on the iPhone).
enum WatchCallCue: Equatable {
    case ringing, started, ended

    static func between(_ old: WatchSnapshot.CallState?, _ new: WatchSnapshot.CallState?) -> WatchCallCue? {
        guard old != new else { return nil }
        switch new {
        case .ringing: return .ringing
        case .connected: return .started
        case .connecting: return nil
        case nil: return old == nil ? nil : .ended
        }
    }
}
