import HermesCallCore
import os
import UIKit
@preconcurrency import UserNotifications

/// Chat notifications: the alert push token, the categories (reply from the notification),
/// taps that open the chat, and no banners for the chat that is already on screen.
@MainActor
final class ChatNotifications: NSObject {
    static let messageCategory = "chat"
    static let approvalCategory = "approval"
    nonisolated static let replyAction = "reply"

    private let app: AppModel
    private let chat: ChatModel
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "notifications")

    init(app: AppModel, chat: ChatModel) {
        self.app = app
        self.chat = chat
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.messageCategory, actions: [reply], intentIdentifiers: [],
                                   options: [.hiddenPreviewsShowTitle]),
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PhoneContextModel.notificationCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PlaceMonitor.notificationCategory,
                                   actions: [UNNotificationAction(identifier: PlaceMonitor.tellAction, title: "Tell \(app.activeProfile?.bridgeName ?? RelayProfile.defaultAgentName)")],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// Asks once; registering also works without permission (the token is still issued).
    func requestAuthorization() {
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

    private func profileID(_ content: UNNotificationContent) -> UUID? {
        (content.userInfo["profile"] as? String).flatMap(UUID.init(uuidString:))
    }
}

extension ChatNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        return await MainActor.run {
            let showing = chat.isVisible && app.isForeground && profileID(content) == app.activeProfile?.id
            return showing ? [] : [.banner, .list, .sound]
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            if let id = profileID(content), id != app.activeProfile?.id, app.profiles.contains(where: { $0.id == id }) {
                if reply == nil { app.activate(id) }
            }
        }
        if content.categoryIdentifier == PlaceMonitor.notificationCategory {
            // A place reminder with the Ask rule: only the "Tell" button sends it to the agent.
            if response.actionIdentifier == PlaceMonitor.tellAction, let text = content.userInfo["place_message"] as? String {
                let profile = await MainActor.run { profileID(content) }
                await chat.send(text: text, profileID: profile)
            }
            return
        }
        if let reply, response.actionIdentifier == Self.replyAction {
            let profile = await MainActor.run { profileID(content) }
            await chat.send(text: reply, profileID: profile)
        } else if content.categoryIdentifier != PhoneContextModel.notificationCategory {
            // Phone queries open wherever the app was: the prompt shows on top.
            await MainActor.run { app.tab = .chat }
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
