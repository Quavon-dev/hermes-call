// SPDX-License-Identifier: MIT
import Foundation

/// Protocol versions and capabilities exchanged in `auth` / `ready` (docs/protocol.md, "Versions and capabilities").
public enum RelayCaps {
    /// What this app understands: `unsupported` error replies, the mailbox, blobs, Live Activity tokens, `turns:` URLs.
    public static let client = ["unsupported", "mail", "blobs", "live_activity", "turns"]
    static let maxCount = 32

    /// `[a-z0-9_]{1,32}`.
    public static func isValidName(_ name: String) -> Bool {
        (1...32).contains(name.utf8.count) && name.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 }
    }
}

extension RelayAuth {
    /// The protocol version this app speaks.
    public static let protocolVersion = 1

    /// The `auth` frame; `v` and `caps` are not signed and grant nothing, the relay only records them.
    public static func body(role: String, identity: String, signature: String) -> [String: JSON] {
        ["t": "auth", "role": .string(role), "id": .string(identity), "sig": .string(signature),
         "v": .int(Int64(protocolVersion)), "caps": .array(RelayCaps.client.prefix(RelayCaps.maxCount).map { .string($0) })]
    }
}

/// What the relay said about itself in `ready`. Relays up to 0.6.2 send a bare `ready`: no caps at all.
public struct RelayInfo: Sendable, Equatable {
    public let protocolVersion: Int?
    /// The relay's software version, e.g. "0.7.0".
    public let relayVersion: String?
    public let caps: Set<String>

    public init(ready: JSON) {
        protocolVersion = ready["v"]?.int.map { Int(clamping: $0) }
        relayVersion = ready["relay"]?.string.map { String($0.prefix(32)) }
        if case .array(let names)? = ready["caps"] {
            caps = Set(names.prefix(RelayCaps.maxCount).compactMap(\.string).filter(RelayCaps.isValidName))
        } else {
            caps = []
        }
    }

    public func supports(_ cap: String) -> Bool { caps.contains(cap) }

    /// nil when a request needing `cap` may be sent; an old relay would drop the connection on an unknown type.
    public func check(requires cap: String?) -> ProtocolError? {
        guard let cap, !supports(cap) else { return nil }
        return .relay("unsupported")
    }

    /// For Diagnostics.
    public var displayVersion: String { relayVersion ?? "0.6.2 or older" }
}

public enum RelayReply {
    /// The error a reply to a request stands for, nil for a normal reply.
    public static func error(in reply: JSON) -> ProtocolError? {
        guard reply["t"]?.string == "error" else { return nil }
        return .relay(reply["code"]?.string ?? "unknown")
    }
}

extension ProtocolError {
    /// The relay does not know the request type (it stays connected).
    public var isUnsupported: Bool { self == .relay("unsupported") }
}

/// How long to wait before reconnecting to the relay.
public struct RelayBackoff: Sendable {
    /// WebSocket "going away": the relay shuts down (restart, update).
    public static let goingAway = 1001
    public static let maximum: Double = 30
    /// A connection that stayed up this long was healthy: a 1001 after it is a new relay restart.
    public static let stableConnection: TimeInterval = 30

    /// The current base pause (starts at 1 s, doubles up to `maximum`).
    public private(set) var base: Double = 1
    /// 1001 closes in a row without a stable connection between them.
    private var goingAwayStreak = 0

    public init() {}

    /// The connection ended (`connectedFor`: how long it was authenticated; nil: it never got there); returns
    /// the pause before the next try. A relay that went away on purpose is back in seconds, so the first 1001
    /// gets a short random pause (spread, so not every phone arrives at once); a relay that keeps closing
    /// with 1001 (a shutdown loop) gets the growing backoff like any other failure.
    public mutating func pause(closeCode: Int?, connectedFor: TimeInterval?) -> Double {
        if let connectedFor, connectedFor >= Self.stableConnection || closeCode != Self.goingAway { goingAwayStreak = 0 }
        if connectedFor != nil, goingAwayStreak == 0 { base = 1 }
        if closeCode == Self.goingAway {
            goingAwayStreak += 1
            if goingAwayStreak == 1 { return Double.random(in: 0.5...2.5) }
        }
        let pause = base + Double.random(in: 0...(base / 2))
        base = min(base * 2, Self.maximum)
        return pause
    }

    /// `reconnectNow`: the next pause starts at 1 s again.
    public mutating func reset() {
        base = 1
    }
}

/// Blob transfers: a relay busy with other transfers answers HTTP 503 without using up the ticket.
public enum BlobRetry {
    /// Upload and download each must finish within the ticket's lifetime.
    public static let deadline: TimeInterval = 300
    public static let maxUploadAttempts = 6
    /// A download ticket works three times; after that a new one is needed.
    public static let downloadUsesPerTicket = 3
    public static let maxDownloadTickets = 2

    /// Pause before attempt `n` (2, 3, …): 1, 2, 4, 8, 16 s.
    public static func pause(before attempt: Int) -> Duration {
        guard attempt > 1 else { return .zero }
        return .seconds(1 << min(attempt - 2, 4))
    }

    /// Runs `attempt` until it answers 200, retrying 503 up to `maxAttempts` times; other statuses fail at once.
    public static func run(maxAttempts: Int, sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                           _ attempt: () async throws -> (Data, Int)) async throws -> Data {
        for number in 1...max(maxAttempts, 1) {
            if number > 1 { try await sleep(pause(before: number)) }
            let (data, status) = try await attempt()
            switch status {
            case 200, 204: return data
            case 503: continue
            default: throw ProtocolError.unexpected("blob HTTP \(status)")
            }
        }
        throw ProtocolError.relay("busy")
    }
}

/// TURN credentials from the relay's `turn` reply, limited to the relay's own host.
public struct TURNServers: Sendable, Equatable {
    /// `turn:` (UDP, TCP) and `turns:` (TLS, port 5349) URLs, all handed to ICE.
    public let urls: [String]
    public let username: String
    public let credential: String
    /// Seconds the credentials are valid (5400 by default, longer than the longest call).
    public let ttl: Int?

    public init(reply: JSON, relayHost: String) throws {
        guard case .array(let all)? = reply["urls"], let username = reply["username"]?.string,
              let credential = reply["credential"]?.string
        else { throw ProtocolError.unexpected("relay returned no TURN credentials") }
        urls = all.compactMap(\.string).filter { Self.isRelayTURN($0, host: relayHost) }
        guard !urls.isEmpty else { throw ProtocolError.unexpected("relay offered no TURN server on its own host") }
        self.username = username
        self.credential = credential
        ttl = reply["ttl"]?.int.map { Int(clamping: $0) }
    }

    /// Only TURN on the relay's own host: a relay must not route the phone's media (and IP) elsewhere.
    public static func isRelayTURN(_ url: String, host: String) -> Bool {
        let parts = url.split(separator: "?", maxSplits: 1)[0].split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "turn" || parts[0] == "turns" else { return false }
        let rest = String(parts[1])
        let urlHost = rest.hasPrefix("[") ? String(rest.dropFirst().prefix { $0 != "]" }) : String(rest.prefix { $0 != ":" })
        return urlHost.lowercased() == host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
