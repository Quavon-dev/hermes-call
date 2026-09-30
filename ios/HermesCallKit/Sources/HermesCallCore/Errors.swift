public enum ProtocolError: Error, Equatable, Sendable {
    case invalidField
    case invalidCode
    case invalidLink
    case invalidHost
    case invalidPin
    case cryptoFailure
    case pairingFailed
    case pinMismatch
    /// The relay's certificate is not publicly trusted; the user must confirm this key (SPKI pin).
    case selfSignedRelay(String)
    case relay(String)
    case unexpected(String)
    case staleOrReplayed
    case notConnected
    case timeout
}
