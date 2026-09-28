import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

extension PodcastPreparationPipelineTests {
    // MARK: Fixtures

    static let itemID = try! ItemID(rawValue: "item-" + String(repeating: "4", count: 64))
    static let revisionID = try! RevisionID.derive(downloadedAudioContentHash: Fixture.contentHash(Data("x".utf8)))

    static func payload(text: String?) -> PodcastPreparationPipeline.WorkerPayload {
        PodcastPreparationPipeline.WorkerPayload(
            timing: .none, cues: [], text: text, languageCode: "en",
            audioPath: "/tmp/a.mp3", audioChanged: false, durationSeconds: nil,
            adSegments: [], removedSeconds: 0, keepIntervals: [],
            adRemovalOutcome: "disabled",
            timeline: try! PreparationStatus.PreparationTimeline(removed: [], kept: [])
        )
    }
}

final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, String, Double?)] = []

    func append(_ stage: String, detail: String = "", fraction: Double? = nil) {
        lock.lock(); recorded.append((stage, detail, fraction)); lock.unlock()
    }

    var stages: [String] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.0) }
    var fractions: [Double] { lock.lock(); defer { lock.unlock() }; return recorded.compactMap(\.2) }
}

/// Stands in for the Python worker, and records what it was asked to do.
actor WorkerStub: PodcastPipelineRunning {
    private let response: [String: Any]
    private let writesCutAudio: Data?
    private let progress: [PodcastPreparationProgress]
    private var request: Data?

    init(response: [String: Any], writesCutAudio: Data? = nil,
         progress: [PodcastPreparationProgress] = [PodcastPreparationProgress(stage: "worker.start")]) {
        self.response = response
        self.writesCutAudio = writesCutAudio
        self.progress = progress
    }

    /// A function, not a stored property: `[String: Any]` is not `Sendable`,
    /// so a static constant of it is a concurrency error.
    static func cleanAudit() -> [String: Any] {
        ["classifierRequests": 3, "classifierValidRequests": 3, "classifierInvalidRequests": 0,
         "exhaustedSingletonLineages": 0, "modelRequests": 3, "modelFailures": 0,
         "experimentalRequests": 0, "unresolvedIds": [Int](), "candidates": [[String: Any]](),
         "incompleteError": NSNull()]
    }

    /// Returned as bytes: a decoded `[String: Any]` cannot cross the actor
    /// boundary, and the caller wants to inspect it anyway.
    func lastRequest() -> Data? { request }

    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
        request = payload
        progress.forEach(onProgress)
        var answer = response
        answer["protocolVersion"] = decoded["protocolVersion"] as? Int ?? 2
        if answer["ok"] as? Bool == true, answer["report"] == nil {
            let changed = (answer["audioChanged"] as? Bool) ?? (writesCutAudio != nil)
            let removeAds = decoded["removeAds"] as? Bool ?? true
            let outcome = !removeAds ? "disabled" : (changed ? "cut" : "noAds")
            var report: [String: Any] = ["outcome": outcome,
                                         "rawNominations": answer["adSegments"] as? [[String: Any]] ?? []]
            // A real worker cannot report that the detector ran without the
            // evidence that it did, so neither can the stub.
            if outcome != "disabled" { report["audit"] = WorkerStub.cleanAudit() }
            answer["report"] = report
        }
        if let body = writesCutAudio, let outputPath = decoded["outputPath"] as? String {
            try body.write(to: URL(fileURLWithPath: outputPath))
            answer["audioPath"] = outputPath
        }
        return try JSONSerialization.data(withJSONObject: answer)
    }
}

/// A worker that lets a test look at the store mid-run, then fails.
actor ProbingWorker: PodcastPipelineRunning {
    private let probe: @Sendable () async throws -> Void

    init(probe: @escaping @Sendable () async throws -> Void) { self.probe = probe }

    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        onProgress(PodcastPreparationProgress(stage: "worker.start"))
        try await probe()
        throw PodcastPreparationError.workerUnavailable("probe")
    }
}

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

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func contentHash(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init(installDownload: Bool = true, publishesTranscript: Bool = false, transcriptStatusCode: Int = 200) async throws {
        root = try Fixture.temporaryDirectory()
        libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        workDirectory = root.appendingPathComponent("Work", isDirectory: true)
        for directory in [libraryDirectory, workDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.transcriptStatusCode = transcriptStatusCode
        store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))

        let feedURL = try #require(URL(string: "https://feeds.example.test/show.xml"))
        let enclosureURL = try #require(URL(string: "https://cdn.example.test/e1.mp3"))
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

        let body = Data("original-audio-bytes".utf8)
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
    static func cuttingStub() -> some PodcastPipelineRunning {
        WorkerStub(response: cuttingStubResponse(), writesCutAudio: cuttingAudio)
    }

    static let cuttingAudio = Data("shorter-audio-bytes".utf8)

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

    func pipeline(_ runner: some PodcastPipelineRunning) -> PodcastPreparationPipeline {
        PodcastPreparationPipeline(
            store: store, workDirectory: workDirectory, runner: runner,
            documentLoader: TranscriptDocumentLoader(statusCode: transcriptStatusCode),
            now: { Date(timeIntervalSince1970: 1_700_000_200) }
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
}
