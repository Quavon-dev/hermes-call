import CCPace
import Foundation

/// Initiator side of CPace (jedisct1/cpace, compiled from third_party/cpace).
struct CPaceInitiator {
    private var state = crypto_cpace_state()
    let publicData: Data

    init(password: String, idA: String, idB: String, ad: Data) throws {
        try Sodium.ensure()
        let a = idA.utf8.count, b = idB.utf8.count, adBytes = [UInt8](ad)
        guard a <= 255, b <= 255, password.allSatisfy(\.isASCII) else { throw ProtocolError.cryptoFailure }
        var st = crypto_cpace_state()
        var out = [UInt8](repeating: 0, count: Int(crypto_cpace_PUBLICDATABYTES))
        guard crypto_cpace_step1(&st, &out, password, password.utf8.count, idA, UInt8(a), idB, UInt8(b),
                                 adBytes, adBytes.count) == 0
        else { throw ProtocolError.cryptoFailure }
        state = st
        publicData = Data(out)
    }

    mutating func finish(response: Data) throws -> (clientKey: Data, serverKey: Data) {
        guard response.count == Int(crypto_cpace_RESPONSEBYTES) else { throw ProtocolError.cryptoFailure }
        var keys = crypto_cpace_shared_keys()
        let r = [UInt8](response)
        guard crypto_cpace_step3(&state, &keys, r) == 0 else { throw ProtocolError.cryptoFailure }
        let client = withUnsafeBytes(of: keys.client_sk) { Data($0) }
        let server = withUnsafeBytes(of: keys.server_sk) { Data($0) }
        return (client, server)
    }
}
