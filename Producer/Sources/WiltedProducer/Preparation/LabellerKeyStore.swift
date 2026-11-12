import Foundation
import Security

/// Why a key-store operation failed. Carries only the `OSStatus`; never the key.
public enum LabellerKeyStoreError: Error, Equatable, Sendable {
    /// `save` was given a key that is empty once trimmed.
    case emptyKey
    /// A Keychain call failed; the payload is the raw `OSStatus`.
    case keychain(OSStatus)
}

/// Stores the ad-labeller provider key. The key leaves the store only to build the
/// request's Authorization header; it is never logged and never described.
public protocol LabellerKeyStoring: Sendable {
    /// Stores `key`, replacing any key already stored.
    func save(_ key: String) throws
    /// The stored key, or nil when none is stored.
    func read() throws -> String?
    /// Removes the stored key. Removing nothing is not an error.
    func remove() throws
    /// Whether a key is stored, without reading its value.
    func hasKey() -> Bool
}

/// A key store for tests and previews: lives and dies with the process.
public final class InMemoryLabellerKeyStore: LabellerKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) { self.key = key }

    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LabellerKeyStoreError.emptyKey }
        lock.withLock { self.key = trimmed }
    }

    public func read() throws -> String? { lock.withLock { key } }

    public func remove() throws { lock.withLock { key = nil } }

    public func hasKey() -> Bool { lock.withLock { key != nil } }
}

/// The Keychain-backed store: one generic-password item, readable after the first
/// unlock, bound to this device, and never synchronizable (so it cannot reach
/// iCloud Keychain).
public struct KeychainLabellerKeyStore: LabellerKeyStoring {
    public static let defaultService = "com.zerodelta.wilted.ad-labeller"
    static let account = "ad-labeller-api-key"

    private let service: String

    public init(service: String = KeychainLabellerKeyStore.defaultService) { self.service = service }

    // MARK: Queries (separate so tests can assert the attributes without the Keychain)

    /// Identifies the item. `kSecUseDataProtectionKeychain` makes macOS honour the
    /// accessibility class the way iOS does; the legacy file keychain ignores it.
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

    // MARK: LabellerKeyStoring

    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let keyData = trimmed.data(using: .utf8) else {
            throw LabellerKeyStoreError.emptyKey
        }
        let update = SecItemUpdate(
            Self.baseQuery(service: service) as CFDictionary,
            [kSecValueData as String: keyData] as CFDictionary)
        switch update {
        case errSecSuccess: return
        case errSecItemNotFound: break
        default: throw LabellerKeyStoreError.keychain(update)
        }
        let add = SecItemAdd(Self.addQuery(service: service, keyData: keyData) as CFDictionary, nil)
        if add == errSecDuplicateItem {
            // Another process stored a key between the update and the add; replace it.
            let retry = SecItemUpdate(
                Self.baseQuery(service: service) as CFDictionary,
                [kSecValueData as String: keyData] as CFDictionary)
            guard retry == errSecSuccess else { throw LabellerKeyStoreError.keychain(retry) }
            return
        }
        guard add == errSecSuccess else { throw LabellerKeyStoreError.keychain(add) }
    }

    public func read() throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.readQuery(service: service) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LabellerKeyStoreError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func remove() throws {
        let status = SecItemDelete(Self.baseQuery(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LabellerKeyStoreError.keychain(status)
        }
    }

    public func hasKey() -> Bool {
        SecItemCopyMatching(Self.baseQuery(service: service) as CFDictionary, nil) == errSecSuccess
    }
}
