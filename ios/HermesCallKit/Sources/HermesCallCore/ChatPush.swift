import Foundation

/// What a decrypted alert push shows (Notification Service Extension). Apple and the relay only ever
/// see the ciphertext and the generic "New message"; this is worked out on the phone.
public struct PushPresentation: Equatable, Sendable {
    public enum Category: String, Sendable {
        case chat
        case approval
        /// A phone-context query the owner answers ("Answer…" / "Deny" actions).
        case phone
        /// A phone-context query that is not allowed: information only.
        case phoneInfo = "phone.info"
    }

    public var profileID: UUID
    public var agentName: String
    public var palette: AgentPalette
    public var title: String
    public var body: String
    public var category: Category
    public var timeSensitive = false
    public var queryID: String?
    /// Chat messages: the message (for the sender's avatar and photo previews).
    public var message: ChatMessage?

    /// The notification's `userInfo`.
    public var userInfo: [String: String] {
        var info = ["profile": profileID.uuidString]
        if let queryID { info["query"] = queryID }
        return info
    }
}

public enum ChatPush {
    /// Tries every paired profile's keys (the push does not say which relay it came from); nil when none
    /// opens it, it is a replay, or it is not something to show.
    public static func presentation(sealed: String, profiles: [RelayProfile], mailStore: UserDefaults?, showText: Bool,
                                    permission: (PhoneCapability) -> PhonePermission) -> PushPresentation? {
        for profile in profiles {
            guard let bridgeKey = try? Base64URL.decode(profile.bridgeBoxKey, length: 32),
                  let channel = try? profile.channel(seenStore: nil, mailStore: mailStore),
                  let body = try? channel.peekMail(from: profile.bridgeID, peerKey: bridgeKey, data: sealed) else { continue }
            return presentation(body: body, profile: profile, showText: showText, permission: permission)
        }
        return nil
    }

    static func presentation(body: [String: JSON], profile: RelayProfile, showText: Bool,
                             permission: (PhoneCapability) -> PhonePermission) -> PushPresentation? {
        var shown = PushPresentation(profileID: profile.id, agentName: profile.bridgeName, palette: profile.agentPalette,
                                     title: profile.bridgeName, body: "New message", category: .chat)
        if body["type"]?.string == "approval_request" {
            shown.category = .approval
            shown.title = "Approval needed"
            shown.body = "\(profile.bridgeName) wants to run a command. Open to approve or deny."
            shown.timeSensitive = true
            return shown
        }
        if let query = PhoneQuery.parse(body) {
            // The extension cannot read iOS data; the app answers once it is opened.
            shown.queryID = query.queryID
            shown.title = "\(profile.bridgeName) asks for: \(query.capability.title)"
            shown.timeSensitive = true
            if permission(query.capability) == .no {
                shown.category = .phoneInfo
                shown.body = "Not allowed (Settings › Phone access). “\(query.reason)”"
            } else {
                shown.category = .phone
                shown.body = "“\(query.reason)”"
            }
            return shown
        }
        guard let message = ChatWire.message(from: body) else { return nil }
        shown.message = message
        shown.body = showText ? message.preview : "New message"
        shown.timeSensitive = message.kind == "missed_call" || message.kind == "declined_call"
        return shown
    }
}
