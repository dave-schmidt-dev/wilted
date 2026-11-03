import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

extension WiltedMacModel {
    /// Applies a position already committed by `PlaybackController` to its visible row.
    ///
    /// Advancing the read epoch rejects any library snapshot that began before this write, so a
    /// late full reload cannot overwrite the row with its older playback value.
    func applyImportedPlaybackPosition(_ request: RemotePositionRequest) {
        libraryReadEpoch &+= 1
        lastAppliedLibraryReadEpoch = libraryReadEpoch
        importedPlaybackReadEpoch = libraryReadEpoch

        guard request.positionSeconds.isFinite, request.durationSeconds.isFinite else { return }
        let position = min(max(0, request.positionSeconds), max(0, request.durationSeconds))
        if let index = episodes.firstIndex(where: { $0.id == request.itemID.rawValue }) {
            guard episodes[index].playbackSeconds != position else { return }
            episodes[index].playbackSeconds = position
            playbackProjectionWriteCountForTesting += 1
        } else if let index = articles.firstIndex(where: { $0.id == request.itemID.rawValue }) {
            guard articles[index].playbackSeconds != position else { return }
            articles[index].playbackSeconds = position
            playbackProjectionWriteCountForTesting += 1
        }
    }
}
#endif
