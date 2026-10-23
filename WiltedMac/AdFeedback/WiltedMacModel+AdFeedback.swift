import Foundation
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer

/// Ad feedback from the Now Playing pane and from the phone, filed in the review inbox.
extension WiltedMacModel {
    /// True while a prepared podcast revision is loaded, the only audio feedback can be about.
    /// `removedSpansByEpisode` holds a value exactly when the journal has that revision's timeline.
    var offersAdFeedback: Bool {
        guard isPodcastPlayback, let id = currentPodcastEpisodeID, playback?.revisionID != nil else { return false }
        return removedSpansByEpisode[id] != nil
    }

    /// The cut the listener has just heard, inside `AdFeedbackWindow`; Good cut and Not an ad
    /// are offered only while there is one.
    var adFeedbackNearbyCut: AdCut? {
        guard offersAdFeedback else { return nil }
        let cuts = currentRemovedSpans.map {
            AdCut(preparedSeconds: $0.preparedSeconds, originalStartSeconds: $0.originalStartSeconds,
                  originalEndSeconds: $0.originalEndSeconds, label: $0.label)
        }
        return AdCut.nearest(to: playbackPositionSeconds, in: cuts)
    }

    /// Records the listener's press at the live playhead of the loaded revision.
    func recordAdFeedback(_ kind: AdFeedbackKind) async {
        guard offersAdFeedback, !adFeedback.isSaving, let playback,
              let itemID = playback.itemID, let revisionID = playback.revisionID else { return }
        let position = playback.livePositionSeconds
        let id = UUID().uuidString
        adFeedback.acknowledge(entryID: id, kind: kind, playedSeconds: position)
        defer { adFeedback.pressFinished() }
        let entry = await adFeedbackEntry(
            id: id, kind: kind, itemID: itemID, revisionID: revisionID, playedSeconds: position,
            createdAt: adFeedback.now(), deviceID: libraryDeviceID(), source: .mac)
        await adFeedback.file(entry)
    }

    /// Files a phone's `adFeedback` intent. The phone sent only what it heard; the mapping is done
    /// here against the revision it named, which Prepare Again may since have replaced.
    func recordAdFeedback(_ intent: LibraryIntent) async -> Bool {
        guard case let .adFeedback(itemID, revisionID, kind, playedSeconds) = intent.action else { return false }
        let entry = await adFeedbackEntry(
            id: intent.id, kind: kind, itemID: itemID, revisionID: revisionID, playedSeconds: playedSeconds,
            createdAt: intent.createdAt, deviceID: intent.deviceID, source: .phone)
        return await adFeedback.file(entry)
    }

    private func adFeedbackEntry(
        id: String, kind: AdFeedbackKind, itemID: ItemID, revisionID: RevisionID, playedSeconds: Double,
        createdAt: Date, deviceID: String, source: WiltedMacAdFeedbackEntry.Source
    ) async -> WiltedMacAdFeedbackEntry {
        let timeline = try? await store?.latestPreparationTimeline(for: itemID, revisionID: revisionID)
        let outcome = try? await store?.preparationOutcome(for: itemID, revisionID: revisionID)
        let episode = episodes.first { $0.id == itemID.rawValue }
        return WiltedMacAdFeedbackEntry.make(
            id: id, kind: kind, itemID: itemID, revisionID: revisionID, playedSeconds: playedSeconds,
            timeline: timeline, engineVersion: outcome?.semanticVersion,
            pipelineFingerprint: outcome?.pipelineFingerprint, createdAt: createdAt, deviceID: deviceID,
            source: source, showTitle: episode?.feedTitle, episodeTitle: episode?.title)
    }
}
#endif
