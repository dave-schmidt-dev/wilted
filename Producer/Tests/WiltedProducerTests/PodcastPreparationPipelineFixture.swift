import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

private struct TranscriptDocumentLoader: PodcastFeedLoading {
    let statusCode: Int
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(
            url: url, statusCode: statusCode,
            data: Data("WEBVTT\n\n00:00:00.000 --> 00:00:02.500\nWelcome back.\n".utf8)
        )
    }
}

extension PodcastPreparationPipelineTests {
struct Fixture {
    let root: URL
    let libraryDirectory: URL
    let workDirectory: URL
    let store: LocalLibraryStore
    let episodeID: ItemID
    let revisionID: RevisionID
    let contentHash: String
    let audioURL: URL
    let transcriptStatusCode: Int
    /// Set for a labelled fixture: switch on, a key present, the fixture's
    /// feed confirmed, and a provider that labels the span the fake worker
    /// cuts. Nil reads as the switch being off, so ad removal is not sent.
    let labelling: PodcastLabellingServices?
    let sender: MarkedCueLabellerSender?
    private let defaultsName: String?

    /// The publisher's title every fixture saves by default: free of every word
    /// the private-title check refuses, as the feed and audio addresses are
    /// free of sign-in details and token-like parts.
    static let labelledShowTitle = "Invented Garden Show"
    /// The feed address every fixture saves by default.
    static let feedAddress = "https://feeds.example.test/show.xml"

    static func temporaryDirectory() throws -> URL {
        let url = OwnedTestTemp.root
            .appendingPathComponent("wilted-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func contentHash(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `feedAddress` and `showTitle` set the saved feed; a nil `showTitle`
    /// saves no feed record, so the show's address is unknown.
    init(installDownload: Bool = true, publishesTranscript: Bool = false, transcriptStatusCode: Int = 200,
         labelled: Bool = false, feedAddress: String = Fixture.feedAddress,
         showTitle: String? = Fixture.labelledShowTitle,
         enclosureAddress: String = "https://cdn.example.test/e1.mp3") async throws {
        root = try Fixture.temporaryDirectory()
        libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        workDirectory = root.appendingPathComponent("Work", isDirectory: true)
        for directory in [libraryDirectory, workDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.transcriptStatusCode = transcriptStatusCode
        store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))

        let feedURL = try #require(URL(string: feedAddress))
        let enclosureURL = try #require(URL(string: enclosureAddress))
        episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "e1", enclosureURL: enclosureURL)
        var sources: [PodcastTranscriptSource] = []
        if publishesTranscript {
            sources = [try PodcastTranscriptSource(
                url: try #require(URL(string: "https://cdn.example.test/e1.vtt")),
                mediaType: "text/vtt", languageCode: "en", isCaptions: true
            )]
        }
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: try ItemID.derivePodcastFeed(from: feedURL), feedURL: feedURL,
            rssGUID: "e1", title: "Episode", enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
            enclosureByteCount: 19, transcriptSources: sources,
            notes: "Host: Leo Laporte (https://twit.tv/people/leo-laporte)",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        if let showTitle {
            try await store.save(feed: PodcastFeed(
                itemID: feedID, canonicalURL: feedURL, title: showTitle,
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))))
        }
        if labelled {
            let name = "PodcastPreparationPipelineTests.Fixture.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            let preferences = AdLabellerPreferences(preferences: defaults)
            preferences.isEnabled = true
            preferences.setConfirmed(feedID: feedID.rawValue, true)
            let sender = MarkedCueLabellerSender()
            self.sender = sender
            defaultsName = name
            labelling = PodcastLabellingServices(
                preferences: preferences, counter: LabellerRequestCounter(preferences: defaults),
                keyStore: InMemoryLabellerKeyStore(key: "invented-fixture-key-0123456789abcdef"), sender: sender)
        } else {
            sender = nil
            defaultsName = nil
            labelling = nil
        }

