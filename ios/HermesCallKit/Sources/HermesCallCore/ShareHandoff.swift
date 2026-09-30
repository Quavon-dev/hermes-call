import Foundation

/// How the share extension gets a stored message to the bridge. The relay keeps one connection per
/// device and drops the older one, so the extension must not connect while the app has a connection
/// (e.g. during a call). It therefore asks the app first (`SharedSignal.probe`): a running app answers
/// at once and sends the outbox itself. Only when no app answers within the timeout — it is suspended or
/// not running, so it holds no live connection worth keeping — does the extension connect and send,
/// holding a claim on the message so an app that wakes up meanwhile does not send it twice.
public enum ShareHandoff {
    public enum Route: Equatable, Sendable {
        /// The running app sends it (over its own relay connection).
        case app
        /// The extension sent it and the bridge confirmed it.
        case sentHere
        /// Not confirmed yet: it stays in the outbox for the app.
        case waiting
    }

    public static let claimOwner = "share"
    /// Longer than the extension's connect (10 s) + confirmation wait (15 s).
    static let claimDuration: TimeInterval = 40

    /// `message` is already in `store` as pending.
    public static func deliver(_ message: ChatMessage, profile: UUID, store: ChatStore,
                               appIsRunning: @Sendable () async -> Bool,
                               sendHere: @Sendable () async -> Bool) async -> Route {
        if await appIsRunning() { return .app }
        // The app may have woken up and taken it meanwhile.
        guard await store.claim(message.id, in: profile, owner: claimOwner, for: claimDuration) else { return .app }
        let delivered = await sendHere()
        _ = try? await store.update(message.id, in: profile) { stored in
            if stored.status != .delivered { stored.status = delivered ? .delivered : .pending }
        }
        await store.releaseClaim(message.id, in: profile, owner: claimOwner)
        return delivered ? .sentHere : .waiting
    }
}
