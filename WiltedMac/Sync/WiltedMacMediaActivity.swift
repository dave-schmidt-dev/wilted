import Foundation
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

/// A snapshot of ahead-of-time media uploads and queued requests.
struct WiltedMacMediaActivity: Equatable, Sendable {
    typealias PauseReason = Preupload.PauseReason

    struct Preupload: Equatable, Sendable {
        enum PauseReason: String, Equatable, Sendable {
            case storageFull
            case retrying
        }

        var targetCount: Int
        var uploadedCount: Int
        var uploadingID: String?
        var pausedUntil: Date?
        var pauseReason: PauseReason?
        var setAsideCount: Int
        var isStopped: Bool

        init(
            targetCount: Int,
            uploadedCount: Int,
            uploadingID: String? = nil,
            pausedUntil: Date? = nil,
            pauseReason: PauseReason? = nil,
            setAsideCount: Int = 0,
            isStopped: Bool = false
        ) {
            self.targetCount = targetCount
            self.uploadedCount = uploadedCount
            self.uploadingID = uploadingID
            self.pausedUntil = pausedUntil
            self.pauseReason = pauseReason
            self.setAsideCount = setAsideCount
            self.isStopped = isStopped
        }
    }

    var preupload: Preupload?
    var requestsQueued: Int

    init(preupload: Preupload? = nil, requestsQueued: Int = 0) {
        self.preupload = preupload
        self.requestsQueued = requestsQueued
    }
}

extension WiltedMacMediaService {
    /// Pure read of current pre-upload activity. Nil when pre-upload has not yet reconciled.
    func activitySnapshot() -> WiltedMacMediaActivity {
        guard let targets = preuploadTargets else {
            return WiltedMacMediaActivity(preupload: nil, requestsQueued: 0)
        }
        let currentTime = now()
        let uploadedCount = targets.filter { target in
            published[target.entryID.rawValue] == target.audio.revisionID.rawValue
        }.count
        let setAsideCount = targets.filter { target in
            let key = AssetKey(entryID: target.entryID.rawValue, revisionID: target.audio.revisionID.rawValue)
            guard let skipUntil = preuploadSkippedUntil[key] else { return false }
            return currentTime < skipUntil
        }.count
        let isPaused = isPreuploadPaused
        // The audio is booked before its transcript is sent, so a target already counted as
        // uploaded is no longer the one being sent.
        let sendingID = preuploadUploadingID.flatMap { id in
            targets.contains { $0.entryID.rawValue == id && published[id] == $0.audio.revisionID.rawValue } ? nil : id
        }
        let preupload = WiltedMacMediaActivity.Preupload(
            targetCount: targets.count,
            uploadedCount: uploadedCount,
            uploadingID: sendingID,
            pausedUntil: isPaused ? preuploadPausedUntil : nil,
            pauseReason: isPaused ? preuploadPauseReason : nil,
            setAsideCount: setAsideCount,
            isStopped: preuploadStopped
        )
        return WiltedMacMediaActivity(preupload: preupload, requestsQueued: 0)
    }
}
