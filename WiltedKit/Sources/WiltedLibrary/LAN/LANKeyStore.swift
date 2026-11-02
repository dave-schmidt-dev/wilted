import Foundation
import OSLog
import Security

private let keyLog = Logger(subsystem: "com.zerodelta.wilted", category: "LAN")

/// Holds this install's LAN key-agreement private key. The key never leaves the device and is never logged.
public protocol LANKeyStore: Sendable {
    /// The stored key, created and stored on first use.
    func currentKey() throws -> LANKeyAgreementKey
    /// Replaces the key with a new one and returns it. The old key stops working at once.
    func rotate() throws -> LANKeyAgreementKey
    /// Removes the key; the next `currentKey()` creates a fresh one. Deleting nothing is not an error.
    func delete() throws
}

/// A key store for tests and previews: lives and dies with the process.
public final class InMemoryLANKeyStore: LANKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: LANKeyAgreementKey?

    public init(key: LANKeyAgreementKey? = nil) { self.key = key }

    public func currentKey() throws -> LANKeyAgreementKey {
        lock.withLock {
            if let key { return key }
            let created = LANKeyAgreementKey()
            key = created
            return created
        }
    }

    public func rotate() throws -> LANKeyAgreementKey {
        lock.withLock {
            let created = LANKeyAgreementKey()
            key = created
            return created
        }
    }

    public func delete() throws { lock.withLock { key = nil } }
}

/// The Keychain-backed store: one generic-password item holding the raw private scalar, readable after the
/// first unlock, bound to this device, and never synchronizable (so it cannot reach iCloud Keychain).
public final class KeychainLANKeyStore: LANKeyStore, @unchecked Sendable, CustomStringConvertible {
    public static let defaultService = "com.zerodelta.wilted.lan"
    static let account = "key-agreement-p256"

    private let service: String
    private let lock = NSLock()

    public init(service: String = KeychainLANKeyStore.defaultService) { self.service = service }

    public var description: String { "KeychainLANKeyStore(\(service))" }

    // MARK: Queries (separate so tests can assert the attributes without the Keychain)

    /// Identifies the item. `kSecUseDataProtectionKeychain` makes macOS honour the accessibility class
    /// the way iOS does; the legacy file keychain ignores it.
    static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// The attributes a new item is stored with.
    static func addQuery(service: String, keyData: Data) -> [String: Any] {
        var query = baseQuery(service: service)
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    static func readQuery(service: String) -> [String: Any] {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    // MARK: LANKeyStore

    public func currentKey() throws -> LANKeyAgreementKey {
        try lock.withLock {
            if let existing = try read() { return existing }
            let created = LANKeyAgreementKey()
            do {
                try add(created)
            } catch LANKeyError.keychain(errSecDuplicateItem) {
                // Another process stored one between the read and the add; use that key.
                if let existing = try read() { return existing }
                throw LANKeyError.keychain(errSecDuplicateItem)
            }
            keyLog.notice("Created this device's LAN key.")
            return created
        }
    }

    public func rotate() throws -> LANKeyAgreementKey {
        try lock.withLock {
            let created = LANKeyAgreementKey()
            let status = SecItemUpdate(
                Self.baseQuery(service: service) as CFDictionary,
                [kSecValueData as String: created.rawRepresentation] as CFDictionary)
            switch status {
            case errSecSuccess: break
            case errSecItemNotFound: try add(created)
            default: throw LANKeyError.keychain(status)
            }
            keyLog.notice("Rotated this device's LAN key.")
            return created
        }
    }

    public func delete() throws {
        try lock.withLock {
            let status = SecItemDelete(Self.baseQuery(service: service) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw LANKeyError.keychain(status) }
        }
    }

    private func read() throws -> LANKeyAgreementKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.readQuery(service: service) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LANKeyError.keychain(status) }
        return try LANKeyAgreementKey(rawRepresentation: data)
    }

    private func add(_ key: LANKeyAgreementKey) throws {
        let status = SecItemAdd(Self.addQuery(service: service, keyData: key.rawRepresentation) as CFDictionary, nil)
        guard status == errSecSuccess else { throw LANKeyError.keychain(status) }
    }
}
