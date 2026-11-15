import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

private let preuploadLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacMedia")

/// A pre-upload target held by the Mac media service.
struct WiltedMacPreuploadTarget: Sendable, Equatable {
    var entryID: ItemID
    var audio: WiltedMacReadyAudio
}

extension WiltedMacMediaService {
    /// Recomputes `preuploadTargets` from the prepared queued entries in queue order, and forgets the
    /// delivered mark of an entry that has left the Larder. A mark outlives a loss of prepared audio, so
    /// audio a device acknowledged is not uploaded again while its entry stays on the Larder.
    func updatePreuploadTargets() async throws {
        guard preuploadLimit > 0 else {
            preuploadTargets = []
            return
        }
        let queued = try await source.preparedQueued()
        let larder = Set(queued.larderIDs.map(\.rawValue))
        delivered = delivered.filter { larder.contains($0.key) }
        let eligible = queued.entries.filter { entryID, audio in
            audio.byteCount <= Self.maximumByteCount
                && Self.fileSize(audio.fileURL) == audio.byteCount
                && delivered[entryID.rawValue] != audio.revisionID.rawValue
        }
        let targets = eligible.prefix(preuploadLimit).map { WiltedMacPreuploadTarget(entryID: $0.0, audio: $0.1) }
        // A round every 30 s must not write a line every 30 s: only a changed list is logged.
        if targets != preuploadTargets {
            preuploadLog.notice("Pre-upload targets changed: \(targets.count, privacy: .public) entries")
        }
        preuploadTargets = targets
    }
}
