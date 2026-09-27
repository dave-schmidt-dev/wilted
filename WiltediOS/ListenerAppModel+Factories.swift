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
    public static func makeDefault() -> WiltedListenerAppModel {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wilted", isDirectory: true)
        do {
            let repository = try ListenerRepository(directoryURL: root)
            let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
            let playback = ListenerPlaybackController(cache: cache, engine: AVFoundationAudioEngine())
#if WILTED_CLOUDKIT_LIVE
            if defaultSessionMode() == .liveCloudKit {
                return WiltedListenerAppModel(
                    repository: repository,
                    sessionFactory: { stateData in
                        try await Self.makeLiveSession(root: root, stateData: stateData, repository: repository)
                    },
                    cache: cache,
                    playback: playback,
                    metadataLoader: { await repository.loadMetadata() },
                    metadataSaver: { metadata in try await repository.saveMetadata(metadata) }
                )
            }
#endif
            return WiltedListenerAppModel(
                repository: repository,
                cache: cache,
                playback: playback,
                metadataLoader: { await repository.loadMetadata() },
                metadataSaver: { metadata in try await repository.saveMetadata(metadata) }
            )
        } catch {
            return WiltedListenerAppModel(unavailableMessage: "Local larder unavailable: \(error.localizedDescription)")
        }
    }

    static func defaultSessionMode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isXCTestRuntime: Bool = NSClassFromString("XCTestCase") != nil
    ) -> ListenerDefaultSessionMode {
#if WILTED_CLOUDKIT_LIVE
        environment["XCTestConfigurationFilePath"] == nil && !isXCTestRuntime ? .liveCloudKit : .localOnly
#else
        .localOnly
#endif
    }

    /// Deterministic shipping-view data for iOS pixel tests. This intentionally
    /// has no repository, transport, cache, or audio engine, so capturing the
    /// listener Library cannot touch an account or device media state.
    public static func makePixelFixture(
        state: ListenerPixelFixtureState = .library
    ) -> WiltedListenerAppModel {
        let model = WiltedListenerAppModel()
        if state == .emptyNowPlaying {
            model.syncPhase = .ready
            return model
        }
        guard let itemID = try? ItemID.derive(from: URL(string: "https://example.test/wilted-listener")!) else {
            return model
        }
        guard let revisionID = try? RevisionID(rawValue: "revision-pixel-fixture") else { return model }
        model.items = [
            ListenerLibraryItem(
                itemID: itemID,
                title: "A fixture article for listening",
                source: "Wilted Test Journal",
                revisionID: revisionID,
                durationSeconds: 120,
                asset: nil,
                state: .downloaded
            )
        ]
        model.transcriptsByItem[itemID] = try? Transcript(
            itemID: itemID,
            revisionID: revisionID,
            availability: .available,
            text: "This fixture transcript proves saved article text remains available while listening.",
            languageCode: "en",
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_787_515_200))
        )
        model.downloadStatistics = ListenerDownloadStatistics(fileCount: 1, byteCount: 1_245_184)
        model.syncObservability = ListenerSyncObservability(
            lastSuccessfulFetchAt: Date(timeIntervalSince1970: 1_787_515_200)
        )
        switch state {
        case .library, .emptyNowPlaying:
            model.syncPhase = .ready
        case .nowPlaying:
            guard let playback = try? PlaybackState(
                      itemID: itemID,
                      revisionID: revisionID,
                      sessionID: "pixel-fixture",
                      sequence: 1,
                      positionSeconds: 31,
                      durationSeconds: 120,
                      completed: false,
                      intent: .progress,
                      deviceID: "pixel-fixture-device",
                      updatedAt: Timestamp(Date(timeIntervalSince1970: 0))
                  ) else {
                return model
            }
            model.syncPhase = .ready
            model.playbackPhase = .playing
            model.selectedPlayback = playback
        case .terminalFailure:
            // The quarantine flag, not just its message. Setting only the
            // status reproduced the *appearance* of a quarantined listener
            // without the condition, so the baseline recorded a screen with no
            // recovery control and nothing flagged it as a dead end.
            model.accountQuarantined = true
            model.syncPhase = .failed("iCloud account changed; sync is quarantined", retryable: false)
        }
        return model
    }

}
