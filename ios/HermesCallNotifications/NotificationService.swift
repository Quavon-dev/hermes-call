import Foundation
import HermesCallCore
import Intents
import os
@preconcurrency import UserNotifications
import WidgetKit

/// Decrypts chat pushes on this phone: Apple and the relay only ever see ciphertext and the generic
/// "New message" text. Nothing is marked as read here; the app fetches the mail itself.
/// Agent messages become communication notifications (the agent's name and presence as the sender, so
/// Focus can let them through), count on the app badge, and show a photo when the app is not running.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    /// `didReceive` and `serviceExtensionTimeWillExpire` come on different threads: the handler and the
    /// best content so far are only touched under `lock`.
    private let lock = NSLock()
    private var deliver: ((UNNotificationContent) -> Void)?
    private var best: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.categoryIdentifier = PushPresentation.Category.chat.rawValue
        lock.withLock {
            deliver = contentHandler
            best = content
        }
        guard let sealed = request.content.userInfo["e"] as? String,
              let shown = ChatPush.presentation(sealed: sealed, profiles: (try? ProfileStore().load()) ?? [],
                                                mailStore: SharedContainer.defaults, showText: SharedContainer.showMessageText,
                                                permission: PhoneAccessSettings().permission(for:))
        else { return finish(content) }
        Self.apply(shown, to: content)
        guard let message = shown.message, message.role == .agent else { return finish(content) }
        content.badge = NSNumber(value: ChatBadge.increment())
        if SharedContainer.showMessageText {
            ChatSnapshot(agentName: shown.agentName, preview: message.preview, date: message.date, fromAgent: true,
                         profileID: shown.profileID).save()
            WidgetCenter.shared.reloadTimelines(ofKind: "HermesCallChat")
        }
        let styled = Self.fromAgent(content, shown: shown)
        lock.withLock { best = styled }
        Task {
            let final = await Self.withPhoto(styled, shown: shown, message: message)
            self.finish(final)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        let (handler, content) = lock.withLock { (deliver, best) }
        if let handler, let content { finish(content, handler: handler) }
    }

    private func finish(_ content: UNNotificationContent) {
        guard let handler = lock.withLock({ deliver }) else { return }
        finish(content, handler: handler)
    }

    /// Hands over the content once (a late photo download must not deliver twice).
    private func finish(_ content: UNNotificationContent, handler: (UNNotificationContent) -> Void) {
        let first = lock.withLock {
            defer { deliver = nil }
            return deliver != nil
        }
        if first { handler(content) }
    }

    private static func apply(_ shown: PushPresentation, to content: UNMutableNotificationContent) {
        content.userInfo = shown.userInfo
        content.threadIdentifier = shown.profileID.uuidString
        // The agent's id: the Focus filter (Settings › Focus › Hermes Call) lets chosen agents through.
        content.filterCriteria = shown.profileID.uuidString
        content.title = shown.title
        content.body = shown.body
        content.categoryIdentifier = shown.category.rawValue
        if shown.timeSensitive { content.interruptionLevel = .timeSensitive }
    }

    /// A communication notification: the agent (name and presence) as the sender of a message.
    private static func fromAgent(_ content: UNMutableNotificationContent, shown: PushPresentation) -> UNNotificationContent {
        let image = (try? Data(contentsOf: SharedContainer.presenceStillURL(shown.palette))).map(INImage.init(imageData:))
        let sender = INPerson(personHandle: INPersonHandle(value: shown.profileID.uuidString, type: .unknown), nameComponents: nil,
                              displayName: shown.agentName, image: image, contactIdentifier: nil, customIdentifier: shown.profileID.uuidString)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: shown.body,
                                         speakableGroupName: nil, conversationIdentifier: shown.profileID.uuidString,
                                         serviceName: "Hermes Call", sender: sender, attachments: nil)
        intent.setImage(image, forParameterNamed: \.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        do {
            return try content.updating(from: intent)
        } catch {
            return content
        }
    }

    /// Photos: only with message text shown, and only when the app is not running (it would lose its relay
    /// connection to ours; a running app shows the photo itself). The relay copy stays for the app.
    private static func withPhoto(_ content: UNNotificationContent, shown: PushPresentation, message: ChatMessage) async
        -> UNNotificationContent {
        guard SharedContainer.showMessageText,
              let photo = message.attachments.first(where: { $0.kind == .photo && $0.size <= 5_000_000 }),
              let blobID = photo.blobID, let keyText = photo.key, let key = try? Base64URL.decode(keyText, length: 32),
              let profile = ((try? ProfileStore().load()) ?? []).first(where: { $0.id == shown.profileID }),
              !(await SharedSignal.probe(timeout: .milliseconds(500))),
              let session = try? RelaySession(profile: profile, acceptsMail: false) else { return content }
        defer { Task { await session.stop() } }
        do {
            try await session.waitUntilConnected(timeout: 8)
            let data = try Blob.open(try await session.downloadBlob(blobID, maxSize: 6_000_000), key: key)
            guard let jpeg = PhotoEncoder.jpeg(data, maxSide: 1024) else { return content }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(photo.id).jpg")
            try jpeg.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
            let attachment = try UNNotificationAttachment(identifier: photo.id, url: file)
            guard let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
            mutable.attachments = [attachment]
            return mutable
        } catch {
            Logger(subsystem: "de.quavon.hermescall.notifications", category: "push")
                .error("photo preview failed: \(String(describing: error), privacy: .public)")
            return content
        }
    }
}
