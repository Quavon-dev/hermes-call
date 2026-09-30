import Darwin
import notify
import Foundation

/// Payload-free signals between the app and its extensions (Darwin notifications, `notify(3)`):
/// "the chat store changed", and a ping the app answers while it is running.
public enum SharedSignal {
    /// A process wrote to the chat store (history or outbox).
    public static let chatChanged = "\(SharedContainer.appGroup).chat.changed"
    /// An extension asks whether the app is running; the app answers `appPong` and sends the outbox.
    public static let appPing = "\(SharedContainer.appGroup).app.ping"
    public static let appPong = "\(SharedContainer.appGroup).app.pong"

    public static func post(_ name: String) {
        notify_post(name)
    }

    /// Every post of `name` from now on, until the stream is dropped or its task cancelled.
    public static func observe(_ name: String) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, DispatchQueue.global(qos: .utility)) { _ in
                continuation.yield()
            }
            guard status == 0 else {
                continuation.finish()
                return
            }
            let registered = token
            continuation.onTermination = { _ in notify_cancel(registered) }
        }
    }

    /// True when a running app answers `ping` with `pong` within `timeout`.
    public static func probe(ping: String = appPing, pong: String = appPong, timeout: Duration = .seconds(1)) async -> Bool {
        let replies = observe(pong)
        post(ping)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in replies { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let answered = await group.next() ?? false
            group.cancelAll()
            return answered
        }
    }
}
