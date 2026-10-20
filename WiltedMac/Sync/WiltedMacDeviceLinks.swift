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
    private var links: [String: LibraryDeviceLink] = [:]
    private var kinds: [String: String] = [:]
    /// The announcement time each directory entry was last linked for: a newer one means the
    /// device still sees no link (a reset zone, a lost write) and asks again.
    private var answeredAnnouncements: [String: Date] = [:]
    private var unsaved: Set<String> = []
    private var saved: Set<String> = []
    private var flushing: Task<Void, Never>?
    private var lastFailure: String?

    init(transport: any LibraryTransport, macDeviceID: String?, now: @escaping @Sendable () -> Date = { Date() },
         onChange: OnChange? = nil) {
        self.transport = transport
        self.macDeviceID = macDeviceID
        self.now = now
        self.onChange = onChange
    }

    /// Links every device in the directory that this Mac has not linked for its latest announcement.
    func noteDirectory(_ directory: LibraryDeviceDirectory?) async {
        guard let directory else { return }
        var changed = false
        for device in directory.devices where device.deviceID != macDeviceID {
            if kinds[device.deviceID] != device.kind { kinds[device.deviceID] = device.kind; changed = true }
            guard answeredAnnouncements[device.deviceID].map({ device.announcedAt > $0 }) ?? true else { continue }
            answeredAnnouncements[device.deviceID] = device.announcedAt
            links[device.deviceID] = links[device.deviceID] ?? LibraryDeviceLink(deviceID: device.deviceID, linkedAt: now())
            unsaved.insert(device.deviceID)
            changed = true
        }
        if changed { await report() }
    }

    /// Links devices found without an announcement: by their requests or playback records.
    func noteDevices(_ deviceIDs: some Sequence<String>) async {
        var changed = false
        for deviceID in deviceIDs where deviceID != macDeviceID && links[deviceID] == nil && !deviceID.isEmpty {
            links[deviceID] = LibraryDeviceLink(deviceID: deviceID, linkedAt: now())
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
                  links[intent.deviceID]?.status(intentID: intent.id) == nil else { continue }
            set(LibraryMediaRequestStatus(intentID: intent.id, entryID: entryID, stage: .received, updatedAt: now()),
                for: intent.deviceID)
            changed = true
        }
        if changed { await report() }
    }

    /// Records and writes a later stage of `intent`'s request at once, so the device sees it while it
    /// waits and a Mac that quits right after answering leaves no request looking unanswered.
    func record(_ intent: LibraryIntent, stage: LibraryMediaRequestStatus.Stage, detail: String? = nil) async {
        guard case let .requestMedia(entryID) = intent.action, intent.deviceID != macDeviceID else { return }
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
                inFlight: link.requests.filter { $0.stage == .received || $0.stage == .sending })
        }
        .sorted { ($0.kind ?? "~", $0.deviceID) < ($1.kind ?? "~", $1.deviceID) }
    }

    private func set(_ status: LibraryMediaRequestStatus, for deviceID: String) {
        let link = links[deviceID] ?? LibraryDeviceLink(deviceID: deviceID, linkedAt: now())
        links[deviceID] = link.updating(status, server: nil, now: now())
        unsaved.insert(deviceID)
    }

    private func writeUnsaved() async {
        var changed = false
        for deviceID in unsaved.sorted() {
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

    private func report() async { await onChange?(devices()) }
}
