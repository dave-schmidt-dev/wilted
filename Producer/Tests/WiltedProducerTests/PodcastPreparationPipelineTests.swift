import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Podcast preparation pipeline")
struct PodcastPreparationPipelineTests {
    @Test func refusesToPrepareAnEpisodeThatIsNotDownloaded() async throws {
        let fixture = try await Fixture(installDownload: false)
        defer { fixture.remove() }
        await #expect(throws: PodcastPreparationError.episodeNotDownloaded) {
            _ = try await fixture.pipeline(WorkerStub(response: [:])).prepare(episodeID: fixture.episodeID)
        }
    }

    /// The transcript the feed publishes is preferred, arrives already timed,
    /// and is handed to the worker as text rather than as a URL.
    @Test func fetchesThePublishedTranscriptAndKeepsItsTiming() async throws {
        let fixture = try await Fixture(publishesTranscript: true)
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "published", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "text": "Welcome back. Today we talk about latency.",
            "languageCode": "en",
            "cues": [["startSeconds": 0.0, "endSeconds": 2.5, "text": "Welcome back."],
                     ["startSeconds": 2.5, "endSeconds": 6.0, "text": "Today we talk about latency."]],
        ])

        let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)

        let requestData = try #require(await stub.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let published = try #require(request["publishedTranscript"] as? [String: Any])
        #expect(published["mediaType"] as? String == "text/vtt")
        #expect((published["body"] as? String)?.contains("WEBVTT") == true)
        #expect(request["audioPath"] as? String == fixture.audioURL.path)
        #expect(result.transcript.timing == .published)
        #expect(result.transcript.cues?.count == 2)
        #expect(result.revision.revisionID == fixture.revisionID)
        #expect(result.audioWasCut == false)

        let stored = try #require(try await fixture.store.transcript(for: fixture.episodeID, revisionID: fixture.revisionID))
        #expect(stored.cues?.last?.text == "Today we talk about latency.")
        #expect(stored.schemaVersion == 2)
    }

    /// An unreachable transcript document is a downgrade, not a failure: the
    /// worker still runs and falls through to speech-to-text.
    @Test func continuesWithoutThePublishedTranscriptWhenItCannotBeFetched() async throws {
        let fixture = try await Fixture(publishesTranscript: true, transcriptStatusCode: 404)
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "aligned", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "text": "Spoken words.", "cues": [["startSeconds": 0.0, "endSeconds": 1.0, "text": "Spoken words."]],
        ])
        let statuses = StatusLog()

        let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID) { progress in
            statuses.append(progress.stage)
        }

        let sentData = try #require(await stub.lastRequest())
        let sent = try #require(try JSONSerialization.jsonObject(with: sentData) as? [String: Any])
        #expect(sent["publishedTranscript"] == nil)
        #expect(statuses.stages.contains("transcript.published.unreadable"))
        #expect(result.transcript.timing == .aligned)
    }

    /// The whole point of the pipeline: cut audio is different audio, so it
    /// takes a new revision identity, replaces the download, and the remapped
    /// cues bind to the revision they actually describe.
    @Test func cutAudioBecomesANewRevisionThatTheTranscriptBindsTo() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let cutBody = Data("shorter-audio-bytes".utf8)
        let stub = WorkerStub(response: [
            "ok": true, "timing": "aligned", "audioChanged": true, "durationSeconds": 7.5,
            "text": "Kept words.", "cues": [["startSeconds": 0.0, "endSeconds": 3.0, "text": "Kept words."]],
            "removedSeconds": 4.5,
            "adSegments": [["startSeconds": 3.0, "endSeconds": 7.5, "label": "host read", "confidence": 0.91]],
        ], writesCutAudio: cutBody)

        let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)

        let expectedID = try RevisionID.derive(downloadedAudioContentHash: Fixture.contentHash(cutBody))
        #expect(result.revision.revisionID == expectedID)
        #expect(result.revision.revisionID != fixture.revisionID)
        #expect(result.revision.durationSeconds == 7.5)
        #expect(result.revision.byteCount == Int64(cutBody.count))
        #expect(result.removedSeconds == 4.5)
        #expect(result.adSegments.first?.label == "host read")
        #expect(result.transcript.revisionID == expectedID)

        #expect(try Data(contentsOf: result.mediaURL) == cutBody)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path) == false)
        let download = try #require(try await fixture.store.download(for: fixture.episodeID))
        #expect(download.localURL == result.mediaURL)
        #expect(download.contentHash == result.revision.contentHash)
        let ready = try #require(try await fixture.store.readyRevision(for: fixture.episodeID, revisionID: expectedID))
        #expect(ready.mediaURL == result.mediaURL)
    }

    @Test func reportsWorkerFailuresAndUnreadableResults() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await #expect(throws: PodcastPreparationError.workerFailed(code: "stt-unavailable", message: "daemon down")) {
            _ = try await fixture.pipeline(WorkerStub(response: [
                "ok": false, "code": "stt-unavailable", "message": "daemon down",
            ])).prepare(episodeID: fixture.episodeID)
        }
        await #expect(throws: PodcastPreparationError.malformedWorkerResponse("no audioPath")) {
            _ = try await fixture.pipeline(WorkerStub(response: ["ok": true, "timing": "none"]))
                .prepare(episodeID: fixture.episodeID)
        }
    }

    /// A worker that claims it cut the audio but leaves nothing behind must not
    /// be believed into a revision that points at a missing file.
    @Test func rejectsCutAudioThatIsNotOnDisk() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "none", "audioChanged": true,
            "audioPath": fixture.workDirectory.appendingPathComponent("absent.mp3").path,
        ])
        await #expect(throws: PodcastPreparationError.preparedAudioUnreadable) {
            _ = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    // MARK: Transcript construction

    @Test func recordsAnAbsentTranscriptWhenTheWorkerFoundNoWords() throws {
        let transcript = try PodcastPreparationPipeline.transcript(
            from: Self.payload(text: nil), itemID: Self.itemID, revisionID: Self.revisionID,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(transcript.availability == .absent)
        #expect(transcript.timing == TranscriptTiming.none)
    }

    @Test func recordsOversizedRatherThanDiscardingAnEpisode() throws {
        let huge = String(repeating: "a ", count: Transcript.maximumTextUTF8Bytes)
        let transcript = try PodcastPreparationPipeline.transcript(
            from: Self.payload(text: huge), itemID: Self.itemID, revisionID: Self.revisionID,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(transcript.availability == .oversized)
        #expect(transcript.text == nil)
    }

    /// Timing that will not fit costs the timing, never the words.
    @Test func keepsTheWordsWhenTheCuesExceedTheTransportBudget() throws {
        let cues = try (0..<(Transcript.maximumCueCount + 10)).map {
            try TranscriptCue(startSeconds: Double($0), endSeconds: Double($0) + 1, text: "cue \($0)")
        }
        var payload = Self.payload(text: "Words that fit.")
        payload.timing = .aligned
        payload.cues = cues
        let transcript = try PodcastPreparationPipeline.transcript(
            from: payload, itemID: Self.itemID, revisionID: Self.revisionID,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(transcript.availability == .available)
        #expect(transcript.text == "Words that fit.")
        #expect(transcript.timing == TranscriptTiming.none)
        #expect(transcript.cues == nil)
    }

    // MARK: Subprocess runner

    /// Exercises the real process plumbing with a shell script standing in for
    /// the Python worker, so stdin delivery, NDJSON progress, and result
    /// collection are covered by the gate without a virtualenv or a model.
    @Test func subprocessRunnerStreamsProgressAndReturnsTheResult() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("worker.sh")
        try """
        #!/bin/sh
        printf '{"stage":"one","detail":"first","fraction":0.25}\\n' >&2
        printf 'not json at all\\n' >&2
        printf '{"stage":"two","detail":"second"}\\n' >&2
        request=$(cat)
        printf '{"ok":true,"echo":%s}' "$request"
        """.write(to: worker, atomically: true, encoding: .utf8)

        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 30
        ))
        let statuses = StatusLog()
        let output = try await runner.run(request: Data(#"{"audioPath":"/tmp/a.mp3"}"#.utf8)) { progress in
            statuses.append(progress.stage, detail: progress.detail, fraction: progress.fraction)
        }

        let decoded = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(decoded["ok"] as? Bool == true)
        #expect((decoded["echo"] as? [String: Any])?["audioPath"] as? String == "/tmp/a.mp3")
        #expect(statuses.stages == ["one", "two"])
        #expect(statuses.fractions.first == 0.25)
    }

    @Test func subprocessRunnerReportsAWorkerThatProducesNothing() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("silent.sh")
        try "#!/bin/sh\nexit 3\n".write(to: worker, atomically: true, encoding: .utf8)
        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 30
        ))
        await #expect(throws: PodcastPreparationError.self) {
            _ = try await runner.run(request: Data("{}".utf8)) { _ in }
        }
    }

    @Test func subprocessRunnerRefusesToStartWithoutItsPieces() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: directory.appendingPathComponent("no-python").path),
            workerURL: directory.appendingPathComponent("worker.py")
        ))
        await #expect(throws: PodcastPreparationError.self) {
            _ = try await missing.run(request: Data("{}".utf8)) { _ in }
        }
    }

    /// Every path is overridable, and the shipped defaults name real things.
    @Test func configurationResolvesFromTheEnvironment() {
        let overridden = SubprocessPodcastPipelineRunner.Configuration.resolved(environment: [
            "WILTED_PIPELINE_PYTHON": "/opt/py", "WILTED_PIPELINE_WORKER": "/opt/w.py",
            "WILTED_PIPELINE_PYTHONPATH": "/opt/src", "WILTED_PIPELINE_TIMEOUT_S": "60",
        ])
        #expect(overridden.interpreterURL.path == "/opt/py")
        #expect(overridden.workerURL.path == "/opt/w.py")
        #expect(overridden.pythonPath?.path == "/opt/src")
        #expect(overridden.timeout == 60)

        let defaults = SubprocessPodcastPipelineRunner.Configuration.resolved(environment: [:])
        #expect(defaults.workerURL.lastPathComponent == "wilted_pipeline.py")
        #expect(defaults.timeout > 0)
    }

    // MARK: Fixtures

    private static let itemID = try! ItemID(rawValue: "item-" + String(repeating: "4", count: 64))
    private static let revisionID = try! RevisionID.derive(downloadedAudioContentHash: Fixture.contentHash(Data("x".utf8)))

    private static func payload(text: String?) -> PodcastPreparationPipeline.WorkerPayload {
        PodcastPreparationPipeline.WorkerPayload(
            timing: .none, cues: [], text: text, languageCode: "en",
            audioPath: "/tmp/a.mp3", audioChanged: false, durationSeconds: nil,
            adSegments: [], removedSeconds: 0
        )
    }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, String, Double?)] = []

    func append(_ stage: String, detail: String = "", fraction: Double? = nil) {
        lock.lock(); recorded.append((stage, detail, fraction)); lock.unlock()
    }

    var stages: [String] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.0) }
    var fractions: [Double] { lock.lock(); defer { lock.unlock() }; return recorded.compactMap(\.2) }
}

