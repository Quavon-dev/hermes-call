import HermesCallCore
import os
import UIKit
@preconcurrency import UserNotifications

/// Chat notifications: the alert push token, the categories (reply from the notification, answer or
/// deny a phone-context question), taps that open the chat, and no banners for the chat on screen.
@MainActor
final class ChatNotifications: NSObject {
    static let messageCategory = "chat"
    static let approvalCategory = "approval"
    nonisolated static let replyAction = "reply"
    /// Phone-context "Ask": open the app at the question, or deny it without opening.
    nonisolated static let answerQueryAction = "phone.answer"
    nonisolated static let denyQueryAction = "phone.deny"
    nonisolated static let phoneInfoCategory = "phone.info"

    private let app: AppModel
    private let chat: ChatModel
    private let phone: PhoneContextModel?
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "notifications")

    init(app: AppModel, chat: ChatModel, phone: PhoneContextModel? = nil) {
        self.app = app
        self.chat = chat
        self.phone = phone
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.messageCategory, actions: [reply], intentIdentifiers: [],
                                   options: [.hiddenPreviewsShowTitle]),
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PhoneContextModel.notificationCategory, actions: [
                UNNotificationAction(identifier: Self.answerQueryAction, title: "Answer…", options: [.foreground]),
                UNNotificationAction(identifier: Self.denyQueryAction, title: "Deny", options: [.destructive]),
            ], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.phoneInfoCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PlaceMonitor.notificationCategory,
                                   actions: [UNNotificationAction(identifier: PlaceMonitor.tellAction, title: "Tell \(app.activeProfile?.bridgeName ?? RelayProfile.defaultAgentName)")],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// Asks once; registering also works without permission (the token is still issued).
    func requestAuthorization() {
        #if DEBUG
        if ChatDemo.enabled { return }
        #endif
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didRegister(token: Data) {
        app.updateAlertToken(token.map { String(format: "%02x", $0) }.joined())
    }

    func didFailToRegister(_ error: Error) {
        log.error("alert push registration failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension ChatNotifications: UNUserNotificationCenterDelegate {
    // Completion-handler variants: the async ones return on a background executor under Swift 6, and
    // UIKit asserts that a response that foregrounds the app completes on the main thread.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let profile = (notification.request.content.userInfo["profile"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            let showing = chat.isVisible && app.isForeground && profile == app.activeProfile?.id
            completionHandler(showing ? [] : [.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let content = response.notification.request.content
        let tap = Tap(
            category: content.categoryIdentifier,
            action: response.actionIdentifier,
            reply: (response as? UNTextInputNotificationResponse)?.userText,
            profile: (content.userInfo["profile"] as? String).flatMap(UUID.init(uuidString:)),
            query: content.userInfo["query"] as? String,
            placeMessage: content.userInfo["place_message"] as? String
        )
        Task { @MainActor in
            await handle(tap)
            completionHandler()
        }
    }
}

private struct Tap: Sendable {
    let category: String
    let action: String
    let reply: String?
    let profile: UUID?
    let query: String?
    let placeMessage: String?
}

extension ChatNotifications {
    fileprivate func handle(_ tap: Tap) async {
        if let id = tap.profile, tap.reply == nil, id != app.activeProfile?.id, app.profiles.contains(where: { $0.id == id }) {
            app.activate(id)
        }
        switch tap.category {
        case PhoneContextModel.notificationCategory:
            // "Answer…" (or a tap) opens the app wherever it was: the question shows on top once its mail
            // is fetched. "Deny" answers without opening the app.
            if tap.action == Self.denyQueryAction, let query = tap.query {
                await phone?.deny(queryID: query, profileID: tap.profile)
            }
        case PlaceMonitor.notificationCategory:
            // A place reminder with the Ask rule: only the "Tell" button sends it to the agent.
            if tap.action == PlaceMonitor.tellAction, let text = tap.placeMessage {
                _ = await chat.send(text: text, profileID: tap.profile)
            }
        default:
            if let reply = tap.reply, tap.action == Self.replyAction {
                _ = await chat.send(text: reply, profileID: tap.profile)
            } else if tap.category != Self.phoneInfoCategory {
                // A tap opens the chat of the agent that wrote.
                app.openChat(tap.profile)
            }
        }
    }
}

/// UIKit callbacks that SwiftUI has no modifiers for (remote notification registration).
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor var notifications: ChatNotifications?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { notifications?.didRegister(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { notifications?.didFailToRegister(error) }
    }
}
