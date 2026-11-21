import Foundation

/// Thread-safe wrapper for UserDefaults for direct download preferences.
final class WiltedMacLANPreferences: @unchecked Sendable {
    static let stoppedPhonesKey = "wilted.mac.directDownloadsStoppedPhones"
    static let ownerFingerprintKey = "wilted.mac.directDownloadsOwnerFingerprint"
    static let deviceDisplayNamesKey = "wilted.mac.linkedDeviceDisplayNames"
    static let deviceRemovalDatesKey = "wilted.mac.linkedDeviceRemovalDates"
    static let deviceAnnouncementDatesKey = "wilted.mac.linkedDeviceAnnouncementDates"

    private let defaults: UserDefaults
    private static let preferencesLock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isDirectDownloadsEnabled: Bool {
        defaults.object(forKey: WiltedMacLANMediaServer.directDownloadsEnabledKey) as? Bool ?? true
    }

    func setDirectDownloadsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: WiltedMacLANMediaServer.directDownloadsEnabledKey)
    }

    /// Phones denied direct downloads. Removed-device IDs remain here through owner-key rotation.
    var stoppedPhones: Set<String> {
        get { Self.preferencesLock.withLock { storedStoppedPhones() } }
        set { Self.preferencesLock.withLock { storeStoppedPhones(newValue) } }
    }

    /// Adds one stopped device without overwriting another concurrent device's preference change.
    func insertStoppedPhone(_ deviceID: String) {
        Self.preferencesLock.withLock {
            var stopped = storedStoppedPhones()
            guard stopped.insert(deviceID).inserted else { return }
            storeStoppedPhones(stopped)
        }
    }

    /// Clears ordinary stops when the owner key rotates but retains every removed device tombstone.
    func replaceStoppedPhonesKeepingRemovalTombstones(_ deviceIDs: Set<String>) {
        Self.preferencesLock.withLock {
            let removed = Set(storedDates(forKey: Self.deviceRemovalDatesKey).keys)
            storeStoppedPhones(deviceIDs.union(removed))
        }
    }

    /// Local labels for linked devices. Names stay on this Mac and never enter the directory.
    var deviceDisplayNames: [String: String] {
        get { Self.preferencesLock.withLock { storedDisplayNames() } }
        set { Self.preferencesLock.withLock { defaults.set(newValue, forKey: Self.deviceDisplayNamesKey) } }
    }

    func setDeviceDisplayName(_ name: String?, for deviceID: String) {
        Self.preferencesLock.withLock {
            var names = storedDisplayNames()
            if let name { names[deviceID] = name } else { names.removeValue(forKey: deviceID) }
            defaults.set(names, forKey: Self.deviceDisplayNamesKey)
        }
    }

    /// Removal cutoffs and latest announcements use epoch seconds for property-list persistence.
    var deviceRemovalDates: [String: Date] {
        get { Self.preferencesLock.withLock { storedDates(forKey: Self.deviceRemovalDatesKey) } }
        set { Self.preferencesLock.withLock { storeDates(newValue, forKey: Self.deviceRemovalDatesKey) } }
    }

    func setDeviceRemovalDate(_ date: Date?, for deviceID: String) {
        Self.preferencesLock.withLock {
            var dates = storedDates(forKey: Self.deviceRemovalDatesKey)
            if let date { dates[deviceID] = date } else { dates.removeValue(forKey: deviceID) }
            storeDates(dates, forKey: Self.deviceRemovalDatesKey)
        }
    }

    var deviceAnnouncementDates: [String: Date] {
        get { Self.preferencesLock.withLock { storedDates(forKey: Self.deviceAnnouncementDatesKey) } }
        set { Self.preferencesLock.withLock { storeDates(newValue, forKey: Self.deviceAnnouncementDatesKey) } }
    }

    func setDeviceAnnouncementDate(_ date: Date?, for deviceID: String) {
        Self.preferencesLock.withLock {
            var dates = storedDates(forKey: Self.deviceAnnouncementDatesKey)
            if let date { dates[deviceID] = date } else { dates.removeValue(forKey: deviceID) }
            storeDates(dates, forKey: Self.deviceAnnouncementDatesKey)
        }
    }

    /// A one-way fingerprint of the owner the current key was used for, so an account change rotates it.
    var ownerFingerprint: String? {
        get { defaults.string(forKey: Self.ownerFingerprintKey) }
        set { defaults.set(newValue, forKey: Self.ownerFingerprintKey) }
    }

    private func storedStoppedPhones() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.stoppedPhonesKey) ?? [])
    }

    private func storeStoppedPhones(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: Self.stoppedPhonesKey)
    }

    private func storedDisplayNames() -> [String: String] {
        defaults.dictionary(forKey: Self.deviceDisplayNamesKey) as? [String: String] ?? [:]
    }

    private func storedDates(forKey key: String) -> [String: Date] {
        let seconds = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return seconds.mapValues(Date.init(timeIntervalSince1970:))
    }

    private func storeDates(_ dates: [String: Date], forKey key: String) {
        defaults.set(dates.mapValues(\.timeIntervalSince1970), forKey: key)
    }
}
