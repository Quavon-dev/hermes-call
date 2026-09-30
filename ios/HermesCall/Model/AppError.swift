import Foundation

/// Something the owner should know about, with what they can do about it. One at a time, shown as an
/// alert with a recovery button where there is one.
enum AppError: Equatable, Identifiable, Sendable {
    case keychainUnreadable
    case profileDamaged(agent: String)
    case microphoneDenied
    case cameraDenied
    case fileTooLarge
    /// Something would go to the agent before the owner agreed to share with it.
    case consentRequired
    case message(String)

    enum Recovery: Equatable, Sendable {
        case openSettings, reviewConsent, showRelays
    }

    var id: String { title + "|" + message }

    var title: String {
        switch self {
        case .keychainUnreadable: "Saved agents unreadable"
        case .profileDamaged: "Pairing damaged"
        case .microphoneDenied: "Microphone is off"
        case .cameraDenied: "Camera is off"
        case .fileTooLarge: "File too large"
        case .consentRequired: "Sharing not allowed yet"
        case .message: "Hermes Call"
        }
    }

    var message: String {
        switch self {
        case .keychainUnreadable:
            "Your saved agents could not be read from the Keychain. Unlock the iPhone and open the app again; if it keeps "
                + "happening, pair your agent again."
        case .profileDamaged(let agent):
            "The pairing with \(agent) is damaged. Remove it in Relays and pair again with a new code from your bridge."
        case .microphoneDenied:
            "Calls and voice notes need the microphone. Allow it in Settings › Hermes Call › Microphone."
        case .cameraDenied:
            "Scanning a pairing code and showing things to your agent need the camera. Allow it in Settings › Hermes Call › Camera."
        case .fileTooLarge:
            "Files can be at most 10 MB."
        case .consentRequired:
            "Before anything goes to your agent, allow Hermes Call to share it. Your agent may pass it to an AI service."
        case .message(let text):
            text
        }
    }

    var recovery: Recovery? {
        switch self {
        case .microphoneDenied, .cameraDenied: .openSettings
        case .consentRequired: .reviewConsent
        case .profileDamaged: .showRelays
        case .keychainUnreadable, .fileTooLarge, .message: nil
        }
    }

    var recoveryTitle: String? {
        switch recovery {
        case .openSettings: "Open Settings"
        case .reviewConsent: "Review"
        case .showRelays: "Relays"
        case nil: nil
        }
    }
}

/// Screens any model can ask the root view to show (error recovery, deep links).
enum AppRoute: Identifiable, Equatable {
    case consent
    case relays
    /// A `hermescall://pair…` link: the pairing sheet with it filled in (it still asks before pairing).
    case pair(String)

    var id: String {
        switch self {
        case .consent: "consent"
        case .relays: "relays"
        case .pair(let link): "pair-\(link)"
        }
    }
}
