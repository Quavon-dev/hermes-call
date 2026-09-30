import Foundation

/// Encrypted attachments (hermescall_common.blobs): sealed with a random key that travels only
/// inside the E2E message; the relay stores opaque bytes.
public enum Blob {
    public static let maxPlaintext = 10 * 1024 * 1024
    public static let maxSealedSize = maxPlaintext + 64
    static let ad = Data("hermescall/v1/blob".utf8)

    /// Returns the key and `nonce || ciphertext`.
    public static func seal(_ data: Data) throws -> (key: Data, sealed: Data) {
        guard data.count <= maxPlaintext else { throw ProtocolError.invalidField }
        let key = Sodium.randomBytes(32)
        return (key, try Sodium.aeadEncrypt(key: key, plaintext: data, ad: ad))
    }

    public static func open(_ sealed: Data, key: Data) throws -> Data {
        try Sodium.aeadDecrypt(key: key, sealed: sealed, ad: ad)
    }
}
