import Foundation

/// Everything the app knows about one paired relay + bridge. Stored in the Keychain.
public struct RelayProfile: Codable, Sendable, Identifiable, Hashable {
    public static let defaultAgentName = "Hermes"

    public let id: UUID
    public var label: String
    public let relay: RelayAddress
    public let pin: String
    public let deviceID: String
    public let bridgeID: String
    /// Name shown for the agent (from the bridge at pairing, editable in the app).
    public var bridgeName: String
    public let bridgeBoxKey: String
    public let bridgeSignKey: String
    public let keys: DeviceKeys
    public let created: Date
    /// The agent's colour (nil in profiles from before M9: gold).
    public var palette: AgentPalette?

    public init(id: UUID, label: String, relay: RelayAddress, pin: String, deviceID: String, bridgeID: String,
                bridgeName: String, bridgeBoxKey: String, bridgeSignKey: String, keys: DeviceKeys, created: Date,
                palette: AgentPalette? = nil) {
        self.id = id
        self.label = label
        self.relay = relay
        self.pin = pin
        self.deviceID = deviceID
        self.bridgeID = bridgeID
        self.bridgeName = bridgeName
        self.bridgeBoxKey = bridgeBoxKey
        self.bridgeSignKey = bridgeSignKey
        self.keys = keys
        self.created = created
        self.palette = palette
    }
}

public struct DeviceKeys: Codable, Sendable, Hashable {
    public let signPublic: String
    public let signSecret: String
    public let boxPublic: String
    public let boxSecret: String

    public static func generate() throws -> DeviceKeys {
        let sign = try Sodium.signKeypair(), box = try Sodium.boxKeypair()
        return DeviceKeys(signPublic: Base64URL.encode(sign.publicKey), signSecret: Base64URL.encode(sign.secretKey),
                          boxPublic: Base64URL.encode(box.publicKey), boxSecret: Base64URL.encode(box.secretKey))
    }
}

extension RelayProfile {
    public func channel(seenStore: UserDefaults?, mailStore: UserDefaults? = nil) throws -> E2EChannel {
        E2EChannel(myID: deviceID, secretKey: try Base64URL.decode(keys.boxSecret, length: 32), seenStore: seenStore,
                   mailStore: mailStore)
    }
}
