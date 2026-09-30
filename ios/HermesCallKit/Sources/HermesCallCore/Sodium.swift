import Clibsodium
import Foundation

/// Thin wrappers over libsodium; the same primitives the Python bridge uses.
public enum Sodium {
    private static let ready: Bool = sodium_init() >= 0

    static func ensure() throws {
        guard ready else { throw ProtocolError.cryptoFailure }
    }

    public static func randomBytes(_ count: Int) -> Data {
        _ = ready
        var out = [UInt8](repeating: 0, count: count)
        randombytes_buf(&out, count)
        return Data(out)
    }

    public static func aeadEncrypt(key: Data, plaintext: Data, ad: Data) throws -> Data {
        try ensure()
        guard key.count == 32 else { throw ProtocolError.cryptoFailure }
        let nonce = [UInt8](randomBytes(24)), m = [UInt8](plaintext), a = [UInt8](ad), k = [UInt8](key)
        var out = [UInt8](repeating: 0, count: m.count + 16)
        var outLen: UInt64 = 0
        guard crypto_aead_xchacha20poly1305_ietf_encrypt(
            &out, &outLen, m, UInt64(m.count), a, UInt64(a.count), nil, nonce, k) == 0
        else { throw ProtocolError.cryptoFailure }
        return Data(nonce + out.prefix(Int(outLen)))
    }

    public static func aeadDecrypt(key: Data, sealed: Data, ad: Data) throws -> Data {
        try ensure()
        let s = [UInt8](sealed), a = [UInt8](ad), k = [UInt8](key)
        guard k.count == 32, s.count >= 24 + 16 else { throw ProtocolError.cryptoFailure }
        let nonce = Array(s[..<24]), ct = Array(s[24...])
        var out = [UInt8](repeating: 0, count: ct.count)
        var outLen: UInt64 = 0
        guard crypto_aead_xchacha20poly1305_ietf_decrypt(
            &out, &outLen, nil, ct, UInt64(ct.count), a, UInt64(a.count), nonce, k) == 0
        else { throw ProtocolError.cryptoFailure }
        return Data(out.prefix(Int(outLen)))
    }

    public static func signKeypair() throws -> (publicKey: Data, secretKey: Data) {
        try ensure()
        var pk = [UInt8](repeating: 0, count: 32), sk = [UInt8](repeating: 0, count: 64)
        guard crypto_sign_ed25519_keypair(&pk, &sk) == 0 else { throw ProtocolError.cryptoFailure }
        return (Data(pk), Data(sk))
    }

    public static func sign(_ message: Data, secretKey: Data) throws -> Data {
        try ensure()
        let m = [UInt8](message), k = [UInt8](secretKey)
        guard k.count == 64 else { throw ProtocolError.cryptoFailure }
        var sig = [UInt8](repeating: 0, count: 64)
        guard crypto_sign_ed25519_detached(&sig, nil, m, UInt64(m.count), k) == 0 else { throw ProtocolError.cryptoFailure }
        return Data(sig)
    }

    public static func verify(_ signature: Data, message: Data, publicKey: Data) -> Bool {
        let s = [UInt8](signature), m = [UInt8](message), k = [UInt8](publicKey)
        guard ready, s.count == 64, k.count == 32 else { return false }
        return crypto_sign_ed25519_verify_detached(s, m, UInt64(m.count), k) == 0
    }

    public static func boxKeypair() throws -> (publicKey: Data, secretKey: Data) {
        try ensure()
        var pk = [UInt8](repeating: 0, count: 32), sk = [UInt8](repeating: 0, count: 32)
        guard crypto_box_keypair(&pk, &sk) == 0 else { throw ProtocolError.cryptoFailure }
        return (Data(pk), Data(sk))
    }

    public static func boxSeal(_ plaintext: Data, to publicKey: Data, from secretKey: Data) throws -> Data {
        try ensure()
        let m = [UInt8](plaintext), pk = [UInt8](publicKey), sk = [UInt8](secretKey)
        guard pk.count == 32, sk.count == 32 else { throw ProtocolError.cryptoFailure }
        let nonce = [UInt8](randomBytes(24))
        var out = [UInt8](repeating: 0, count: m.count + 16)
        guard crypto_box_easy(&out, m, UInt64(m.count), nonce, pk, sk) == 0 else { throw ProtocolError.cryptoFailure }
        return Data(nonce + out)
    }

    public static func boxOpen(_ sealed: Data, from publicKey: Data, to secretKey: Data) throws -> Data {
        try ensure()
        let s = [UInt8](sealed), pk = [UInt8](publicKey), sk = [UInt8](secretKey)
        guard pk.count == 32, sk.count == 32, s.count >= 24 + 16 else { throw ProtocolError.cryptoFailure }
        let nonce = Array(s[..<24]), ct = Array(s[24...])
        var out = [UInt8](repeating: 0, count: ct.count - 16)
        guard crypto_box_open_easy(&out, ct, UInt64(ct.count), nonce, pk, sk) == 0 else { throw ProtocolError.cryptoFailure }
        return Data(out)
    }
}
