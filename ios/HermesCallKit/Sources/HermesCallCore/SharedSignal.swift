import Darwin
import notify
import Foundation

/// Payload-free signals between the app and its extensions (Darwin notifications, `notify(3)`):
/// "the chat store changed", and a ping the app answers while it is running.
///
/// Darwin notifications are system-wide: any app can post or observe these names. So a pong alone
/// proves nothing. The probing extension writes a fresh random nonce into the app group
/// (`handshake`/requests), the app answers by creating `handshake`/answers/<nonce> before it posts the
/// pong, and the extension believes only that file. Other apps cannot reach the app group, so a
/// spoofed pong cannot make an extension leave a message to an app that is not running. (Others can
/// still see that a ping happened, and a spoofed ping only makes the app send its outbox.)
public enum SharedSignal {
    /// A process wrote to the chat store (history or outbox).
    public static let chatChanged = "\(SharedContainer.appGroup).chat.changed"
    /// An extension asks whether the app is running; the app answers `appPong` and sends the outbox.
    public static let appPing = "\(SharedContainer.appGroup).app.ping"
    public static let appPong = "\(SharedContainer.appGroup).app.pong"

    /// Where probes and answers meet (in the app group).
    public static var defaultHandshake: URL { SharedContainer.directory.appendingPathComponent("signals", isDirectory: true) }

    /// Requests older than this are not answered (and are cleaned up).
    static let requestLifetime: TimeInterval = 30

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

    /// True when a running app answers this probe within `timeout`: a pong, and the app's answer for this
    /// probe's nonce in `handshake`.
    public static func probe(ping: String = appPing, pong: String = appPong, timeout: Duration = .seconds(1),
                             handshake: URL = defaultHandshake) async -> Bool {
        guard let nonce = request(handshake) else { return false }
        defer { finish(nonce, handshake) }
        let replies = observe(pong)
        post(ping)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in replies where answered(nonce, handshake) { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// The app's side of `probe`: answers every open request, then posts the pong.
    public static func answer(pong: String = appPong, handshake: URL = defaultHandshake) {
        let manager = FileManager.default
        let requests = handshake.appendingPathComponent("requests", isDirectory: true)
        let answers = handshake.appendingPathComponent("answers", isDirectory: true)
        try? manager.createDirectory(at: answers, withIntermediateDirectories: true)
        let names = (try? manager.contentsOfDirectory(at: requests, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in names {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > requestLifetime {
                try? manager.removeItem(at: file)
            } else if validNonce(file.lastPathComponent) {
                manager.createFile(atPath: answers.appendingPathComponent(file.lastPathComponent).path, contents: nil)
            }
        }
        post(pong)
    }

    // MARK: handshake files

    static func request(_ handshake: URL) -> String? {
        let requests = handshake.appendingPathComponent("requests", isDirectory: true)
        try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        let nonce = Base64URL.encode(Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
        let created = FileManager.default.createFile(atPath: requests.appendingPathComponent(nonce).path, contents: nil)
        return created ? nonce : nil
    }

    static func answered(_ nonce: String, _ handshake: URL) -> Bool {
        FileManager.default.fileExists(atPath: handshake.appendingPathComponent("answers/\(nonce)").path)
    }

    static func finish(_ nonce: String, _ handshake: URL) {
        try? FileManager.default.removeItem(at: handshake.appendingPathComponent("requests/\(nonce)"))
        try? FileManager.default.removeItem(at: handshake.appendingPathComponent("answers/\(nonce)"))
    }

    static func validNonce(_ name: String) -> Bool {
        (try? Base64URL.decode(name, length: 16)) != nil
    }
}
