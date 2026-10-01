import AppKit
import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

extension WiltedMacModel {
    static let larderDemoFlag = "--wilted-ui-fixture-larder-demo"

    /// A Larder with enough in it to judge the layout: ten prepared episodes,
    /// two part way through, the first one open in Now Playing with artwork and
    /// the fixture transcript. Everything goes through the store, the same way a
    /// kept and prepared episode would, because the Larder's rows come from the
    /// store's queue rather than from the in-memory list.
    func installLarderDemoEpisodes(
        in store: LocalLibraryStore, feed: PodcastFeed, queueingFirst firstID: ItemID
    ) async {
        let shows = ["Field Notes", "Quiet Season", "Slow Radio"]
        let titles = [
            "The Long Way Round", "What the Archive Kept", "Small Hours", "Ventilation, Revisited",
            "Letters From the Orchard", "A Short History of Salt", "Night Shift", "The Cartographer's Desk",
            "Tide Tables",
        ]
        let progress: [Double] = [0, 612, 0, 0, 1_140, 0, 0, 0, 0]
        let day: TimeInterval = 86_400
        let mediaURL = mediaDirectory.appendingPathComponent("fixture-podcast.mp3")
        var queue = [firstID]
        // The download row is what makes the Larder call an episode downloaded;
        // the first episode's revision and outcome are written by its own install.
        await markDownloaded(firstID, mediaURL: mediaURL, in: store)
        for (index, title) in titles.enumerated() {
            let feedURL = feed.canonicalURL
            let enclosure = URL(string: "https://fixtures.example.test/media/larder-demo-\(index).mp3")!
            let published = Timestamp(Date(timeIntervalSince1970: 1_699_827_200 - Double(index + 1) * day))
            let length = 1_200 + Double(index) * 210
            guard let episodeID = try? ItemID.derivePodcastEpisode(
                    feedURL: feedURL, rssGUID: "larder-demo-\(index)", enclosureURL: enclosure),
                  let episode = try? PodcastEpisode(
                    itemID: episodeID, feedID: feed.itemID, feedURL: feedURL, rssGUID: "larder-demo-\(index)",
                    title: title, author: shows[index % shows.count], publishedTime: published,
                    enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", durationSeconds: length,
                    createdAt: published),
                  let revisionID = try? RevisionID(rawValue: "larder-demo-revision-\(index)"),
                  let revision = try? AudioRevision(
                    itemID: episodeID, revisionID: revisionID, durationSeconds: length, byteCount: 1,
                    contentHash: "sha256:" + String(repeating: "7", count: 64), mediaType: "audio/mpeg",
                    createdAt: published, schemaVersion: 1) else { continue }
            try? await store.save(episode: episode)
            try? await store.saveReadyRevision(revision, mediaURL: mediaURL)
            await markDownloaded(episodeID, mediaURL: mediaURL, in: store)
            try? await store.savePreparationOutcome(PodcastPreparationOutcome(
                episodeID: episodeID, revisionID: revisionID, policyDigest: "fixture-policy",
                pipelineFingerprint: "fixture-fingerprint", semanticVersion: "fixture-semantic-version",
                producedAt: published))
            if progress[index] > 0, let state = try? PlaybackState(
                itemID: episodeID, revisionID: revisionID, sessionID: "larder-demo", sequence: 1,
                positionSeconds: progress[index], durationSeconds: length, completed: false,
                intent: .progress, deviceID: "larder-demo", updatedAt: Timestamp(Date())) {
                try? await store.save(playback: state)
            }
            queue.append(episodeID)
        }
        if let state = try? PodcastQueueState(episodeIDs: queue, currentEpisodeID: nil) {
            try? await store.replacePodcastQueue(state)
        }
        await refreshPodcastQueueState()
        await reloadLibraryRows()
    }

    private func markDownloaded(_ id: ItemID, mediaURL: URL, in store: LocalLibraryStore) async {
        guard let download = try? PodcastDownload(
            episodeID: id, status: .completed, bytesReceived: 1, expectedByteCount: 1,
            localURL: mediaURL, contentHash: "sha256:" + String(repeating: "7", count: 64),
            updatedAt: Timestamp(Date())) else { return }
        try? await store.save(download: download)
    }

    /// A flat tinted square, written once into the fixture's own media
    /// directory, so rows and the pane draw real artwork without the network.
    func larderDemoArtworkURL() -> URL? {
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let url = mediaDirectory.appendingPathComponent("larder-demo-artwork.png")
        let side = 600
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSColor(calibratedRed: 0.50, green: 0.83, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 150, y: 150, width: 300, height: 300)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
#endif
