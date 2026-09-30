import Foundation

/// CPace pairing context. Must match hermescall_common.pairing byte for byte.
struct PairingContext {
    let kind: PairingKind
    let relay: RelayAddress
    let pin: String

    var ids: (String, String) { kind == .relay ? ("bridge", "relay") : ("device", "bridge") }
    var ad: Data { Data("hermescall/v1/\(kind.rawValue)-pair|\(relay.authority)|\(pin)".utf8) }

    static let initiatorAD = Data("hermescall/v1/pair/initiator".utf8)
    static let responderAD = Data("hermescall/v1/pair/responder".utf8)
}

enum PairingSeal {
    static func sealInitiator(_ payload: JSON, key: Data) throws -> Data {
        try Sodium.aeadEncrypt(key: key, plaintext: payload.encoded(), ad: PairingContext.initiatorAD)
    }

    static func openResponder(_ sealed: Data, key: Data) throws -> JSON {
        guard sealed.count <= 4096 + 64 else { throw ProtocolError.cryptoFailure }
        return try JSON.decode(Sodium.aeadDecrypt(key: key, sealed: sealed, ad: PairingContext.responderAD))
    }
}

public enum RelayAuth {
    public static func message(authority: String, role: String, identity: String, nonce: Data) -> Data {
        Data("hermescall/v1/auth|\(authority)|\(role)|\(identity)|".utf8) + nonce
    }
}
