import Foundation
import HermesCallCore
import WidgetKit

enum SpeechRecognition: String, CaseIterable, Identifiable, Sendable {
    case bridge, iPhone
    var id: String { rawValue }
    var title: String { self == .bridge ? "On bridge (Whisper)" : "On iPhone" }
}

enum TalkMode: String, CaseIterable, Identifiable, Sendable {
    case handsFree, pushToTalk
    var id: String { rawValue }
    var title: String { self == .handsFree ? "Hands-free" : "Push to talk" }
}

/// Which home-screen icon to show (Settings › App icon).
enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic, standard, presence
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Match appearance"
        case .standard: "Standard"
        case .presence: "Presence"
        }
    }

    /// The alternate icon name for an appearance (nil = the primary icon).
    func iconName(for appearance: Appearance) -> String? {
        switch self {
        case .automatic: appearance == .hud ? AppIconChoice.presenceIcon : nil
        case .standard: nil
        case .presence: AppIconChoice.presenceIcon
        }
    }

    static let presenceIcon = "AppIconPresence"
}

/// How long a finger rests on empty space in the presence before the menu opens.
enum MenuHold: String, CaseIterable, Identifiable, Sendable {
    case short, normal, long, veryLong
    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .short: 0.3
        case .normal: 0.42
        case .long: 0.8
        case .veryLong: 1.2
        }
    }
    var title: String {
        switch self {
        case .short: "Short (0.3 s)"
        case .normal: "Normal (0.4 s)"
        case .long: "Long (0.8 s)"
        case .veryLong: "Very long (1.2 s)"
        }
    }
}

/// Non-secret UI preferences.
@MainActor @Observable
final class Preferences {
    private let defaults: UserDefaults

