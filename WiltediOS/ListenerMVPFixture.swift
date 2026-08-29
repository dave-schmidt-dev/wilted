#if DEBUG
import CryptoKit
import Foundation
import SwiftUI
import WiltedDomain
import WiltedListener
import WiltedSync

/// Account-free composition used only by the listener's production-view UI test.
///
/// The fixture hosts the same root and listener views as the shipping app, with
/// a local source file and cache. Only the recovery control is fixture-specific.
@MainActor
struct ListenerMVPFixture: View {
    @ObservedObject var model: WiltedListenerAppModel

    static func makeModel() -> WiltedListenerAppModel {
        do {
            let bytes = Data("wilted listener mvp fixture audio".utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WiltedListenerMVPFixture", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("fixture-audio.m4a")
            try bytes.write(to: source, options: .atomic)

            let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
            let playback = ListenerPlaybackController(cache: cache, engine: ListenerMVPFixtureAudioEngine())
            let model = WiltedListenerAppModel(
                cache: cache,
                playback: playback,
                assetLoader: { _, _ in source }
            )
            let itemID = try ItemID.derive(from: URL(string: "https://example.test/listener-mvp")!)
            let revisionID = try RevisionID(rawValue: "listener-mvp-revision")
            let asset = try WiltedAsset(
                assetID: "listener-mvp-audio",
                contentHash: "sha256:\(digest)"
            )
            let revision = try AudioRevision(
                itemID: itemID,
                revisionID: revisionID,
                durationSeconds: 120,
                byteCount: Int64(bytes.count),
                contentHash: asset.contentHash,
                mediaType: "audio/m4a",
                createdAt: Timestamp(Date(timeIntervalSince1970: 0)),
                schemaVersion: 1
            )
            let transcript = try Transcript(
                itemID: itemID,
                revisionID: revisionID,
                availability: .available,
                text: "This local fixture transcript is available without contacting iCloud.",
                languageCode: "en",
                updatedAt: Timestamp(Date(timeIntervalSince1970: 0))
            )
            model.installMVPFixture(
                item: ListenerLibraryItem(
                    itemID: itemID,
                    title: "A fixture article for listening",
                    source: "Wilted Test Journal",
                    revisionID: revisionID,
                    durationSeconds: revision.durationSeconds,
                    asset: asset,
                    state: .metadataOnly
                ),
                revision: revision,
                asset: asset,
                transcript: transcript
            )
            return model
        } catch {
            return WiltedListenerAppModel(unavailableMessage: "Local fixture unavailable: \(error.localizedDescription)")
        }
    }

    var body: some View {
        WiltedRootView(
            iOSLibrary: AnyView(WiltedListenerLibraryView(model: model)),
            iOSNowPlaying: AnyView(WiltedListenerNowPlayingView(model: model)),
            iOSSettings: AnyView(WiltedListenerSettingsView(model: model)),
            iOSOverlay: AnyView(fixtureControls)
        )
    }

    @ViewBuilder
    private var fixtureControls: some View {
        switch model.status {
        case .failed(_, retryable: false):
            Button("Recover Larder") { Task { await model.recoverMVPFixture() } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wilted-listener-fixture-recover")
                .padding()
        default:
            Button("Simulate Account Switch") { model.quarantineForMVPFixture() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("wilted-listener-fixture-quarantine")
                .padding()
        }
    }
}

private final class ListenerMVPFixtureAudioEngine: ListenerAudioEngine, @unchecked Sendable {
    var duration: Double = 120
    var currentTime: Double = 0
    private(set) var isPlaying = false

    func load(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ListenerError.cacheUnavailable(url.lastPathComponent)
        }
    }

    func play() -> Bool {
        // A deterministic advance lets the production view expose a resume
        // position without requiring a real audio session in the simulator.
        currentTime = min(duration, currentTime + 12)
        isPlaying = true
        return true
    }

    func pause() { isPlaying = false }
}
#endif
