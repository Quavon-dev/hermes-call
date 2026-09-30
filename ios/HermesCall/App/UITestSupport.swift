#if DEBUG
import Foundation
import HermesCallCore

/// Launch arguments for UI tests and screenshots (debug builds only).
/// `-UITestReset YES`: start like a fresh install (no agents, no settings, no demo chat).
/// `-UITestConsent YES`: sharing already allowed (skips the consent screen).
/// `-UITestAgents YES` (with reset): two paired agents on an unreachable relay, each with a message and
/// unread ones, for the chat list.
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
        UnreadCounts().save()
        ChatBadge.reset()
        if defaults.bool(forKey: "UITestAgents") { seedAgents() }
    }

    /// Nova (two unread messages) and Iris (read), paired to `relay.invalid`.
    private static func seedAgents() {
        let now = Date()
        let seeds: [(name: String, palette: AgentPalette, text: String, age: TimeInterval, unread: Int)] = [
            ("Iris", .violet, "The package was delivered to the front desk.", 26 * 3600, 0),
            ("Nova", .emerald, "Your flight tomorrow leaves at **9:40** from gate B12. Check-in is open.", 600, 2),
        ]
        var profiles: [RelayProfile] = []
        var unread = UnreadCounts()
        for seed in seeds {
            guard let keys = try? DeviceKeys.generate() else { continue }
            let profile = RelayProfile(id: UUID(), label: seed.name, relay: RelayAddress(host: "relay.invalid", port: 443), pin: "",
                                       deviceID: "ui-\(seed.name)", bridgeID: "ui-bridge", bridgeName: seed.name,
                                       bridgeBoxKey: Base64URL.encode(Sodium.randomBytes(32)),
                                       bridgeSignKey: Base64URL.encode(Sodium.randomBytes(32)), keys: keys, created: now,
                                       palette: seed.palette)
            profiles.append(profile)
            for _ in 0..<seed.unread { unread.add(profile.id) }
            let message = ChatMessage(id: E2EChannel.newMessageID(), role: .agent, text: seed.text, date: now.addingTimeInterval(-seed.age),
                                      status: .received)
            Task { _ = try? await ChatStore.shared.upsert(message, in: profile.id) }
        }
        try? ProfileStore().save(profiles)
        unread.save()
        UserDefaults.standard.set(true, forKey: "onboardingDone")
    }
}
#endif
