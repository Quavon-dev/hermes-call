import Foundation

/// A `hermescall://` link. Any app or web page can open one, so a call link from outside is only a
/// request the owner confirms ("Call Atlas?"), and an agent named in an outside link never becomes the
/// active agent by itself. Only the app's own widget can skip that: it adds the per-install
/// `LinkSecret` (`s=`), which other apps cannot read (it lives in the app group). Siri, Shortcuts, the
/// Control Center control and the Action button use `CallAgentIntent`, not links.
public enum DeepLink: Equatable, Sendable {
    /// A pairing link (the pairing sheet asks before pairing).
    case pair(String)
    /// Open the chat; `agent` only when the link came from the app's own widget.
    case chat(agent: UUID?)
    /// Start a call: at once when `trusted`, after a confirmation otherwise.
    case call(agent: UUID?, trusted: Bool)
    /// Just open the app (Live Activity).
    case open

    public static let scheme = "hermescall"

    public static func parse(_ url: URL, secret: String?) -> DeepLink? {
        guard url.scheme == scheme else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let trusted = LinkSecret.matches(value(LinkSecret.parameter), secret)
        let agent = value("agent").flatMap(UUID.init(uuidString:))
        switch url.host {
        case "pair": return .pair(url.absoluteString)
        case "chat": return .chat(agent: trusted ? agent : nil)
        case "call": return .call(agent: agent, trusted: trusted)
        case "open": return .open
        default: return nil
        }
    }
}

/// The per-install secret that marks the app's own widget links (see `DeepLink`).
public enum LinkSecret {
    public static let key = "links.secret"
    public static let parameter = "s"

    public static func current(_ defaults: UserDefaults = SharedContainer.defaults) -> String? {
        defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The secret, created (32 random bytes) the first time; the app calls this at launch.
    @discardableResult
    public static func ensure(_ defaults: UserDefaults = SharedContainer.defaults) -> String {
        if let existing = current(defaults) { return existing }
        var generator = SystemRandomNumberGenerator()
        let secret = Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
        defaults.set(secret, forKey: key)
        return secret
    }

    /// Constant-time comparison; an empty or missing value never matches.
    public static func matches(_ given: String?, _ secret: String?) -> Bool {
        guard let given, let secret, !secret.isEmpty else { return false }
        let a = Array(given.utf8), b = Array(secret.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// `hermescall://<host>?agent=<id>&s=<secret>` for the widget (without `s` when there is no secret yet:
    /// the app then asks, as for any outside link).
    public static func link(_ host: String, agent: UUID?, secret: String? = current()) -> URL? {
        var components = URLComponents()
        components.scheme = DeepLink.scheme
        components.host = host
        var items: [URLQueryItem] = []
        if let agent { items.append(URLQueryItem(name: "agent", value: agent.uuidString)) }
        if let secret, !secret.isEmpty { items.append(URLQueryItem(name: parameter, value: secret)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}
