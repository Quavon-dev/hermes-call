import Foundation

/// Data shared between the app and its extensions (notification service, share, widget).
public enum SharedContainer {
    /// From the Info.plist key `HermesCallAppGroup` (`$(HC_APP_GROUP)`, ios/Config/Identity.xcconfig);
    /// the project's own group when missing (unit tests).
    public static let appGroup = Bundle.main.object(forInfoDictionaryKey: "HermesCallAppGroup") as? String
        ?? "group.de.quavon.hermescall"

    /// The app group's defaults (mailbox replay ids, notification preferences); `.standard` when the
    /// app group is unavailable (unsigned test builds).
    public static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    /// The app group directory, or the app's Application Support in unsigned test builds.
    public static var directory: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return url }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Keychain access group from the Info.plist key `HermesCallKeychainGroup`
    /// (`$(AppIdentifierPrefix)$(HC_BUNDLE_ID).shared`), nil when not configured.
    public static var keychainGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HermesCallKeychainGroup") as? String,
              group.hasSuffix(".shared"), !group.hasPrefix(".") else { return nil }
        return group
    }

    /// Notification setting shared with the notification extension.
    public static let showMessageTextKey = "notifications.showText"

    public static var showMessageText: Bool {
        defaults.object(forKey: showMessageTextKey) as? Bool ?? true
    }

    /// The app's appearance (`standard` / `hud`), so the widget can match it.
    public static let appearanceKey = "appearance"

    public static var usesHUD: Bool {
        defaults.string(forKey: appearanceKey) == "hud"
    }

    /// The owner agreed that what they send may reach their agent's AI model (App Review 5.1.2(i)); the app
    /// and the share extension send nothing to an agent without it. The number is the version of the wording.
    public static let aiConsentKey = "consent.aiSharing"
    public static let aiConsentVersion = 1

    public static var hasAIConsent: Bool {
        defaults.integer(forKey: aiConsentKey) >= aiConsentVersion
    }
}
