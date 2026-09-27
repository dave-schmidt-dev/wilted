import Foundation
import SwiftUI
import WiltedDomain
import WiltedListener
import WiltedSync

#if WILTED_CLOUDKIT_LIVE
import CloudKit
import WiltedCloudKit
#endif

extension WiltedListenerAppModel {
    func loadLocal(
        repository: any SyncRepository,
        fallback: String,
        operation: UInt64? = nil
    ) async {
        let state = await repository.state()
        guard operation.map(isCurrent) ?? true else { return }
        let previousAssets = assetByItem
        rebuild(from: state)
        await reconcileCachedAssets(previousAssets)
        guard operation.map(isCurrent) ?? true else { return }
        await restoreMetadata()
        guard operation.map(isCurrent) ?? true else { return }
        await updateDownloadedStates()
        guard operation.map(isCurrent) ?? true else { return }
        if decodeHadErrors { syncPhase = .incompatible("Some listener records are incompatible") }
        else if items.contains(where: { $0.state == .deleted }) { syncPhase = .deleted("An item was deleted remotely") }
        else if items.isEmpty { syncPhase = .offline(fallback) }
        else if items.contains(where: { $0.state == .incompatibleRevision }) {
            syncPhase = .incompatible("A larder item has an incompatible revision")
        } else { syncPhase = .offline(fallback) }
    }

    func reconcileCachedAssets(_ previousAssets: [ItemID: WiltedAsset]) async {
        guard let cache, !assetByItem.isEmpty || !previousAssets.isEmpty else { return }
        await cache.reconcile(retaining: Array(assetByItem.values))
    }

    func updateDownloadedStates() async {
        guard let cache else { return }
        var updated: [ListenerLibraryItem] = []
        for item in items {
            guard item.state == .metadataOnly || item.state == .downloaded, let asset = item.asset else {
                updated.append(item)
                continue
            }
            let downloaded = await cache.url(for: asset) != nil
            updated.append(ListenerLibraryItem(itemID: item.itemID, title: item.title, source: item.source,
                                               revisionID: item.revisionID, durationSeconds: item.durationSeconds,
                                               asset: item.asset, state: downloaded ? .downloaded : .metadataOnly))
        }
        items = updated
        await refreshDownloadStatistics()
    }

