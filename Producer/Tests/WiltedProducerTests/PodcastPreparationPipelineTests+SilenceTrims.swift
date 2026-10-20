import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// Long pauses come out of the prepared audio, but they are not
/// advertisements: the decoder accepts them only beside an honest ad report,
/// keeps them out of every ad figure, and resumes a listener inside one where
/// the speech does.
extension PodcastPreparationPipelineTests {
    private static func interval(_ start: Double, _ end: Double) -> [String: Any] {
        ["startSeconds": start, "endSeconds": end]
    }

    private static func keep(_ start: Double, _ end: Double, at output: Double) -> [String: Any] {
        ["startSeconds": start, "endSeconds": end, "outputStartSeconds": output]
    }

    /// Four tone bursts in a 16.5 second episode: every pause is cut to half a
    /// second and the leading and trailing silence go entirely.
    private static func silenceOnlyResponse() -> [String: Any] {
        ["ok": true, "protocolVersion": 2, "timing": "none", "audioPath": "/tmp/trimmed.mp3",
         "audioChanged": true, "durationSeconds": 5.5, "removedSeconds": 0.0,
         "adSegments": [[String: Any]](),
         "keepIntervals": [keep(1.5, 2.75, at: 0), keep(4.25, 5.75, at: 1.25),
                           keep(7.25, 8.75, at: 2.75), keep(10.25, 11.5, at: 4.25)],
         "silenceTrims": [interval(0, 1.5), interval(2.75, 4.25), interval(5.75, 7.25),
                          interval(8.75, 10.25), interval(11.5, 16.5)],
         "report": ["outcome": "noAds", "rawNominations": [[String: Any]](), "audit": WorkerStub.cleanAudit()]]
    }

    /// One advertisement at 20-40 s of a minute, with a pause on each side of
    /// it and silence to the end.
    private static func adsAndSilenceResponse() -> [String: Any] {
        let ad: [String: Any] = ["startSeconds": 20.0, "endSeconds": 40.0, "label": "host read", "confidence": 0.9]
        return ["ok": true, "protocolVersion": 2, "timing": "none", "audioPath": "/tmp/cut.mp3",
                "audioChanged": true, "durationSeconds": 33.0, "removedSeconds": 20.0,
                "adSegments": [ad],
                "keepIntervals": [keep(0, 18.25, at: 0), keep(40.75, 50.25, at: 18.25), keep(51.75, 57, at: 27.75)],
                "silenceTrims": [interval(18.25, 20), interval(40, 40.75), interval(50.25, 51.75), interval(57, 60)],
                "report": ["outcome": "cut", "rawNominations": [ad], "audit": WorkerStub.cleanAudit()]]
    }