/// Stands in for the Python worker, and records what it was asked to do.
private actor WorkerStub: PodcastPipelineRunning {
    private let response: [String: Any]
    private let writesCutAudio: Data?
    private var request: Data?

    init(response: [String: Any], writesCutAudio: Data? = nil) {
        self.response = response
        self.writesCutAudio = writesCutAudio
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
        onProgress(PodcastPreparationProgress(stage: "worker.start"))
        var answer = response
        if let body = writesCutAudio, let outputPath = decoded["outputPath"] as? String {
            try body.write(to: URL(fileURLWithPath: outputPath))
            answer["audioPath"] = outputPath
        }
        return try JSONSerialization.data(withJSONObject: answer)
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

private struct Fixture {
    let root: URL
    let libraryDirectory: URL
    let workDirectory: URL
    let store: LocalLibraryStore
    let episodeID: ItemID
    let revisionID: RevisionID
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
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))

        let body = Data("original-audio-bytes".utf8)
        let hash = Fixture.contentHash(body)
        revisionID = try RevisionID.derive(downloadedAudioContentHash: hash)
        let audioDirectory = libraryDirectory.appendingPathComponent("PodcastAudio", isDirectory: true)
            .appendingPathComponent(episodeID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        audioURL = audioDirectory.appendingPathComponent(revisionID.rawValue + ".mp3")
        guard installDownload else { return }
        try body.write(to: audioURL)
        try await store.finalizePodcastDownload(
            revision: try AudioRevision(
                itemID: episodeID, revisionID: revisionID, durationSeconds: 12,
                byteCount: Int64(body.count), contentHash: hash, mediaType: "audio/mpeg",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)), schemaVersion: 3
            ),
            mediaURL: audioURL,
            download: try PodcastDownload(
                episodeID: episodeID, status: .completed, bytesReceived: Int64(body.count),
                expectedByteCount: Int64(body.count), localURL: audioURL, contentHash: hash,
                updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
            )
        )
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
