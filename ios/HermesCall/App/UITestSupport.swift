#if DEBUG
import Foundation
import HermesCallCore

/// Launch arguments for UI tests and screenshots (debug builds only).
/// `-UITestReset YES`: start like a fresh install (no agents, no settings, no demo chat).
/// `-UITestConsent YES`: sharing already allowed (skips the consent screen).
enum UITestSupport {
    static var isResetRequested: Bool { UserDefaults.standard.bool(forKey: "UITestReset") }

    static func resetIfRequested() {
        let defaults = UserDefaults.standard
        guard isResetRequested else { return }
        try? ProfileStore().deleteAll()
        for key in ["talkMode", "includeInRecents", "activeProfile", "onboardingDone", "pushRegistrations", "speechRecognition",
                    "alertRegistrations", "voiceHaptics", "showCaptions", "presenceHints", "appIcon", "voiceReplies",
                    "autoPlayVoiceReplies", "taskDetailsOnLockScreen", "demoActive"] {
            defaults.removeObject(forKey: key)
        }
        SharedContainer.defaults.set(defaults.bool(forKey: "UITestConsent") ? SharedContainer.aiConsentVersion : 0,
                                     forKey: SharedContainer.aiConsentKey)
        let chats = SharedContainer.directory.appendingPathComponent("Chats")
        try? FileManager.default.removeItem(at: chats)
    }
}
#endif