    func rebuild(from state: SyncRepositoryState) {
        let codec = WiltedRecordCodec()
        decodeHadErrors = false
        let activePlaybackPresentation: PlaybackState? = if case .playing = playbackPhase {
            selectedPlayback
        } else {
            nil
        }
        let previousItems = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0) })
        var articles: [(Article, WiltedRecordEnvelope)] = []
        var revisions: [ItemID: [RevisionID: (AudioRevision, WiltedAsset?, AudioChunkManifest?)]] = [:]
        revisionByItem = [:]
        assetByItem = [:]
        manifestByItem = [:]
        playbackByItem = [:]
        playbackChangeTagByItem = [:]
        var playbackCandidates: [ItemID: [PlaybackCandidate]] = [:]
        var transcriptRecords: [WiltedRecordID: Transcript] = [:]
        for envelope in state.records {
            switch envelope.id.recordType {
            case .item:
                do { articles.append((try codec.decodeArticleRecord(envelope).value, envelope)) }
                catch { decodeHadErrors = true }
            case .revision:
                do {
                    let decoded = try codec.decodeRevisionRecord(envelope)
                    let legacyAsset: WiltedAsset?
                    if case let .asset(asset) = envelope.fields["audioAsset"] {
                        legacyAsset = asset
                    } else {
                        legacyAsset = nil
                    }
                    let manifest: AudioChunkManifest?
                    if case let .bytes(data) = envelope.fields["audioManifest"] {
                        manifest = try JSONDecoder().decode(AudioChunkManifest.self, from: data)
                    } else {
                        manifest = nil
                    }
                    guard legacyAsset != nil || manifest != nil else { throw ListenerError.metadataCorrupt }
                    let asset = legacyAsset ?? (try? WiltedAsset(
                        assetID: "audio:\(decoded.value.revisionID.rawValue)",
                        contentHash: decoded.value.contentHash
                    ))
                    revisions[decoded.value.itemID, default: [:]][decoded.value.revisionID] =
                        (decoded.value, asset, manifest)
                } catch { decodeHadErrors = true }
            case .revisionChunk:
                // Chunk records are fetched only after a user selects their revision;
                // they are transport rows, never standalone library entries.
                continue
            case .transcript:
                do { transcriptRecords[envelope.id] = try codec.decodeTranscript(envelope) }
                catch { decodeHadErrors = true }
            case .playbackState:
                do {
                    let decoded = try codec.decodePlaybackRecord(envelope)
                    playbackCandidates[decoded.value.itemID, default: []].append(
                        PlaybackCandidate(state: decoded.value, changeTag: envelope.sidecar?.changeTag)
                    )
                }
                catch { decodeHadErrors = true }
            }
        }
        var rebuilt: [ListenerLibraryItem] = []
        for (article, envelope) in articles {
            let revisionID = (try? RevisionID(rawValue: envelope.fields["currentRevisionID"].flatMap { value in
                if case let .string(id) = value { return id }; return nil
            } ?? ""))
            let match: (AudioRevision, WiltedAsset?, AudioChunkManifest?)?
            if let revisionID, let itemRevisions = revisions[article.itemID] {
                match = itemRevisions[revisionID]
            } else {
                match = nil
            }
            if let match {
                revisionByItem[article.itemID] = match.0
                if let asset = match.1 { assetByItem[article.itemID] = asset }
                if let manifest = match.2 { manifestByItem[article.itemID] = manifest }
            }
            let state: ListenerItemState = article.isDeleted ? .deleted : match == nil ? .incompatibleRevision : .metadataOnly
            rebuilt.append(ListenerLibraryItem(itemID: article.itemID, title: article.title, source: article.source,
                                                revisionID: match?.0.revisionID ?? revisionID, durationSeconds: match?.0.durationSeconds,
                                                asset: match?.1, state: state))
            guard !article.isDeleted, let selectedRevisionID = match?.0.revisionID,
                  let selected = latestPlayback(
                      playbackCandidates[article.itemID, default: []].filter {
                          $0.state.revisionID == selectedRevisionID
                      }
                  ) else { continue }
            playbackByItem[article.itemID] = selected.state
            if let changeTag = selected.changeTag {
                playbackChangeTagByItem[article.itemID] = changeTag
            }
        }
        let rebuiltIDs = Set(rebuilt.map(\.itemID))
        rebuilt.append(contentsOf: previousItems.values.filter { !rebuiltIDs.contains($0.itemID) }.map {
            ListenerLibraryItem(itemID: $0.itemID, title: $0.title, source: $0.source,
                                revisionID: $0.revisionID, durationSeconds: $0.durationSeconds,
                                asset: nil, state: .deleted)
        })
        items = rebuilt.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if let activePlaybackPresentation,
           revisionByItem[activePlaybackPresentation.itemID]?.revisionID == activePlaybackPresentation.revisionID {
            playbackByItem[activePlaybackPresentation.itemID] = activePlaybackPresentation
        }
        transcriptsByItem = Dictionary(uniqueKeysWithValues: rebuilt.compactMap { item in
            guard let revisionID = item.revisionID,
                  let recordID = try? WiltedRecordID.transcript(item.itemID, revisionID),
                  let transcript = transcriptRecords[recordID] else { return nil }
            return (item.itemID, transcript)
        })
        selectedPlayback = selectedItemID.flatMap { playbackByItem[$0] }
    }

    private struct PlaybackCandidate: Equatable, Sendable {
        let state: PlaybackState
        let changeTag: String?
    }

    /// Chooses a unique causally latest candidate. An incomparable set is rejected rather
    /// than resolved by record identity or the order in which records happened to arrive.
    private func latestPlayback(_ candidates: [PlaybackCandidate]) -> PlaybackCandidate? {
        var unique: [PlaybackCandidate] = []
        for candidate in candidates where !unique.contains(candidate) {
            unique.append(candidate)
        }
        guard !unique.isEmpty else { return nil }
        let maximal = unique.filter { candidate in
            !unique.contains { other in
                guard candidate != other else { return false }
                let result = mergePlayback(
                    current: candidate.state,
                    incoming: other.state,
                    changeTagMatches: candidate.changeTag == other.changeTag
                )
                return result.acceptedStateIsIncoming
            }
        }
        guard !maximal.isEmpty else { return nil }
        let ranked = maximal.map { candidate in
            let wins = unique.reduce(into: 0) { count, other in
                guard candidate != other else { return }
                let result = mergePlayback(
                    current: other.state,
                    incoming: candidate.state,
                    changeTagMatches: other.changeTag == candidate.changeTag
                )
                if result.acceptedStateIsIncoming { count += 1 }
            }
            return (candidate, wins)
        }
        let highest = ranked.map { $0.1 }.max() ?? 0
        let winners = ranked.filter { $0.1 == highest }
        guard winners.count == 1 else { return nil }
        return winners[0].0
    }

    func refreshPresentationFacts() async {
        await refreshDownloadStatistics()
        await refreshSyncObservability()
    }

    func refreshDownloadStatistics() async {
        guard let cache else {
            downloadStatistics = ListenerDownloadStatistics()
            return
        }
        downloadStatistics = (try? await cache.statistics()) ?? ListenerDownloadStatistics()
    }

    func refreshSyncObservability() async {
        guard let listenerRepository = repository as? ListenerRepository else {
            syncObservability = ListenerSyncObservability()
            return
        }
        syncObservability = await listenerRepository.loadObservability() ?? ListenerSyncObservability()
    }

    /// Builds the playback state for an item that has never been played.
    ///
    /// `sequence` starts at one because `PlaybackState` rejects anything lower, and a
    /// state that cannot be constructed leaves the item permanently unplayable: `play`
    /// has no other way to begin. A new session restarts the numbering at the same floor.
    func makeInitialPlayback(for item: ListenerLibraryItem, revision: AudioRevision) -> PlaybackState? {
        try? PlaybackState(itemID: item.itemID, revisionID: revision.revisionID, sessionID: UUID().uuidString,
                           sequence: 1, positionSeconds: 0, durationSeconds: revision.durationSeconds,
                           completed: false, intent: .progress, deviceID: "iphone", updatedAt: Timestamp(Date()))
    }

    func restoreMetadata() async {
        guard selectedItemID == nil, let metadata = await metadataLoader?(), let recordID = metadata.lastPlayedRecordID else { return }
        for (itemID, state) in playbackByItem {
            if (try? WiltedRecordID.playback(itemID, state.revisionID)) == recordID {
                selectedItemID = itemID
                selectedPlayback = state
                return
            }
        }
    }

}
