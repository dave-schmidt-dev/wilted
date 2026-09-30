import Foundation
import WiltedDomain
import WiltedLibrary

/// Where the newest listen to an episode happened, when it was on the phone.
struct WiltedMacPhonePosition: Equatable, Sendable {
    let entryID: ItemID
    /// The phone's position, moved on by the time since it saved a record that says it was playing.
    let positionSeconds: Double
    let isPlaying: Bool
}

/// Pure selection and wording for "Last played on iPhone at mm:ss", driven by the device records
/// rather than by the Mac's stored state, which is the Mac's own after the phone's position is adopted.
enum WiltedMacPhonePlayback {
    /// The device-ID prefix the phone's install id is created with (`LibraryEnvironment`).
    static let phoneDevicePrefix = "iphone-"

    /// One entry per episode whose newest record (by `HandoffResolver` order across every device,
    /// the Mac's own included) belongs to a phone and is not below the entry's highest epoch.
    /// A Mac listen after the phone's puts the Mac's record first, so the line goes away. A phone
    /// position of zero is not a position.
    static func selections(
        records: LibraryDeviceRecords, localDeviceID: String, now: Date
    ) -> [ItemID: WiltedMacPhonePosition] {
        let all = records.nowPlaying + records.progress
        let offset = HandoffPositionImport.clockOffset(of: all.filter { $0.record.deviceID == localDeviceID })
        var result: [ItemID: WiltedMacPhonePosition] = [:]
        for (entryID, entryRecords) in Dictionary(grouping: all, by: \.record.entryID) {
            guard let newest = HandoffResolver.winner(among: entryRecords),
                  newest.record.deviceID.hasPrefix(phoneDevicePrefix),
                  !HandoffResolver.isStale(newest.record, seen: entryRecords.map(\.record)) else { continue }
            let position = HandoffResolver.resumePosition(
                of: newest, now: now, clockOffset: offset,
                durationSeconds: nil)
            guard position > 0 else { continue }
            let playing = HandoffResolver.effective(newest, now: now, clockOffset: offset).record.isPlaying
            result[entryID] = WiltedMacPhonePosition(entryID: entryID, positionSeconds: position, isPlaying: playing)
        }
        return result
    }

    /// "Last played on iPhone at 12:34" (or "1:02:03" past an hour).
    static func label(_ position: WiltedMacPhonePosition) -> String {
        "Last played on iPhone at \(clock(position.positionSeconds))"
    }

    static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        let (hours, minutes, secs) = (whole / 3_600, (whole % 3_600) / 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
