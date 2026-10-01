import Foundation
import WiltedDomain
import WiltedLibrary

/// The phone's own last position per episode, kept on the phone so a launch with no signal (the
/// car, a tunnel) still resumes where this phone left off instead of at 0. It is only a fallback
/// input to `resumeStart`: the same epoch rules that rank a Mac record against the phone's own
/// still decide, and a fetch from the server replaces what is here, except positions saved but
/// not yet published, which are persisted too so a relaunch cannot lose them to an older server copy.
///
/// Written with `LibraryFileProtection` so it reads while the phone is locked.
struct LibraryOwnPositionStore: Sendable {
    struct Saved: Sendable {
        var positions: [ItemID: ObservedPlayback] = [:]
        var unpublished: [ItemID: (position: Double, savedAt: Date)] = [:]
        /// The other devices' newest records (the Mac), so a cold offline start resumes from them too.
        var checkpoints: [ItemID: ObservedPlayback] = [:]
    }

    private struct Entry: Codable {
        let record: DevicePlaybackPosition
        let serverModifiedAt: Date
    }

    private struct Pending: Codable {
        let entryID: ItemID
        let position: Double
        let savedAt: Date
    }

    private struct File: Codable {
        var positions: [Entry]
        var unpublished: [Pending]
        var checkpoints: [Entry]?
    }

    /// nil keeps positions in memory only (tests, previews).
    let url: URL?

    func load() -> Saved {
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return Saved() }
        return Saved(
            positions: Dictionary(
                file.positions.map { ($0.record.entryID, ObservedPlayback(record: $0.record, serverModifiedAt: $0.serverModifiedAt)) },
                uniquingKeysWith: { first, _ in first }),
            unpublished: Dictionary(
                file.unpublished.map { ($0.entryID, (position: $0.position, savedAt: $0.savedAt)) },
                uniquingKeysWith: { first, _ in first }),
            checkpoints: Dictionary(
                (file.checkpoints ?? []).map { ($0.record.entryID, ObservedPlayback(record: $0.record, serverModifiedAt: $0.serverModifiedAt)) },
                uniquingKeysWith: { first, _ in first }))
    }

    /// Best-effort: a failed write costs only the offline resume point, never playback.
    func save(_ saved: Saved) {
        guard let url else { return }
        let file = File(
            positions: saved.positions.values.map { Entry(record: $0.record, serverModifiedAt: $0.serverModifiedAt) },
            unpublished: saved.unpublished.map { Pending(entryID: $0.key, position: $0.value.position, savedAt: $0.value.savedAt) },
            checkpoints: saved.checkpoints.values.map { Entry(record: $0.record, serverModifiedAt: $0.serverModifiedAt) })
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
    }
}
