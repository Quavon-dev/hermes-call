import Foundation

/// Why pairing did not work, in terms the owner can act on (the app words each case).
public enum PairingFailure: Equatable, Sendable {
    /// The address, code or link is malformed.
    case invalidInput
    /// No connection to the relay (wrong address, offline, relay down).
    case unreachable
    /// The relay's TLS key is not the one in the pairing link (or its certificate is invalid).
    case tlsMismatch
    /// The relay refuses more attempts from this network for a while (HTTP 429).
    case rateLimited
    /// The relay is at its connection limit (HTTP 503).
    case relayBusy
    /// The bridge already has as many phones as its relay allows (`too_many_devices`).
    case tooManyDevices
    /// The code is wrong, already used or expired (key agreement failed).
    case wrongOrExpiredCode
    case other

    public static func classify(_ error: Error) -> PairingFailure {
        if let error = error as? ProtocolError { return classify(error) }
        if let error = error as? URLError { return classify(error) }
        return .other
    }

    private static func classify(_ error: ProtocolError) -> PairingFailure {
        switch error {
        case .invalidField, .invalidCode, .invalidLink, .invalidHost, .invalidPin: .invalidInput
        case .pinMismatch, .selfSignedRelay: .tlsMismatch
        case .pairingFailed, .cryptoFailure, .staleOrReplayed: .wrongOrExpiredCode
        case .timeout, .notConnected: .unreachable
        case .relay(let code):
            switch code {
            case "rate_limited": .rateLimited
            case "busy": .relayBusy
            case "too_many_devices": .tooManyDevices
            case "pairing_failed", "protocol_error": .wrongOrExpiredCode
            default: .other
            }
        case .unexpected: .other
        }
    }

    private static func classify(_ error: URLError) -> PairingFailure {
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed:
            .tlsMismatch
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .notConnectedToInternet,
             .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed, .cannotLoadFromNetwork:
            .unreachable
        default:
            .other
        }
    }
}
