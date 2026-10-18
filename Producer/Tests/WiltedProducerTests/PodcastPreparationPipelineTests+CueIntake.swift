import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

extension PodcastPreparationPipelineTests {
    private static func cueResponseData(cues: [[String: Any]]) throws -> Data {
        let object: [String: Any] = [
            "ok": true,
            "protocolVersion": 2,
            "timing": "aligned",
            "audioPath": "/tmp/a.mp3",
            "audioChanged": false,
            "report": [
                "outcome": "disabled",
                "rawNominations": []
            ],
            "cues": cues
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func decodesValidCuesAndCountsSingleMalformedCue() throws {
        let cues: [[String: Any]] = [
            ["startSeconds": 0.0, "endSeconds": 2.5, "text": "First valid cue.", "speaker": "Host"],
            ["startSeconds": 5.0, "endSeconds": 2.0, "text": "Malformed cue with inverted time."],
            ["startSeconds": 5.0, "endSeconds": 8.0, "text": "Second valid cue.", "speaker": "Guest"]
        ]
        let data = try Self.cueResponseData(cues: cues)
        let payload = try PodcastPreparationPipeline.decode(data)

        #expect(payload.droppedCueCount == 1)
        #expect(payload.cues.count == 2)
        #expect(payload.cues[0].text == "First valid cue.")
        #expect(payload.cues[0].speaker == "Host")
        #expect(payload.cues[1].text == "Second valid cue.")
        #expect(payload.cues[1].speaker == "Guest")
    }

    @Test func throwsMalformedWorkerResponseWhenDroppedCuesExceedThreshold() throws {
        var cues: [[String: Any]] = []
        for index in 0..<70 {
            cues.append([
                "startSeconds": Double(index * 2),
                "endSeconds": Double(index * 2 + 1),
                "text": "Valid cue \(index)"
            ])
        }
        for index in 70..<100 {
            cues.append([
                "startSeconds": Double(index * 2),
                "endSeconds": Double(index * 2 - 1),
                "text": "Invalid cue \(index)"
            ])
        }
        #expect(cues.count == 100)
        let data = try Self.cueResponseData(cues: cues)
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("30 of 100 transcript cues were malformed")) {
            _ = try PodcastPreparationPipeline.decode(data)
        }
    }

    @Test func prepareReportsAndJournalsDroppedCuesStatus() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        var response = Fixture.cuttingStubResponse()
        response["cues"] = [
            ["startSeconds": 0.0, "endSeconds": 3.0, "text": "Kept words."],
            ["startSeconds": 4.0, "endSeconds": 2.0, "text": "Malformed cue with inverted time."]
        ]
        let stub = WorkerStub(response: response, writesCutAudio: Fixture.cuttingAudio)
        let statusLog = StatusLog()

        let result = try await fixture.pipeline(stub).prepare(
            episodeID: fixture.episodeID,
            onStatus: { progress in
                statusLog.append(progress.stage, detail: progress.detail, fraction: progress.fraction)
            }
        )
        #expect(result.summary.contains("Ready"))

        // Reported via onStatus
        #expect(statusLog.stages.contains("transcript.cues.dropped"))
        let reported = statusLog.entries.first { $0.stage == "transcript.cues.dropped" }
        #expect(reported?.detail == "1 of 2 transcript cues were malformed and left out")

        // Journaled to the persistent store
        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        )
        let journaled = entries.first { $0.status.step == "transcript.cues.dropped" }
        let droppedStatus = try #require(journaled?.status)
        #expect(droppedStatus.step == "transcript.cues.dropped")
        #expect(droppedStatus.stage == .extracting)
        #expect(droppedStatus.detail == "1 of 2 transcript cues were malformed and left out")
    }
}