    private static func decodeSilence(_ response: [String: Any]) throws -> PodcastPreparationPipeline.WorkerPayload {
        try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: response))
    }

    @Test func acceptsTrimmedPausesAsChangedAudioWithNoAdvertisement() throws {
        let payload = try Self.decodeSilence(Self.silenceOnlyResponse())
        #expect(payload.adRemovalOutcome == "noAds")
        #expect(payload.audioChanged)
        #expect(payload.adSegments.isEmpty && payload.removedSeconds == 0)
        #expect(payload.timeline.removed.isEmpty && payload.timeline.kept.count == 4)
        #expect(payload.silenceTrims == [0..<1.5, 2.75..<4.25, 5.75..<7.25, 8.75..<10.25, 11.5..<16.5])
    }

    @Test func keepsTrimmedPausesOutOfTheAdvertisementFigures() throws {
        let payload = try Self.decodeSilence(Self.adsAndSilenceResponse())
        #expect(payload.adRemovalOutcome == "cut")
        #expect(payload.adSegments.map { $0.startSeconds..<$0.endSeconds } == [20..<40])
        #expect(payload.removedSeconds == 20)
        #expect(payload.timeline.removed.map { $0.originalStartSeconds..<$0.originalEndSeconds } == [20..<40])
        #expect(payload.silenceTrims.count == 4)

        let progress = PodcastPreparationPipeline.resultProgress(payload)
        #expect(progress.evidence?.fields["advertisements"] == "1")
        #expect(progress.evidence?.fields["removedSeconds"] == "20.000")
        #expect(progress.evidence?.fields["silenceRemovedSeconds"] == "7.000")
        #expect(progress.detail.hasSuffix("· 7.0s of pauses removed"))
    }

    @Test func aWorkerWithoutSilenceTrimmingDecodesAsBefore() throws {
        var response = Self.adsAndSilenceResponse()
        response["silenceTrims"] = nil
        response["keepIntervals"] = [Self.keep(0, 20, at: 0), Self.keep(40, 60, at: 20)]
        let payload = try Self.decodeSilence(response)
        #expect(payload.silenceTrims.isEmpty)
        #expect(PodcastPreparationPipeline.resultProgress(payload).evidence?.fields["silenceRemovedSeconds"] == nil)
    }

    @Test func refusesTrimmedPausesThatDoNotMatchTheReport() throws {
        var cases: [(String, [String: Any])] = []
        var missing = Self.silenceOnlyResponse()
        missing["silenceTrims"] = nil
        cases.append(("changed noAds audio with nothing trimmed", missing))
        var counted = Self.silenceOnlyResponse()
        counted["removedSeconds"] = 9.0
        cases.append(("pauses counted as removed advertising", counted))
        var shifted = Self.silenceOnlyResponse()
        shifted["silenceTrims"] = [Self.interval(0, 1.5), Self.interval(2.75, 4.0), Self.interval(5.75, 7.25),
                                   Self.interval(8.75, 10.25), Self.interval(11.5, 16.5)]
        cases.append(("a pause that leaves part of a gap unexplained", shifted))
        var overlapping = Self.adsAndSilenceResponse()
        overlapping["silenceTrims"] = [Self.interval(18.25, 25), Self.interval(40, 40.75),
                                       Self.interval(50.25, 51.75), Self.interval(57, 60)]
        cases.append(("a pause overlapping an advertisement", overlapping))
        var unchanged = Self.silenceOnlyResponse()
        unchanged["audioChanged"] = false
        unchanged["keepIntervals"] = [[String: Any]]()
        cases.append(("pauses reported on unchanged audio", unchanged))
        var disabled = unchanged
        disabled["report"] = ["outcome": "disabled", "rawNominations": [[String: Any]]()]
        cases.append(("pauses reported with ad removal disabled", disabled))
        for (name, response) in cases {
            #expect(throws: PodcastPreparationError.malformedWorkerResponse("inconsistent ad-removal report"),
                    "\(name)") { _ = try Self.decodeSilence(response) }
        }
    }

    @Test func refusesTrimmedPausesBesideAnUncertainResult() throws {
        let warning = "original audio includes ads: classifier could not resolve IDs 0"
        var audit = WorkerStub.cleanAudit()
        audit["unresolvedIds"] = [0]
        audit["incompleteError"] = "classifier could not resolve IDs 0"
        audit["warning"] = warning
        audit["heldSpans"] = [[String: Any]]()
        audit["declinedCommercialEvidenceSeeds"] = [[String: Any]]()
        var response: [String: Any] = [
            "ok": true, "protocolVersion": 2, "timing": "none", "audioPath": "/tmp/original.mp3",
            "audioChanged": false, "durationSeconds": 16.5, "removedSeconds": 0.0,
            "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
            "report": ["outcome": "uncertain", "rawNominations": [[String: Any]](), "warning": warning, "audit": audit]
        ]
        #expect(try Self.decodeSilence(response).adRemovalOutcome == "uncertain")
        // W-INV-013: an uncertain result keeps the whole original.
        response["silenceTrims"] = [Self.interval(11.5, 16.5)]
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("inconsistent ad-removal report")) {
            _ = try Self.decodeSilence(response)
        }
    }

    @Test func refusesMalformedSilenceIntervals() throws {
        let malformed: [Any] = [
            [Self.interval(2, 1)], [Self.interval(-1, 1)], [Self.interval(5, 6), Self.interval(1, 2)],
            [["startSeconds": "0", "endSeconds": 1.0]]
        ]
        for value in malformed {
            var response = Self.silenceOnlyResponse()
            response["silenceTrims"] = value
            #expect(throws: PodcastPreparationError.malformedWorkerResponse("malformed silence interval")) {
                _ = try Self.decodeSilence(response)
            }
        }
        var tooMany = Self.silenceOnlyResponse()
        tooMany["silenceTrims"] = (0..<1_026).map { Self.interval(Double($0), Double($0) + 0.5) }
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("too many silence intervals")) {
            _ = try Self.decodeSilence(tooMany)
        }
        var notAList = Self.silenceOnlyResponse()
        notAList["silenceTrims"] = "0-1.5"
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("malformed silenceTrims")) {
            _ = try Self.decodeSilence(notAList)
        }
    }

    /// Two touching advertisements were refused before pauses existed; a
    /// pause must not become a way to make them pass.
    @Test func stillRefusesTwoTouchingAdvertisementsInOneGap() throws {
        let first: [String: Any] = ["startSeconds": 20.0, "endSeconds": 30.0, "label": "one", "confidence": 0.9]
        let second: [String: Any] = ["startSeconds": 30.0, "endSeconds": 40.0, "label": "two", "confidence": 0.9]
        var response = Self.adsAndSilenceResponse()
        response["adSegments"] = [first, second]
        response["report"] = ["outcome": "cut", "rawNominations": [first, second], "audit": WorkerStub.cleanAudit()]
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("inconsistent ad-removal report")) {
            _ = try Self.decodeSilence(response)
        }
    }

    @Test func aPositionInsideATrimmedPauseResumesWhereTheSpeechDoes() throws {
        let payload = try Self.decodeSilence(Self.silenceOnlyResponse())
        let keeps = payload.keepIntervals
        let silence = payload.silenceTrims
        #expect(PodcastKeepInterval.map(0.5, through: keeps, silence: silence) == 0)
        #expect(PodcastKeepInterval.map(3.0, through: keeps, silence: silence) == 1.25)
        #expect(PodcastKeepInterval.map(2.0, through: keeps, silence: silence) == 0.5)
        #expect(PodcastKeepInterval.map(14.0, through: keeps, silence: silence) == 5.5)
        // Without the pauses a gap reads as a removed ad, as it always has.
        #expect(PodcastKeepInterval.map(3.0, through: keeps) == nil)

        let cut = try Self.decodeSilence(Self.adsAndSilenceResponse())
        #expect(PodcastKeepInterval.map(19.0, through: cut.keepIntervals, silence: cut.silenceTrims) == 18.25)
        #expect(PodcastKeepInterval.map(30.0, through: cut.keepIntervals, silence: cut.silenceTrims) == nil)
    }

    /// The prepared revision replaces the download, the timeline lists no
    /// advertisement, and a listener parked in a pause resumes at the speech.
    @Test func preparesAnEpisodeWhoseOnlyChangeIsShorterPauses() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(playback: try PlaybackState(
            itemID: fixture.episodeID, revisionID: fixture.revisionID, sessionID: "session-1", sequence: 4,
            positionSeconds: 5.5, durationSeconds: 12, completed: false, intent: .progress, deviceID: "mac-1",
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_150))
        ))
        let response: [String: Any] = [
            "ok": true, "timing": "none", "audioChanged": true, "durationSeconds": 8.0, "removedSeconds": 0.0,
            "adSegments": [[String: Any]](),
            "keepIntervals": [Self.keep(1, 4.75, at: 0), Self.keep(6.75, 11, at: 3.75)],
            "silenceTrims": [Self.interval(0, 1), Self.interval(4.75, 6.75), Self.interval(11, 12)],
            "report": ["outcome": "noAds", "rawNominations": [[String: Any]](), "audit": WorkerStub.cleanAudit()]
        ]
        let worker = WorkerStub(response: response, writesCutAudio: Data("trimmed-audio-bytes".utf8))
        let result = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID)

        #expect(result.revision.revisionID != fixture.revisionID)
        #expect(result.adSegments.isEmpty && result.removedSeconds == 0)
        let carried = try #require(try await fixture.store.playbackState(for: fixture.episodeID,
                                                                        revisionID: result.revision.revisionID))
        #expect(carried.positionSeconds == 3.75)
        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        let evidence = try #require(entries.first { $0.id.contains("|pipeline.result#") }?.status.evidence)
        #expect(evidence.fields["adRemovalOutcome"] == "noAds")
        #expect(evidence.fields["advertisements"] == "0")
        #expect(evidence.fields["silenceRemovedSeconds"] == "4.000")
        let terminal = try #require(entries.last { $0.status.terminal })
        #expect(terminal.status.timeline?.removed.isEmpty == true)
        #expect(terminal.status.timeline?.kept.count == 2)
        #expect(terminal.status.detail == "Ready · no ads found · transcript not synced")
    }

    @Test func realPythonSilenceResponsesDecodeUnderTheSwiftContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let python = ProcessInfo.processInfo.environment["WILTED_PIPELINE_PYTHON"]
            ?? "/opt/homebrew/opt/python@3.15/bin/python3.15"
        process.arguments = ["-u", "PYTHONPATH", python, "-B", "-c",
                             "import json; from test_silence_trim import silence_contract_payloads; print(json.dumps(silence_contract_payloads()))"]
        process.currentDirectoryURL = root.appendingPathComponent("Producer/Workers")
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "Python silence contract failed: \(String(decoding: errorBytes, as: UTF8.self))")
        let entries = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        #expect(entries.compactMap { $0["scenario"] as? String } == ["silence-only", "ads-and-silence"])
        var payloads: [PodcastPreparationPipeline.WorkerPayload] = []
        for entry in entries {
            let response = try #require(entry["payload"] as? [String: Any])
            payloads.append(try Self.decodeSilence(response))
        }
        let silenceOnly = try #require(payloads.first)
        #expect(silenceOnly.adRemovalOutcome == "noAds" && silenceOnly.audioChanged)
        #expect(silenceOnly.adSegments.isEmpty && silenceOnly.removedSeconds == 0)
        #expect(silenceOnly.silenceTrims.count == 5)
        let withAds = try #require(payloads.last)
        #expect(withAds.adRemovalOutcome == "cut")
        #expect(withAds.adSegments.map { $0.startSeconds..<$0.endSeconds } == [20..<40])
        #expect(withAds.removedSeconds == 20)
        #expect(withAds.silenceTrims.count == 4)
    }
}