        let body = Fixture.originalBody
        contentHash = Fixture.contentHash(body)
        revisionID = try RevisionID.derive(downloadedAudioContentHash: contentHash)
        let audioDirectory = libraryDirectory.appendingPathComponent("PodcastAudio", isDirectory: true)
            .appendingPathComponent(episodeID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        audioURL = audioDirectory.appendingPathComponent(revisionID.rawValue + ".mp3")
        guard installDownload else { return }
        try body.write(to: audioURL)
        try await store.finalizePodcastDownload(
            revision: try AudioRevision(
                itemID: episodeID, revisionID: revisionID, durationSeconds: 12,
                byteCount: Int64(body.count), contentHash: contentHash, mediaType: "audio/mpeg",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)), schemaVersion: 3
            ),
            mediaURL: audioURL,
            download: try PodcastDownload(
                episodeID: episodeID, status: .completed, bytesReceived: Int64(body.count),
                expectedByteCount: Int64(body.count), localURL: audioURL, contentHash: contentHash,
                updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
            )
        )
    }

    /// A worker that removes 3.0-7.5 from a twelve second episode.
    static func cuttingStub(codeRevision: String? = nil) -> some PodcastPipelineRunning {
        WorkerStub(response: cuttingStubResponse(), writesCutAudio: cuttingAudio, codeRevision: codeRevision)
    }

    static let cuttingAudio = Data("shorter-audio-bytes".utf8)
    static let originalBody = Data("original-audio-bytes".utf8)

    static func cuttingStubResponse() -> [String: Any] {
        [
            "ok": true, "timing": "aligned", "audioChanged": true, "durationSeconds": 7.5,
            "text": "Kept words.", "cues": [["startSeconds": 0.0, "endSeconds": 3.0, "text": "Kept words."]],
            "removedSeconds": 4.5,
            "adSegments": [["startSeconds": 3.0, "endSeconds": 7.5, "label": "host read", "confidence": 0.91]],
            "keepIntervals": [["startSeconds": 0.0, "endSeconds": 3.0, "outputStartSeconds": 0.0],
                              ["startSeconds": 7.5, "endSeconds": 12.0, "outputStartSeconds": 3.0]],
        ]
    }

    /// A labelled cut stage that could not settle the breaks, so it keeps the
    /// whole original and says why.
    static func labelledUncertainResponse(audioPath: String) -> [String: Any] {
        let reason = "unresolved commercial spans"
        let warning = "original audio includes ads: \(reason)"
        return [
            "ok": true, "protocolVersion": 2, "timing": "none", "audioPath": audioPath, "audioChanged": false,
            "durationSeconds": 12.0, "removedSeconds": 0.0,
            "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
            "report": ["outcome": "uncertain", "rawNominations": [[String: Any]](), "warning": warning,
                       "audit": WorkerStub.labelledAudit(incompleteError: reason, warning: warning)],
        ]
    }

    /// A labelled fixture's pipeline carries its labelling services. Every
    /// fixture's worker refuses any ad-removal request that has no labelled stage.
    func pipeline(
        _ runner: some PodcastPipelineRunning,
        now: (@Sendable () -> Date)? = nil,
        appVersion: String? = PodcastPreparationBuildStamp.hostAppVersion(),
        engineVersion: String = PodcastPreparationPipeline.semanticVersion
    ) -> PodcastPreparationPipeline {
        PodcastPreparationPipeline(
            store: store, workDirectory: workDirectory, runner: LabelledOnlyRunner(base: runner),
            documentLoader: TranscriptDocumentLoader(statusCode: transcriptStatusCode),
            now: now ?? { Date(timeIntervalSince1970: 1_700_000_200) },
            appVersion: appVersion, engineVersion: engineVersion, labelling: labelling
        )
    }

    /// The provenance a labelled fixture's outcome is digested with.
    var labelledProvenance: LabelledRunProvenance? {
        labelling.map { PodcastPreparationPipeline.labelledRunProvenance(preferences: $0.preferences) }
    }

    /// Files the pipeline left in its labeller cue folder. It writes one only
    /// while a run waits for the provider and removes it when the run ends.
    func leftoverLabellerCueFiles() -> [String] {
        let directory = workDirectory.appendingPathComponent("labeller-cues", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// Fails a labelled test that leaves a labeller cue file behind, then
    /// removes everything the fixture made.
    func remove() {
        if labelling != nil {
            let leftover = leftoverLabellerCueFiles()
            if !leftover.isEmpty { Issue.record("labeller cue files left behind: \(leftover)") }
        }
        if let defaultsName { UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName) }
        try? FileManager.default.removeItem(at: root)
    }
}
}