    var talkMode: TalkMode { didSet { defaults.set(talkMode.rawValue, forKey: "talkMode") } }
    var includeInRecents: Bool { didSet { defaults.set(includeInRecents, forKey: "includeInRecents") } }
    var activeProfileID: UUID? { didSet { defaults.set(activeProfileID?.uuidString, forKey: "activeProfile") } }
    var speechRecognition: SpeechRecognition { didSet { defaults.set(speechRecognition.rawValue, forKey: "speechRecognition") } }
    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            Self.shareAppearance(appearance)
        }
    }
    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    /// HUD calls: a soft vibration follows the agent's voice.
    var voiceHaptics: Bool { didSet { defaults.set(voiceHaptics, forKey: "voiceHaptics") } }
    /// HUD calls: the spoken lines appear under the presence.
    var showCaptions: Bool { didSet { defaults.set(showCaptions, forKey: "showCaptions") } }
    /// HUD calls: the agent speaks through the loudspeaker (unless AirPods, headphones or a car carry the call).
    var presenceSpeaker: Bool { didSet { defaults.set(presenceSpeaker, forKey: "presenceSpeaker") } }
    /// HUD: how long to hold on empty space before the menu opens.
    var menuHold: MenuHold { didSet { defaults.set(menuHold.rawValue, forKey: "menuHold") } }
    var appIcon: AppIconChoice { didSet { defaults.set(appIcon.rawValue, forKey: "appIcon") } }
    /// Voice notes ask the agent to answer by voice too (sent with each voice note).
    var voiceReplies: Bool { didSet { defaults.set(voiceReplies, forKey: "voiceReplies") } }
    /// Voice replies play by themselves while the app is open (never during a call).
    var autoPlayVoiceReplies: Bool { didSet { defaults.set(autoPlayVoiceReplies, forKey: "autoPlayVoiceReplies") } }
    /// Live Activity pushes (plaintext to Apple) may name the current step instead of "Working…".
    var taskDetailsOnLockScreen: Bool {
        didSet { defaults.set(taskDetailsOnLockScreen, forKey: "taskDetailsOnLockScreen") }
    }
    /// Relay profile id → "environment:token" last registered there.
    var pushRegistrations: [String: String] { didSet { defaults.set(pushRegistrations, forKey: "pushRegistrations") } }
    /// Same for the chat (alert) push token.
    var alertRegistrations: [String: String] { didSet { defaults.set(alertRegistrations, forKey: "alertRegistrations") } }
    /// Lock-screen notifications show the decrypted message text (decrypted on this phone only).
    var showMessageText: Bool {
        didSet { SharedContainer.defaults.set(showMessageText, forKey: SharedContainer.showMessageTextKey) }
    }

    /// Sharing with the agent's AI model is allowed (ConsentView); in the app group for the share extension.
    var aiConsent: Bool {
        didSet { shared.set(aiConsent ? SharedContainer.aiConsentVersion : 0, forKey: SharedContainer.aiConsentKey) }
    }
    /// The offline demo agent is shown (DemoAgent).
    var demoActive: Bool { didSet { defaults.set(demoActive, forKey: "demoActive") } }
    private let shared: UserDefaults

    init(defaults: UserDefaults = .standard, shared: UserDefaults = SharedContainer.defaults) {
        self.defaults = defaults
        self.shared = shared
        aiConsent = shared.integer(forKey: SharedContainer.aiConsentKey) >= SharedContainer.aiConsentVersion
        demoActive = defaults.bool(forKey: "demoActive")
        talkMode = TalkMode(rawValue: defaults.string(forKey: "talkMode") ?? "") ?? .handsFree
        includeInRecents = defaults.object(forKey: "includeInRecents") as? Bool ?? true
        activeProfileID = defaults.string(forKey: "activeProfile").flatMap(UUID.init(uuidString:))
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        voiceHaptics = defaults.object(forKey: "voiceHaptics") as? Bool ?? true
        showCaptions = defaults.object(forKey: "showCaptions") as? Bool ?? true
        presenceSpeaker = defaults.object(forKey: "presenceSpeaker") as? Bool ?? true
        menuHold = MenuHold(rawValue: defaults.string(forKey: "menuHold") ?? "") ?? .normal
        speechRecognition = SpeechRecognition(rawValue: defaults.string(forKey: "speechRecognition") ?? "") ?? .bridge
        appIcon = AppIconChoice(rawValue: defaults.string(forKey: "appIcon") ?? "") ?? .automatic
        voiceReplies = defaults.object(forKey: "voiceReplies") as? Bool ?? true
        autoPlayVoiceReplies = defaults.bool(forKey: "autoPlayVoiceReplies")
        taskDetailsOnLockScreen = defaults.bool(forKey: "taskDetailsOnLockScreen")
        let appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .standard
        self.appearance = appearance
        Self.shareAppearance(appearance)
        pushRegistrations = defaults.dictionary(forKey: "pushRegistrations") as? [String: String] ?? [:]
        alertRegistrations = defaults.dictionary(forKey: "alertRegistrations") as? [String: String] ?? [:]
        showMessageText = SharedContainer.showMessageText
    }

    /// The widget reads the appearance from the app group.
    private static func shareAppearance(_ appearance: Appearance) {
        guard SharedContainer.defaults.string(forKey: SharedContainer.appearanceKey) != appearance.rawValue else { return }
        SharedContainer.defaults.set(appearance.rawValue, forKey: SharedContainer.appearanceKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func reset() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(E2EChannel.seenKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        for key in ["talkMode", "includeInRecents", "activeProfile", "onboardingDone", "pushRegistrations", "appearance",
                    "speechRecognition", "alertRegistrations", "voiceHaptics", "showCaptions", "presenceSpeaker", "menuHold", "presenceHints",
                    "appIcon", "voiceReplies", "autoPlayVoiceReplies", "taskDetailsOnLockScreen", "demoActive"] {
            defaults.removeObject(forKey: key)
        }
        for key in shared.dictionaryRepresentation().keys
        where key.hasPrefix(E2EChannel.mailKeyPrefix) || key == SharedContainer.showMessageTextKey
            || key == SharedContainer.appearanceKey || key == SharedContainer.aiConsentKey {
            shared.removeObject(forKey: key)
        }
        aiConsent = false
        demoActive = false
        alertRegistrations = [:]
        showMessageText = true
        talkMode = .handsFree
        includeInRecents = true
        activeProfileID = nil
        onboardingDone = false
        voiceHaptics = true
        showCaptions = true
        pushRegistrations = [:]
        appearance = .standard
        speechRecognition = .bridge
        appIcon = .automatic
        voiceReplies = true
        autoPlayVoiceReplies = false
        taskDetailsOnLockScreen = false
    }
}
