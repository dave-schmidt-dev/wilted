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
    /// Whether a saved key is present, without reading its value.
    func savedKeyPresent() -> Bool
}

public extension LabellerKeyStoring {
    func savedKeyPresent() -> Bool { hasKey() }
}

/// A key store for tests and previews: lives and dies with the process.
public final class InMemoryLabellerKeyStore: LabellerKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]
    public let provider: AdLabellerProvider

    public init(key: String? = nil, provider: AdLabellerProvider = .opencodeGoKey) {
        self.provider = provider
        if let key {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.keys[Self.account(for: provider)] = trimmed
            }
        }
    }

    public init(keys: [AdLabellerProvider: String], provider: AdLabellerProvider = .opencodeGoKey) {
        self.provider = provider
        for (p, k) in keys {
            let trimmed = k.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.keys[Self.account(for: p)] = trimmed
            }
        }
    }

    public static func account(for provider: AdLabellerProvider) -> String {
        KeychainLabellerKeyStore.account(for: provider)
    }

    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LabellerKeyStoreError.emptyKey }
        lock.withLock { self.keys[Self.account(for: provider)] = trimmed }
    }

    public func read() throws -> String? {
        lock.withLock { keys[Self.account(for: provider)] }
    }

    public func remove() throws {
        lock.withLock { _ = keys.removeValue(forKey: Self.account(for: provider)) }
    }

    public func hasKey() -> Bool {
        lock.withLock { keys[Self.account(for: provider)] != nil }
    }

    /// Whether a key is stored for `targetProvider`.
    public func savedKeyPresent(for targetProvider: AdLabellerProvider) -> Bool {
        lock.withLock { keys[Self.account(for: targetProvider)] != nil }
    }
}

/// The Keychain-backed store: one generic-password item per provider, readable after
/// the first unlock, bound to this device, and never synchronizable (so it cannot reach
/// iCloud Keychain).
public struct KeychainLabellerKeyStore: LabellerKeyStoring {
    public static let defaultService = "com.zerodelta.wilted.ad-labeller"
    public static let defaultAccount = "ad-labeller-api-key"
    public static let account = defaultAccount

    public let provider: AdLabellerProvider
    public let account: String
    private let service: String

    public init(
        provider: AdLabellerProvider = .opencodeGoKey,
        service: String = KeychainLabellerKeyStore.defaultService
    ) {
        self.provider = provider
        self.service = service
        self.account = Self.account(for: provider)
    }

    /// Identifies the Keychain account name for a provider.
    ///
    /// The existing OpenCode Go key keeps working at its current slot ("ad-labeller-api-key")
    /// with no migration; other providers include the provider's raw value.
    public static func account(for provider: AdLabellerProvider) -> String {
        switch provider {
        case .opencodeGoKey:
            return defaultAccount
        default:
            return "\(defaultAccount)-\(provider.rawValue)"
        }
    }

    // MARK: Queries (separate so tests can assert the attributes without the Keychain)

    /// Identifies the item. `kSecUseDataProtectionKeychain` makes macOS honour the
    /// accessibility class the way iOS does; the legacy file keychain ignores it.
    public static func baseQuery(service: String, account: String = defaultAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// The attributes a new item is stored with.
    public static func addQuery(service: String, account: String = defaultAccount, keyData: Data) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    public static func readQuery(service: String, account: String = defaultAccount) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
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
            Self.baseQuery(service: service, account: account) as CFDictionary,
            [kSecValueData as String: keyData] as CFDictionary)
        switch update {
        case errSecSuccess: return
        case errSecItemNotFound: break
        default: throw LabellerKeyStoreError.keychain(update)
        }
        let add = SecItemAdd(Self.addQuery(service: service, account: account, keyData: keyData) as CFDictionary, nil)
        if add == errSecDuplicateItem {
            // Another process stored a key between the update and the add; replace it.
            let retry = SecItemUpdate(
                Self.baseQuery(service: service, account: account) as CFDictionary,
                [kSecValueData as String: keyData] as CFDictionary)
            guard retry == errSecSuccess else { throw LabellerKeyStoreError.keychain(retry) }
            return
        }
        guard add == errSecSuccess else { throw LabellerKeyStoreError.keychain(add) }
    }

    public func read() throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.readQuery(service: service, account: account) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LabellerKeyStoreError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func remove() throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LabellerKeyStoreError.keychain(status)
        }
    }

    public func hasKey() -> Bool {
        SecItemCopyMatching(Self.baseQuery(service: service, account: account) as CFDictionary, nil) == errSecSuccess
    }

    /// Whether a saved key is present for `provider`. Pure style query without reading the key.
    public static func savedKeyPresent(
        for provider: AdLabellerProvider,
        service: String = defaultService
    ) -> Bool {
        KeychainLabellerKeyStore(provider: provider, service: service).hasKey()
    }

    /// Whether a saved key is present for `provider`. Pure style query without reading the key.
    public func savedKeyPresent(for provider: AdLabellerProvider) -> Bool {
        Self.savedKeyPresent(for: provider, service: service)
    }
}

/// Pure functions for inspecting saved key presence across providers.
public enum LabellerKeyPresence {
    /// Pure check for whether a saved key is present given an in-memory dictionary of keys.
    public static func savedKeyPresent(
        for provider: AdLabellerProvider,
        in keys: [AdLabellerProvider: String]
    ) -> Bool {
        guard let key = keys[provider], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    /// Pure check for whether a saved key is present given a provider lookup closure.
    public static func savedKeyPresent(
        for provider: AdLabellerProvider,
        hasKey: (AdLabellerProvider) -> Bool
    ) -> Bool {
        hasKey(provider)
    }
}
