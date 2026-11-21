import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let linkLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacDeviceLinks")

/// One follower device as the Sync card shows it.
struct WiltedMacLinkedDevice: Equatable, Sendable, Identifiable {
    var id: String { deviceID }
    let deviceID: String
    /// "iPhone" or "iPad" from the device's announcement; nil for a device found only by its
    /// requests or playback records.
    let kind: String?
    /// False until this Mac's link record for the device is saved in iCloud.
    let isLinked: Bool
    /// The device's media requests this Mac has not finished answering.
    let inFlight: [LibraryMediaRequestStatus]
    /// Whether direct LAN downloads are stopped for this follower device.
    var isDirectDownloadsStopped: Bool = false
    /// A display-only label saved in this Mac's preferences.
    var displayName: String? = nil
    /// The newest announcement timestamp seen by this Mac.
    var lastAnnouncedAt: Date? = nil
}

/// The Mac's side of the device handshake: it links every follower it learns of (from the
/// directory, an intent, or playback records) by writing that device's `LibraryDeviceLink`, then
/// writes each media request's stage to it, so the device knows its request was read and how it
/// is going.
///
/// Writes are by name and only for a device whose link changed, so an idle round writes nothing.
/// A write that fails keeps the device marked unsaved and is retried on the next `flush`.
actor WiltedMacDeviceLinks {
    typealias OnChange = @Sendable ([WiltedMacLinkedDevice]) async -> Void

    private let transport: any LibraryTransport
    private let macDeviceID: String?
    private let now: @Sendable () -> Date
    private let onChange: OnChange?
    private let preferences: WiltedMacLANPreferences?
    private var links: [String: LibraryDeviceLink] = [:]
    private var kinds: [String: String] = [:]
    /// The announcement time each directory entry was last linked for: a newer one means the
    /// device still sees no link (a reset zone, a lost write) and asks again.
    private var answeredAnnouncements: [String: Date] = [:]
    private var unsaved: Set<String> = []
    private var saved: Set<String> = []
    private var flushing: Task<Void, Never>?
    private var lastFailure: String?
    private var macLANPublicKey: Data?
    private var stoppedDevices: Set<String> = []
    private var phonePublicKeys: [String: Data] = [:]
    private var displayNames: [String: String]
    private var lastAnnouncements: [String: Date]
    private var removalDates: [String: Date]
    private var removingDevices: Set<String> = []

    init(transport: any LibraryTransport, macDeviceID: String?, now: @escaping @Sendable () -> Date = { Date() },
         onChange: OnChange? = nil, preferences: WiltedMacLANPreferences? = nil) {
        self.transport = transport
        self.macDeviceID = macDeviceID
        self.now = now
        self.onChange = onChange
        self.preferences = preferences
        stoppedDevices = preferences?.stoppedPhones ?? []
        displayNames = preferences?.deviceDisplayNames ?? [:]
        lastAnnouncements = preferences?.deviceAnnouncementDates ?? [:]
        removalDates = preferences?.deviceRemovalDates ?? [:]
    }

    /// Updates this Mac's published LAN key across all device links.
    func setMacLANPublicKey(_ key: Data?) async {
        macLANPublicKey = key
        var changed = false
        for (deviceID, link) in links {
            guard !removingDevices.contains(deviceID) else { continue }
            let isStopped = stoppedDevices.contains(deviceID)
            let targetMacKey = isStopped ? nil : key
            let targetFingerprint = isStopped ? nil : phonePublicKeys[deviceID].map { LANPairingKey.fingerprint(of: $0) }
            if link.lanPublicKey != targetMacKey || link.knownPhoneKeyFingerprint != targetFingerprint {
                links[deviceID] = LibraryDeviceLink(
                    deviceID: link.deviceID,
                    linkedAt: link.linkedAt,
                    requests: link.requests,
                    lanPublicKey: targetMacKey,
                    knownPhoneKeyFingerprint: targetFingerprint
                )
                unsaved.insert(deviceID)
                changed = true
            }
        }
        if changed { await report() }
    }

    /// Drops direct download capabilities for one device ("Stop direct downloads for this iPhone").
    func stopDirectDownloads(for deviceID: String) async {
        guard !removingDevices.contains(deviceID) else { return }
        stoppedDevices.insert(deviceID)
        if let link = links[deviceID] {
            links[deviceID] = LibraryDeviceLink(
                deviceID: link.deviceID,
                linkedAt: link.linkedAt,
                requests: link.requests,
                lanPublicKey: nil,
                knownPhoneKeyFingerprint: nil
            )
            unsaved.insert(deviceID)
            await flush()
            await report()
        }
    }

    /// Whether direct downloads have been stopped for this device.
    func isDirectDownloadsStopped(for deviceID: String) -> Bool {
        stoppedDevices.contains(deviceID)
    }

    /// The phone public key held for this device, if announced.
    func phonePublicKey(for deviceID: String) -> Data? {
        phonePublicKeys[deviceID]
    }

    /// Saves a local-only display name for this linked device. An empty name clears the alias.
    func renameDevice(_ deviceID: String, to displayName: String) async throws {
        guard links[deviceID] != nil else { throw WiltedMacDeviceManagementError.deviceUnavailable }
        guard !removingDevices.contains(deviceID) else {
            throw WiltedMacDeviceManagementError.removalInProgress
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            displayNames.removeValue(forKey: deviceID)
        } else {
            displayNames[deviceID] = trimmed
        }
        preferences?.setDeviceDisplayName(displayNames[deviceID], for: deviceID)
        await report()
    }

    /// Deletes one remote link, then removes this Mac's cached device state and tombstones old announcements.
    func removeDevice(_ deviceID: String) async throws {
        guard links[deviceID] != nil else { throw WiltedMacDeviceManagementError.deviceUnavailable }
        guard removingDevices.insert(deviceID).inserted else {
            throw WiltedMacDeviceManagementError.removalInProgress
        }
        defer { removingDevices.remove(deviceID) }

        // Join any publication already in flight before deleting, so a late write cannot recreate the link.
        let pendingFlush = flushing
        await pendingFlush?.value
        try await transport.deleteDeviceLink(deviceID: deviceID)

        let cutoff = max(now(), lastAnnouncements[deviceID] ?? .distantPast)
        links.removeValue(forKey: deviceID)
        kinds.removeValue(forKey: deviceID)
        phonePublicKeys.removeValue(forKey: deviceID)
        answeredAnnouncements.removeValue(forKey: deviceID)
        unsaved.remove(deviceID)
        saved.remove(deviceID)
        stoppedDevices.insert(deviceID)
        displayNames.removeValue(forKey: deviceID)
        removalDates[deviceID] = cutoff
        lastAnnouncements[deviceID] = nil
        preferences?.insertStoppedPhone(deviceID)
        preferences?.setDeviceDisplayName(nil, for: deviceID)
        preferences?.setDeviceRemovalDate(cutoff, for: deviceID)
        preferences?.setDeviceAnnouncementDate(nil, for: deviceID)
        await report()
    }

    /// Links every device in the directory that this Mac has not linked for its latest announcement.
    func noteDirectory(_ directory: LibraryDeviceDirectory?) async {
        guard let directory else { return }
        var changed = false
        for device in directory.devices where device.deviceID != macDeviceID {
            let deviceID = device.deviceID
            guard !removingDevices.contains(deviceID) else { continue }
            let knownAnnouncement = lastAnnouncements[deviceID]
            if let removalDate = removalDates[deviceID] {
                guard device.announcedAt > removalDate else { continue }
            }
            if let knownAnnouncement, device.announcedAt < knownAnnouncement { continue }

            if let phoneKey = device.lanPublicKey {
                phonePublicKeys[deviceID] = phoneKey
            }
            if kinds[deviceID] != device.kind { kinds[deviceID] = device.kind; changed = true }
            if device.announcedAt > (knownAnnouncement ?? .distantPast) {
                lastAnnouncements[deviceID] = device.announcedAt
                preferences?.setDeviceAnnouncementDate(device.announcedAt, for: deviceID)
            }
            let needsLink = links[deviceID] == nil
                || (answeredAnnouncements[deviceID].map { device.announcedAt > $0 } ?? true)
            let isStopped = stoppedDevices.contains(deviceID)
            let targetMacKey = isStopped ? nil : macLANPublicKey
            let targetFingerprint = isStopped ? nil : device.lanPublicKey.map { LANPairingKey.fingerprint(of: $0) }
            let existing = links[deviceID]
            if needsLink || existing?.lanPublicKey != targetMacKey || existing?.knownPhoneKeyFingerprint != targetFingerprint {
                answeredAnnouncements[deviceID] = device.announcedAt
                links[deviceID] = LibraryDeviceLink(
                    deviceID: deviceID,
                    linkedAt: existing?.linkedAt ?? now(),
                    requests: existing?.requests ?? [],
                    lanPublicKey: targetMacKey,
                    knownPhoneKeyFingerprint: targetFingerprint
                )
                unsaved.insert(deviceID)
                changed = true
            }
        }
        if changed { await report() }
    }

    /// Links devices found without an announcement: by their requests or playback records.
    func noteDevices(_ deviceIDs: some Sequence<String>) async {
        var changed = false
        for deviceID in deviceIDs where deviceID != macDeviceID && links[deviceID] == nil
            && !deviceID.isEmpty && !removingDevices.contains(deviceID) && !isAwaitingFreshAnnouncement(deviceID) {
            let isStopped = stoppedDevices.contains(deviceID)
            let targetMacKey = isStopped ? nil : macLANPublicKey
            let targetFingerprint = isStopped ? nil : phonePublicKeys[deviceID].map { LANPairingKey.fingerprint(of: $0) }
            links[deviceID] = LibraryDeviceLink(
                deviceID: deviceID, linkedAt: now(),
                lanPublicKey: targetMacKey, knownPhoneKeyFingerprint: targetFingerprint)
            unsaved.insert(deviceID)
            changed = true
        }
        if changed { await report() }
    }

    /// Marks each new media request `received`. A request that already has a stage keeps it, so a
    /// request read again never moves back from `answered` or `failed`.
    func noteReceived(_ intents: [LibraryIntent]) async {
        var changed = false
        for intent in intents {
            guard case let .requestMedia(entryID) = intent.action,
                  links[intent.deviceID]?.status(intentID: intent.id) == nil,
                  !removingDevices.contains(intent.deviceID), !isAwaitingFreshAnnouncement(intent.deviceID) else { continue }
            set(LibraryMediaRequestStatus(intentID: intent.id, entryID: entryID, stage: .received, updatedAt: now()),
                for: intent.deviceID)
            changed = true
        }
        if changed { await report() }
    }

    /// Records and writes a later stage of `intent`'s request at once, so the device sees it while it
    /// waits and a Mac that quits right after answering leaves no request looking unanswered.
    func record(_ intent: LibraryIntent, stage: LibraryMediaRequestStatus.Stage, detail: String? = nil) async {
        guard case let .requestMedia(entryID) = intent.action, intent.deviceID != macDeviceID,
              !removingDevices.contains(intent.deviceID), !isAwaitingFreshAnnouncement(intent.deviceID) else { return }
        set(LibraryMediaRequestStatus(intentID: intent.id, entryID: entryID, stage: stage, detail: detail, updatedAt: now()),
            for: intent.deviceID)
        await report()
        await flush()
    }

    /// Writes every link that changed since its last save, one at a time.
    func flush() async {
        let previous = flushing
        let task = Task { await previous?.value; await self.writeUnsaved() }
        flushing = task
        await task.value
    }

    /// The devices for the Sync card, sorted by kind then id.
    func devices() -> [WiltedMacLinkedDevice] {
        links.values.map { link in
            WiltedMacLinkedDevice(
                deviceID: link.deviceID, kind: kinds[link.deviceID],
                isLinked: saved.contains(link.deviceID),
                inFlight: link.requests.filter { $0.stage == .received || $0.stage == .sending },
                isDirectDownloadsStopped: stoppedDevices.contains(link.deviceID),
                displayName: displayNames[link.deviceID], lastAnnouncedAt: lastAnnouncements[link.deviceID])
        }
        .sorted { ($0.kind ?? "~", $0.deviceID) < ($1.kind ?? "~", $1.deviceID) }
    }

    private func set(_ status: LibraryMediaRequestStatus, for deviceID: String) {
        let isStopped = stoppedDevices.contains(deviceID)
        let targetMacKey = isStopped ? nil : macLANPublicKey
        let targetFingerprint = isStopped ? nil : phonePublicKeys[deviceID].map { LANPairingKey.fingerprint(of: $0) }
        let link = links[deviceID] ?? LibraryDeviceLink(
            deviceID: deviceID, linkedAt: now(),
            lanPublicKey: targetMacKey, knownPhoneKeyFingerprint: targetFingerprint)
        links[deviceID] = link.updating(status, server: nil, now: now())
        unsaved.insert(deviceID)
    }

    private func writeUnsaved() async {
        var changed = false
        for deviceID in unsaved.sorted() {
            guard !removingDevices.contains(deviceID) else { continue }
            guard unsaved.remove(deviceID) != nil, let link = links[deviceID] else { continue }
            do {
                try await transport.publishDeviceLink(link)
                if saved.insert(deviceID).inserted {
                    changed = true
                    linkLog.notice("Linked device \(deviceID, privacy: .public)")
                }
                lastFailure = nil
            } catch {
                unsaved.insert(deviceID)
                let failure = String(describing: error)
                // A held account repeats every round, so only a change is logged; a rate limit
                // reports itself on the Sync card.
                if failure != lastFailure, !(error is TransportThrottled) {
                    linkLog.error("Could not save the link for \(deviceID, privacy: .public): \(failure, privacy: .public)")
                }
                lastFailure = failure
            }
        }
        if changed { await report() }
    }

    private func isAwaitingFreshAnnouncement(_ deviceID: String) -> Bool {
        guard let removalDate = removalDates[deviceID] else { return false }
        return (lastAnnouncements[deviceID] ?? .distantPast) <= removalDate
    }

    private func report() async { await onChange?(devices()) }
}

#if canImport(AppKit)
enum WiltedMacDeviceManagementError: LocalizedError {
    case syncUnavailable
    case deviceUnavailable
    case removalInProgress

    var errorDescription: String? {
        switch self {
        case .syncUnavailable: "Device settings are unavailable while library sync is stopped."
        case .deviceUnavailable: "This device is no longer available. Refresh the device list and try again."
        case .removalInProgress: "This device is already being removed."
        }
    }
}

extension WiltedMacModel {
    /// Saves a device's display label locally on this Mac.
    func renameDevice(_ deviceID: String, to displayName: String) async throws {
        guard let links = librarySyncController?.inbound?.links else {
            throw WiltedMacDeviceManagementError.syncUnavailable
        }
        try await links.renameDevice(deviceID, to: displayName)
    }

    /// Removes the selected device link and then revokes its cached LAN peer.
    func removeDevice(_ deviceID: String) async throws {
        guard let inbound = librarySyncController?.inbound else {
            throw WiltedMacDeviceManagementError.syncUnavailable
        }
        try await inbound.removeDevice(deviceID)
    }
}
#endif
