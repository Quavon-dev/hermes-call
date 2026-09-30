import Foundation
import Security

/// Relay profiles (including device keys) live only in the Keychain, never in
/// backups or on other devices (…ThisDeviceOnly). "After first unlock" lets an
/// incoming push be authenticated while the phone is locked. The shared access
/// group lets the notification and share extensions read them.
public struct ProfileStore: Sendable {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "de.quavon.hermescall.profiles", accessGroup: String? = SharedContainer.keychainGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private var baseQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "profiles",
         kSecUseDataProtectionKeychain: true]
    }

    private var groupQuery: [CFString: Any] {
        var query = baseQuery
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }

    public func load() throws -> [RelayProfile] {
        var item: CFTypeRef?
        var q = baseQuery
        q[kSecReturnData] = true
        q[kSecReturnAttributes] = true
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let attributes = item as? [CFString: Any],
              let data = attributes[kSecValueData] as? Data else { throw KeychainError(status) }
        let profiles = try JSONDecoder().decode([RelayProfile].self, from: data)
        if let accessGroup, let oldGroup = attributes[kSecAttrAccessGroup] as? String, oldGroup != accessGroup {
            migrate(profiles, from: oldGroup)
        }
        return profiles
    }

    /// Items written before the extensions existed sit in the app's private group: copy them to the
    /// shared group, and only then delete the old copy.
    private func migrate(_ profiles: [RelayProfile], from oldGroup: String) {
        guard let data = try? JSONEncoder().encode(profiles), write(data, to: groupQuery) == errSecSuccess else { return }
        var old = baseQuery
        old[kSecAttrAccessGroup] = oldGroup
        SecItemDelete(old as CFDictionary)
    }

    public func save(_ profiles: [RelayProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        var status = write(data, to: groupQuery)
        if status == errSecMissingEntitlement, accessGroup != nil {
            status = write(data, to: baseQuery)  // unsigned test builds have no access group entitlement
        }
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    private func write(_ data: Data, to query: [CFString: Any]) -> OSStatus {
        let attributes: [CFString: Any] = [
            kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
    }

    public func deleteAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public init(_ status: OSStatus) { self.status = status }
    public var errorDescription: String? { "Keychain error \(status)" }
}
