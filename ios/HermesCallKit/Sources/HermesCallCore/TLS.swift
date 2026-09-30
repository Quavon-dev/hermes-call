import CryptoKit
import Foundation
import Security

/// SPKI SHA-256 pin, identical to hermescall_common.tls.spki_pin (base64url, no padding).
public enum TLSPin {
    private static let p256Prefix: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]
    private static let p384Prefix: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
    ]

    public static func pin(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == (kSecAttrKeyTypeECSECPrimeRandom as String)
        else { return nil }
        let prefix: [UInt8]
        switch raw.count {
        case 65: prefix = p256Prefix
        case 97: prefix = p384Prefix
        default: return nil
        }
        return Base64URL.encode(Data(SHA256.hash(data: Data(prefix) + raw)))
    }
}

/// Server-trust policy for one connection to a relay.
final class RelayTrust: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// `firstContact`: WebPKI only, but records the key of a self-signed relay so the user can confirm it.
    enum Mode { case pinned(String), webPKI, firstContact }

    private let mode: Mode
    private let lock = NSLock()
    private var observed: String?
    private var mismatched = false
    private var openState: Result<Void, Error>?
    private var openWaiters: [CheckedContinuation<Void, Error>] = []

    init(_ mode: Mode) { self.mode = mode }

    func waitOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let state: Result<Void, Error>? = lock.withLock {
                if openState == nil { openWaiters.append(continuation) }
                return openState
            }
            if let state { continuation.resume(with: state) }
        }
    }

    private func finishOpen(_ result: Result<Void, Error>) {
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            guard openState == nil else { return [] }
            openState = result
            defer { openWaiters.removeAll() }
            return openWaiters
        }
        waiters.forEach { $0.resume(with: result) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finishOpen(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finishOpen(.failure(Self.openError(status: (task.response as? HTTPURLResponse)?.statusCode,
                                           pinMismatch: lock.withLock { mismatched }, error: error)))
    }

    /// What a failed WebSocket upgrade means: the relay's rate limit (429) and connection cap (503) answer
    /// with plain HTTP; a pinned key that did not match cancels the TLS handshake.
    static func openError(status: Int?, pinMismatch: Bool, error: Error?) -> Error {
        if pinMismatch { return ProtocolError.pinMismatch }
        switch status {
        case 429: return ProtocolError.relay("rate_limited")
        case 503: return ProtocolError.relay("busy")
        default: return error ?? ProtocolError.notConnected
        }
    }

    /// "" for a WebPKI-valid relay, the SPKI pin of a (rejected) self-signed one.
    var observedPin: String? { lock.withLock { observed } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        switch mode {
        case .webPKI:
            return (.performDefaultHandling, nil)
        case .pinned(let expected):
            guard TLSPin.pin(of: trust) == expected else {
                lock.withLock { mismatched = true }
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        case .firstContact:
            if SecTrustEvaluateWithError(trust, nil) {
                lock.withLock { observed = "" }
                return (.performDefaultHandling, nil)
            }
            if let pin = TLSPin.pin(of: trust) { lock.withLock { observed = pin } }
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}
