import HermesCallCore
import UserNotifications
import WidgetKit

/// Decrypts chat pushes on this phone: Apple and the relay only ever see ciphertext and the
/// generic "New message" text. Nothing is marked as read here; the app fetches the mail itself.
final class NotificationService: UNNotificationServiceExtension {
    private var deliver: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.categoryIdentifier = "chat"
        deliver = contentHandler
        fallback = content
        if let sealed = request.content.userInfo["e"] as? String {
            ChatPush.apply(sealed, to: content)
        }
        contentHandler(content)
        deliver = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let deliver, let fallback { deliver(fallback) }
    }
}

enum ChatPush {
    static func apply(_ sealed: String, to content: UNMutableNotificationContent) {
        guard let profiles = try? ProfileStore().load() else { return }
        for profile in profiles {
            guard let bridgeKey = try? Base64URL.decode(profile.bridgeBoxKey, length: 32),
                  let channel = try? profile.channel(seenStore: nil, mailStore: SharedContainer.defaults),
                  let body = try? channel.peekMail(from: profile.bridgeID, peerKey: bridgeKey, data: sealed) else { continue }
            content.userInfo = ["profile": profile.id.uuidString]
            content.threadIdentifier = profile.id.uuidString
            content.title = profile.bridgeName
            if body["type"]?.string == "approval_request" {
                content.categoryIdentifier = "approval"
                content.title = "Approval needed"
                content.body = "\(profile.bridgeName) wants to run a command. Open to approve or deny."
                content.interruptionLevel = .timeSensitive
                return
            }
            if let query = PhoneQuery.parse(body) {
                // The extension cannot read iOS data; the app answers once it is opened.
                content.categoryIdentifier = "phone"
                content.userInfo["query"] = query.queryID
                content.title = "\(profile.bridgeName) asks for: \(query.capability.title)"
                content.body = PhoneAccessSettings().permission(for: query.capability) == .no
                    ? "Not allowed (Settings › Phone access). “\(query.reason)”"
                    : "“\(query.reason)” Open Hermes Call to answer."
                content.interruptionLevel = .timeSensitive
                return
            }
            guard let message = ChatWire.message(from: body) else { return }
            content.body = SharedContainer.showMessageText ? message.preview : "New message"
            if message.kind == "missed_call" || message.kind == "declined_call" { content.interruptionLevel = .timeSensitive }
            if SharedContainer.showMessageText, message.role == .agent {
                ChatSnapshot(agentName: profile.bridgeName, preview: message.preview, date: message.date, fromAgent: true).save()
                WidgetCenter.shared.reloadAllTimelines()
            }
            return
        }
    }
}
