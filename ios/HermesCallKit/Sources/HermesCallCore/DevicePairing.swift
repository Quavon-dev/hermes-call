import Foundation

public enum DevicePairing {
    /// Pairs this phone with a bridge through its relay. The relay only forwards the
    /// CPace messages; a wrong code or a TLS man-in-the-middle makes key agreement fail.
    /// A self-signed relay without a pin in the invite throws `selfSignedRelay(pin)`: the
    /// app asks the user, then retries with that pin, never trusting it silently.
    public static func pair(invite: PairingInvite, deviceName: String) async throws -> RelayProfile {
        guard invite.kind == .device else { throw ProtocolError.invalidLink }
        let keys = try DeviceKeys.generate()
        let trust = RelayTrust(invite.pin.isEmpty ? .firstContact : .pinned(invite.pin))
        let socket = try RelaySocket(relay: invite.relay, path: "/v1/pair", trust: trust)
        defer { socket.close() }
        do {
            try await socket.waitConnected()
        } catch {
            if let observed = trust.observedPin, !observed.isEmpty { throw ProtocolError.selfSignedRelay(observed) }
            throw error
        }
        let pin = invite.pin

        let context = PairingContext(kind: .device, relay: invite.relay, pin: pin)
        var cpace = try CPaceInitiator(password: invite.code.secret, idA: context.ids.0, idB: context.ids.1, ad: context.ad)
        try await socket.send([
            "t": "join", "slot": .string(invite.code.slot), "msg": .string(Base64URL.encode(cpace.publicData)),
        ])
        let response = try await socket.expect("pair_msg", timeout: 60)
        let sessionKeys = try cpace.finish(response: try Base64URL.decode(response["data"]?.string ?? "", length: 32))
        let payload: JSON = [
            "sign_pk": .string(keys.signPublic), "box_pk": .string(keys.boxPublic),
            "name": .string(String(deviceName.prefix(64))),
        ]
        let confirm = try PairingSeal.sealInitiator(payload, key: sessionKeys.clientKey)
        try await socket.send(["t": "pair_msg", "data": .string(Base64URL.encode(confirm))])

        let final = try await socket.expect("pair_final", timeout: 60)
        let result: JSON
        do {
            result = try PairingSeal.openResponder(try Base64URL.decode(final["data"]?.string ?? "", maxLength: 4096),
                                                   key: sessionKeys.serverKey)
        } catch {
            throw ProtocolError.pairingFailed
        }
        return try profile(from: result, relayDeviceID: final["device_id"]?.string, invite: invite, pin: pin, keys: keys)
    }

    static func profile(from result: JSON, relayDeviceID: String?, invite: PairingInvite, pin: String,
                        keys: DeviceKeys) throws -> RelayProfile {
        guard let deviceID = result["device_id"]?.string, deviceID == relayDeviceID,
              let bridgeID = result["bridge_id"]?.string,
              let boxKey = result["bridge_box_pk"]?.string, (try? Base64URL.decode(boxKey, length: 32)) != nil,
              let signKey = result["bridge_sign_pk"]?.string, (try? Base64URL.decode(signKey, length: 32)) != nil,
              let relay = result["relay"], relay["host"]?.string == invite.relay.host,
              relay["port"]?.int == Int64(invite.relay.port), relay["pin"]?.string == pin
        else { throw ProtocolError.pairingFailed }
        let name = String((result["bridge_name"]?.string ?? RelayProfile.defaultAgentName).prefix(32))
        return RelayProfile(id: UUID(), label: invite.relay.host, relay: invite.relay, pin: pin, deviceID: deviceID,
                            bridgeID: bridgeID, bridgeName: name.isEmpty ? RelayProfile.defaultAgentName : name, bridgeBoxKey: boxKey,
                            bridgeSignKey: signKey, keys: keys, created: Date())
    }
}
