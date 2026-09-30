import Foundation

public struct PairingCode: Sendable, Hashable {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public let slot: String
    public let secret: String

    public var display: String { "\(slot)-\(secret)" }

    /// Accepts "R7K-Q4M9P", lower case, spaces, and the confusables O→0, I/L→1.
    public init(parsing text: String) throws {
        var normalized = ""
        for ch in text.uppercased() where ch != "-" && ch != " " {
            switch ch {
            case "O": normalized.append("0")
            case "I", "L": normalized.append("1")
            default: normalized.append(ch)
            }
        }
        guard (8...29).contains(normalized.count), normalized.allSatisfy(Self.alphabet.contains) else {
            throw ProtocolError.invalidCode
        }
        slot = String(normalized.prefix(3))
        secret = String(normalized.dropFirst(3))
    }
}

public struct RelayAddress: Sendable, Hashable, Codable {
    public let host: String
    public let port: Int

    public var authority: String { port == 443 ? host : "\(host):\(port)" }

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// 1–5 ASCII digits only (no sign or spaces), like the Python parser.
    private static func port(_ text: Substring) -> Int? {
        guard (1...5).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// host, host:port, IPv4, or [IPv6](:port). Mirrors hermescall_common.codes.parse_authority.
    public init(parsing text: String) throws {
        let value = text.trimmingCharacters(in: .whitespaces)
        var host = value, port = 443
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { throw ProtocolError.invalidHost }
            host = String(value[...close]).lowercased()
            let rest = value[value.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let p = Self.port(rest.dropFirst()) else { throw ProtocolError.invalidHost }
                port = p
            }
            let inner = host.dropFirst().dropLast()
            guard !inner.isEmpty, inner.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { throw ProtocolError.invalidHost }
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw ProtocolError.invalidHost }
            host = String(parts[0])
            if parts.count == 2 {
                guard let p = Self.port(parts[1]) else { throw ProtocolError.invalidHost }
                port = p
            }
            host = host.lowercased()
            if host.hasSuffix(".") { host.removeLast() }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.count <= 253, !labels.isEmpty, labels.allSatisfy(Self.validLabel) else { throw ProtocolError.invalidHost }
        }
        guard (1...65535).contains(port) else { throw ProtocolError.invalidHost }
        self.host = host
        self.port = port
    }

    private static func validLabel(_ label: Substring) -> Bool {
        (1...63).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
            && label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }
}

public enum PairingKind: String, Sendable { case relay, device }

public struct PairingInvite: Sendable, Hashable {
    public let kind: PairingKind
    public let relay: RelayAddress
    public let pin: String
    public let code: PairingCode

    public init(kind: PairingKind, relay: RelayAddress, pin: String, code: PairingCode) {
        self.kind = kind
        self.relay = relay
        self.pin = pin
        self.code = code
    }

    /// hermescall://pair?v=1&k=device&r=<authority>&c=<slot+secret>[&pin=<spki>]
    public init(link: String) throws {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "hermescall", components.host == "pair",
              let items = components.queryItems
        else { throw ProtocolError.invalidLink }
        var query: [String: String] = [:]
        for item in items {
            guard query[item.name] == nil, let value = item.value else { throw ProtocolError.invalidLink }
            query[item.name] = value
        }
        guard query["v"] == "1", let kind = query["k"].flatMap(PairingKind.init(rawValue:)) else { throw ProtocolError.invalidLink }
        let pin = query["pin"] ?? ""
        guard pin.isEmpty || (pin.count == 43 && (try? Base64URL.decode(pin, length: 32)) != nil) else { throw ProtocolError.invalidPin }
        self.init(kind: kind, relay: try RelayAddress(parsing: query["r"] ?? ""), pin: pin,
                  code: try PairingCode(parsing: query["c"] ?? ""))
    }
}
