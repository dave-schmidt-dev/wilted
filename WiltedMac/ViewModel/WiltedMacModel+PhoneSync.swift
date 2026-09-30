import Foundation
import WiltedDomain
import WiltedLibrary

/// What the library sync tells the rest of the Mac app: whether iCloud is pausing it, and which
/// episodes the phone listened to last.
extension WiltedMacModel {
    /// The single status line for an episode whose newest listen was on the phone; nil otherwise.
    func phonePositionLabel(forEpisodeID id: String) -> String? {
        guard let itemID = try? ItemID(rawValue: id), let position = phonePositions[itemID] else { return nil }
        return WiltedMacPhonePlayback.label(position)
    }
}

#if canImport(WiltedProducer)
extension WiltedMacModel {
    /// Called by the sync's shared gate when it closes, backs off further, or opens again.
    func libraryThrottleChanged(_ state: TransportGateState?) {
        guard libraryThrottle != state else { return }
        libraryThrottle = state
    }

    /// Refreshes the "Last played on iPhone" lines from a fresh read of the device records.
    func updatePhonePositions(from records: LibraryDeviceRecords, now: Date = Date()) {
        let selected = WiltedMacPhonePlayback.selections(records: records, localDeviceID: libraryDeviceID(), now: now)
        guard selected != phonePositions else { return }
        phonePositions = selected
    }

    /// One bounded read of the phone's position before Play starts the audio; returns when the
    /// position is stored, or when the read failed or timed out (then playback uses what is stored).
    func refreshPhonePositionBeforePlay() async {
        await librarySyncController?.playRefresher?.refreshBeforePlay()
    }
}
#endif
