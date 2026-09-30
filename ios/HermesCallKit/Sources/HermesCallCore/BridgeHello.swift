// SPDX-License-Identifier: MIT
import Foundation

/// The E2E `hello` between this app and a bridge (docs/protocol.md, "App ↔ bridge versions"): sent after
/// every relay connect; the bridge answers with its version and caps. Bridges that do not know `hello`
/// answer nothing (or `unsupported`): the app then uses none of the optional features.
public enum AppHello {
    public static let protocolVersion = 1
    /// What this app understands beyond protocol v1.
    public static let caps = ["unsupported"]
    /// Types the app never answers with `unsupported` (no loops, and `hello` is handled by the session).
    static let neverAnswered: Set<String> = ["unsupported", "hello"]

    public static func body(appVersion: String, caps: [String] = caps) -> [String: JSON] {
        ["type": "hello", "v": .int(Int64(protocolVersion)), "app": .string(String(appVersion.prefix(40))),
         "caps": .array(caps.prefix(RelayCaps.maxCount).map { .string($0) })]
    }

    /// The answer to an E2E message this app does not know, or nil (no type, or one never answered).
    /// The unknown name is echoed only when it is a valid type name.
    public static func unsupportedReply(to message: [String: JSON]) -> [String: JSON]? {
        guard let type = message["type"]?.string, !neverAnswered.contains(type) else { return nil }
        var reply: [String: JSON] = ["type": "unsupported"]
        if RelayCaps.isValidName(type) { reply["unknown"] = .string(type) }
        return reply
    }
}

/// What a bridge said about itself in its `hello`.
public struct BridgeInfo: Sendable, Equatable {
    public let protocolVersion: Int
    /// The bridge's software version, e.g. "0.7.0".
    public let bridgeVersion: String?
    public let caps: Set<String>

    public init?(hello body: [String: JSON]) {
        guard body["type"]?.string == "hello" else { return nil }
        protocolVersion = body["v"]?.int.map { Int(clamping: $0) } ?? 1
        bridgeVersion = body["bridge"]?.string.map { String($0.prefix(32)) }
        if case .array(let names)? = body["caps"] {
            caps = Set(names.prefix(RelayCaps.maxCount).compactMap(\.string).filter(RelayCaps.isValidName))
        } else {
            caps = []
        }
    }

    public func supports(_ cap: String) -> Bool { caps.contains(cap) }

    /// For Diagnostics.
    public var displayVersion: String { bridgeVersion ?? "Unknown" }
}
