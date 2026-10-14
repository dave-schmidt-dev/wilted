import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

extension WiltedMacModel {
#if canImport(WiltedProducer)
    /// The launch argument that holds every playlist write behind a bounded
    /// pending window. It changes nothing on its own: the fixture and directory
    /// guards below must both hold.
    static let playlistWriteDelayFlag = "--wilted-ui-fixture-playlist-write-delay"

    /// Installs the one held playlist-write hook when this launch asked for
    /// it and owns a canonical fixture state directory. The hold runs before
    /// the real store write, which still decides success; nothing here fakes it.
    /// A launch without the flag, or one whose directory is not the owned
    /// fixture root, leaves the static hook and every normal path untouched.
    func installDelayedPlaylistWriteFixtureIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        guard fixtureMode, arguments.contains(Self.playlistWriteDelayFlag),
              let root = Self.fixtureStateDirectoryOverride(arguments: arguments) else { return }
        let canonical = root.standardizedFileURL
        guard canonical == root.resolvingSymlinksInPath().standardizedFileURL,
              canonical == libraryURL.deletingLastPathComponent().standardizedFileURL,
              canonical.lastPathComponent.hasPrefix("wilted-"),
              (try? canonical.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { return }
        let acknowledgments = WiltedMacFixturePlaylistWriteAcknowledgments(root: canonical)
        WiltedMacModel.playlistWriteHookForTesting = {
            try await acknowledgments.waitForRelease()
        }
    }

#endif
}

#if canImport(WiltedProducer)
/// Counts the delayed playlist writes one fixture root serviced, across
/// relaunches of the same owned directory, so a hosted journey can wait out a
/// bounded pending window without polling the UI. It carries one integer and
/// nothing else: no library rows and no owner data.
@MainActor
final class WiltedMacFixturePlaylistWriteAcknowledgments {
    static let fileName = "playlist-ui-write-acknowledgments.json"
    private let root: URL
    private var writes = 0
    private var requestedWrites = 0

    init(root: URL) {
        self.root = root
        let url = root.appendingPathComponent(Self.fileName)
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            writes = stored["writes"] as? Int ?? 0
        }
        requestedWrites = writes
    }

    /// Each request waits for its own synthetic release marker, with a hard bound.
    func waitForRelease() async throws {
        requestedWrites += 1
        let write = requestedWrites
        let marker = root.appendingPathComponent("playlist-ui-write-release-\(write)")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: marker.path) {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw PlaylistFixtureWriteError.releaseTimedOut(write) }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        record()
    }

    func record() {
        writes += 1
        guard let data = try? JSONSerialization.data(withJSONObject: ["writes": writes]) else { return }
        try? data.write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

private enum PlaylistFixtureWriteError: LocalizedError {
    case releaseTimedOut(Int)

    var errorDescription: String? {
        switch self {
        case let .releaseTimedOut(write):
            "Fixture playlist write \(write) was not released within 30 seconds."
        }
    }
}

#endif
