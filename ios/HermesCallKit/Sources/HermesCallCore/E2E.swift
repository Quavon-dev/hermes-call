import Foundation

/// End-to-end channel between this device and its bridge (crypto_box), matching
/// hermescall_common.e2e: sender/recipient binding and strictly increasing timestamps.
///
/// Chat messages may arrive days late (relay mailbox, retries), so they carry a message id
/// `mid` instead: accepted once within `mailWindowMs`, in any order.
public final class E2EChannel: @unchecked Sendable {
    public static let maxSkewMs: Int64 = 120_000
    /// Longer than the relay mailbox keeps messages (7 days).
    public static let mailWindowMs: Int64 = 8 * 86_400_000
    static let maxSeenMail = 5000
    private let myID: String
    private let secretKey: Data
    private let lock = NSLock()
    private var lastSent: Int64 = 0
    private var lastSeen: [String: Int64] = [:]
    private let seenStore: UserDefaults?
    private let mailStore: UserDefaults?
    private var mailMemory: [String: Int64] = [:]

    public static let seenKeyPrefix = "e2e.seen."
    public static let mailKeyPrefix = "e2e.mail."

    /// `seenStore` keeps each peer's newest timestamp across app launches, so a relay cannot
    /// replay messages after a restart; `mailStore` does the same for mailbox message ids and
    /// must be shared with the notification extension (app group), which only reads it.
    public init(myID: String, secretKey: Data, seenStore: UserDefaults? = nil, mailStore: UserDefaults? = nil) {
        self.myID = myID
        self.secretKey = secretKey
        self.seenStore = seenStore
        self.mailStore = mailStore
    }

    private func seenKey(_ peerID: String) -> String { "\(Self.seenKeyPrefix)\(myID).\(peerID)" }
    private var mailKey: String { "\(Self.mailKeyPrefix)\(myID)" }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public static func newMessageID() -> String { Base64URL.encode(Sodium.randomBytes(16)) }

    /// `mid` marks a mailbox message (see the type comment).
    public func seal(to peerID: String, peerKey: Data, body: [String: JSON], mid: String? = nil) throws -> String {
        guard body["type"]?.string != nil else { throw ProtocolError.invalidField }
        let ts: Int64 = lock.withLock {
            lastSent = max(Self.nowMs(), lastSent + 1)
            return lastSent
        }
        var message = body
        message["from"] = .string(myID)
        message["to"] = .string(peerID)
        message["ts"] = .int(ts)
        if let mid {
            guard (try? Base64URL.decode(mid, length: 16)) != nil else { throw ProtocolError.invalidField }
            message["mid"] = .string(mid)
        }
        let plaintext = try JSON.object(message).encoded()
        guard plaintext.count <= 40 * 1024 else { throw ProtocolError.invalidField }
        return Base64URL.encode(try Sodium.boxSeal(plaintext, to: peerKey, from: secretKey))
    }

    public func open(from peerID: String, peerKey: Data, data: String) throws -> [String: JSON] {
        let body = try decrypt(from: peerID, peerKey: peerKey, data: data)
        guard let ts = body["ts"]?.int else { throw ProtocolError.invalidField }
        if let mid = body["mid"]?.string {
            try acceptMail(mid: mid, ts: ts)
            return body
        }
        try lock.withLock {
            let newest = lastSeen[peerID] ?? (seenStore?.object(forKey: seenKey(peerID)) as? Int64 ?? 0)
            guard abs(ts - Self.nowMs()) <= Self.maxSkewMs, ts > newest else {
                throw ProtocolError.staleOrReplayed
            }
            lastSeen[peerID] = ts
            seenStore?.set(ts, forKey: seenKey(peerID))
        }
        return body
    }

    /// Decrypts and checks a mailbox message without marking it seen: the app calls `markMailSeen` once
    /// it has stored the message (so a crash in between cannot lose it), the notification extension never
    /// does. Throws for replays of messages already marked.
    public func peekMail(from peerID: String, peerKey: Data, data: String) throws -> [String: JSON] {
        let body = try decrypt(from: peerID, peerKey: peerKey, data: data)
        guard let mid = body["mid"]?.string, let ts = body["ts"]?.int else { throw ProtocolError.invalidField }
        let seen = lock.withLock { loadSeenMail() }
        guard ts > mailFloor(seen), ts <= Self.nowMs() + Self.maxSkewMs, seen[mid] == nil else {
            throw ProtocolError.staleOrReplayed
        }
        return body
    }

    private func decrypt(from peerID: String, peerKey: Data, data: String) throws -> [String: JSON] {
        let sealed = try Base64URL.decode(data)
        guard let plaintext = try? Sodium.boxOpen(sealed, from: peerKey, to: secretKey),
              case .object(let body)? = try? JSON.decode(plaintext),
              body["ts"]?.int != nil, body["from"]?.string == peerID, body["to"]?.string == myID,
              body["type"]?.string != nil
        else { throw ProtocolError.invalidField }
        return body
    }

    /// Records a mailbox message as processed; later copies are rejected as replays.
    public func markMailSeen(mid: String, ts: Int64) {
        try? acceptMail(mid: mid, ts: ts)
    }

    // MARK: mailbox replay protection (key "" = newest timestamp ever evicted)

    private func loadSeenMail() -> [String: Int64] {
        guard let mailStore else { return mailMemory }
        return (mailStore.dictionary(forKey: mailKey) as? [String: Int64]) ?? [:]
    }

    private func mailFloor(_ seen: [String: Int64]) -> Int64 {
        max(Self.nowMs() - Self.mailWindowMs, seen[""] ?? 0)
    }

    private func acceptMail(mid: String, ts: Int64) throws {
        guard (try? Base64URL.decode(mid, length: 16)) != nil else { throw ProtocolError.invalidField }
        try lock.withLock {
            let stored = loadSeenMail()
            let now = Self.nowMs()
            var floor = mailFloor(stored)
            guard ts > floor, ts <= now + Self.maxSkewMs, stored[mid] == nil else { throw ProtocolError.staleOrReplayed }
            var seen = stored.filter { !$0.key.isEmpty && $0.value > now - Self.mailWindowMs }
            seen[mid] = ts
            if seen.count > Self.maxSeenMail {
                let ordered = seen.sorted { $0.value < $1.value }
                floor = max(floor, ordered[ordered.count - Self.maxSeenMail - 1].value)
                seen = Dictionary(uniqueKeysWithValues: ordered.suffix(Self.maxSeenMail).map { ($0.key, $0.value) })
            }
            if floor > now - Self.mailWindowMs { seen[""] = floor }
            mailMemory = seen
            mailStore?.set(seen, forKey: mailKey)
        }
    }
}
