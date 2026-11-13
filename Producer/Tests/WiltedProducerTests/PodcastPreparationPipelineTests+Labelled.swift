import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

extension PodcastPreparationPipelineTests {
    static let labelledFeedURL = URL(string: "https://feeds.example.test/show.xml")!
    static let labelledFeedID = try! ItemID.derivePodcastFeed(from: labelledFeedURL)
    static let labelledShowTitle = "Invented Garden Show"
    static let labelledKey = "invented-key-0123456789abcdef"
    private static let localPolicyDigestPin =
        "sha256:aba0d63d8fa246707f5baeaf453159ccda1392c7fc912c7c3ba4edb968c311ca"

    private static let cueTexts = [
        "Welcome to the invented garden show.",
        "This break is brought to you by Fizzbolt.",
        "Fizzbolt makes invented widgets.",
        "Back to the show.",
    ]

    func makeDefaults() -> (UserDefaults, String) {
        let name = "PodcastPreparationPipelineTests.Labelled.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func saveFeed(in store: LocalLibraryStore, title: String = labelledShowTitle) async throws {
        try await store.save(feed: PodcastFeed(
            itemID: Self.labelledFeedID,
            canonicalURL: Self.labelledFeedURL,
            title: title,
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
    }

    func writeCueFile(
        to workDirectory: URL, extraCues: [LabellerCue] = []
    ) throws -> (path: String, digest: String, cues: [LabellerCue]) {
        let cues = [
            LabellerCue(id: 0, start: 0, end: 3, text: Self.cueTexts[0]),
            LabellerCue(id: 1, start: 3, end: 7.5, text: Self.cueTexts[1]),
            LabellerCue(id: 2, start: 7.5, end: 10, text: Self.cueTexts[2]),
            LabellerCue(id: 3, start: 10, end: 12, text: Self.cueTexts[3]),
        ] + extraCues
        let data = try JSONEncoder().encode(cues)
        let url = workDirectory.appendingPathComponent("labeller-cues.json")
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url.path, digest, cues)
    }

    private static func labelledAudit(
        proposed: Int, cut: Int, leftIn: [[String: Any]],
        held: [[String: Any]] = [],
        incompleteError: String? = nil,
        warning: String? = nil,
        modelID: String = AdLabellerPreferences.defaultModelID,
        level: String = AdLabellerPreferences.defaultLevel,
        promptVersion: String = EpisodeLabeller.promptVersion
    ) -> [String: Any] {
        return [
            "adEngine": "labelled",
            "breaksProposed": proposed,
            "breaksCut": cut,
            "breaksLeftIn": leftIn.count,
            "leftIn": leftIn,
            "labellerModelID": modelID,
            "labellerLevel": level,
            "labellerPromptVersion": promptVersion,
            "heldSpans": held,
            "incompleteError": incompleteError as Any? ?? NSNull(),
            "warning": warning as Any? ?? NSNull(),
            "unresolvedIds": [Int](),
            "modelRequests": 0,
            "modelFailures": 0,
            "experimentalRequests": 0,
            "classifierRequests": 0,
            "classifierValidRequests": 0,
            "classifierInvalidRequests": 0,
            "exhaustedSingletonLineages": 0,
            "candidates": [[String: Any]](),
            "declinedCommercialEvidenceSeeds": [[String: Any]](),
        ]
    }

    static func cutResponse(
        audioPath: String,
        leftIn: [[String: Any]] = [],
        cutCount: Int = 1
    ) -> [String: Any] {
        var response = Fixture.cuttingStubResponse()
        response["adStage"] = "cut"
        response["audioPath"] = audioPath
        let proposed = cutCount + leftIn.count
        response["report"] = [
            "outcome": "cut",
            "rawNominations": response["adSegments"] as? [[String: Any]] ?? [],
            "audit": labelledAudit(proposed: proposed, cut: cutCount, leftIn: leftIn),
        ]
        return response
    }

    static func noAdsCutResponse(audioPath: String) -> [String: Any] {
        [
            "ok": true, "adStage": "cut", "timing": "aligned", "audioPath": audioPath,
            "audioChanged": false, "durationSeconds": 12,
            "text": "No ads.", "cues": [["startSeconds": 0.0, "endSeconds": 12.0, "text": "No ads."]],
            "removedSeconds": 0, "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
            "report": [
                "outcome": "noAds",
                "rawNominations": [[String: Any]](),
                "audit": labelledAudit(proposed: 0, cut: 0, leftIn: []),
            ],
        ]
    }

    private static func shareCeilingResponse(audioPath: String) -> [String: Any] {
        let warning = "original audio includes ads: unresolved commercial spans"
        return [
            "ok": true, "adStage": "cut", "timing": "aligned", "audioPath": audioPath,
            "audioChanged": false, "durationSeconds": 12,
            "text": "Whole original.", "cues": [["startSeconds": 0.0, "endSeconds": 12.0, "text": "Whole."]],
            "removedSeconds": 0, "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
            "report": [
                "outcome": "uncertain",
                "warning": warning,
                "rawNominations": [[String: Any]](),
                "audit": labelledAudit(
                    proposed: 1, cut: 0, leftIn: [],
                    held: [["reason": "total-share-ceiling", "startSeconds": 3.0, "endSeconds": 10.0]],
                    incompleteError: "unresolved commercial spans",
                    warning: warning),
            ],
        ]
    }

    func configureLabelling(
        defaults: UserDefaults,
        sender: LabellerSenderStub,
        shadow: Bool? = false,
        enabled: Bool = true,
        confirmed: Bool = true,
        adFree: Bool = false,
        modelID: String? = nil,
        level: String? = nil
    ) -> PodcastLabellingServices {
        let preferences = AdLabellerPreferences(preferences: defaults)
        preferences.isEnabled = enabled
        if let shadow { preferences.isShadow = shadow }
        if confirmed { preferences.setConfirmed(feedID: Self.labelledFeedID.rawValue, true) }
        if adFree { defaults.set([Self.labelledFeedID.rawValue], forKey: AdLabellerPreferences.adFreeFeedsKey) }
        if let modelID { preferences.modelID = modelID }
        if let level { preferences.level = level }
        return PodcastLabellingServices(
            preferences: preferences,
            counter: LabellerRequestCounter(preferences: defaults),
            keyStore: InMemoryLabellerKeyStore(key: Self.labelledKey),
            sender: sender)
    }

    func labelledPipeline(
        _ fixture: Fixture,
        runner: some PodcastPipelineRunning,
        labelling: PodcastLabellingServices
    ) -> PodcastPreparationPipeline {
        PodcastPreparationPipeline(
            store: fixture.store,
            workDirectory: fixture.workDirectory,
            runner: runner,
            now: { Date(timeIntervalSince1970: 1_700_000_200) },
            appVersion: nil,
            labelling: labelling)
    }

    func decodeRequest(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func mustCutReply(rejectedExtra: Bool = false) -> String {
        if rejectedExtra {
            return #"{"breaks":[{"startSegment":1,"endSegment":2,"kind":"sponsor","label":"must-cut","advertisers":["Fizzbolt"]},{"startSegment":99,"endSegment":100,"kind":"sponsor","label":"must-cut","advertisers":["Nope"]}]}"#
        }
        return #"{"breaks":[{"startSegment":1,"endSegment":2,"kind":"sponsor","label":"must-cut","advertisers":["Fizzbolt"]}]}"#
    }

    private func emptyBreaksReply() -> String {
        #"{"breaks":[]}"#
    }

    // MARK: Cases

    @Test func labelledCutRunsTranscriptLabelAndCutThenCommits() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, _ in
            let stage = request["adStage"] as? String
            if stage == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            #expect(stage == "cut")
            #expect(request["labellerCuesDigest"] as? String == cue.digest)
            #expect(request["labellerModelID"] as? String == AdLabellerPreferences.defaultModelID)
            #expect(request["labellerLevel"] as? String == AdLabellerPreferences.defaultLevel)
            #expect(request["labellerPromptVersion"] as? String == EpisodeLabeller.promptVersion)
            let breaks = try #require(request["labelledBreaks"] as? [[String: Any]])
            #expect(breaks.count == 1)
            #expect(breaks[0]["start"] as? Double == 3.0)
            #expect(breaks[0]["end"] as? Double == 10.0)
            #expect(breaks[0]["kind"] as? String == "sponsor")
            #expect(breaks[0]["label"] as? String == "must-cut")
            return (Self.cutResponse(audioPath: request["outputPath"] as? String ?? ""), Fixture.cuttingAudio)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let status = StatusLog()
        let result = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID, onStatus: { status.append($0.stage, detail: $0.detail) })

        let requests = await worker.allRequests()
        #expect(requests.count == 2)
        #expect(try decodeRequest(requests[0])["adStage"] as? String == "transcript")
        #expect(try decodeRequest(requests[1])["adStage"] as? String == "cut")
        #expect(sender.requestCount == 1)
        #expect(result.adRemovalOutcome == "cut")
        #expect(result.removedSeconds == 4.5)
        #expect(status.stages.contains("ads.label.start"))
        #expect(status.stages.contains("ads.label.complete"))
        let outcome = try #require(try await fixture.store.preparationOutcome(
            for: fixture.episodeID, revisionID: result.revision.revisionID))
        let local = PodcastPreparationPipeline.policyDigest(
            PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true))
        #expect(outcome.policyDigest != local)
        #expect(local == Self.localPolicyDigestPin)
    }

    @Test func labelledNoAdsReplyStillRunsCutStage() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: emptyBreaksReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            let breaks = try #require(request["labelledBreaks"] as? [[String: Any]])
            #expect(breaks.isEmpty)
            return (Self.noAdsCutResponse(audioPath: fixture.audioURL.path), nil)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let result = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        let requests = await worker.allRequests()
        #expect(requests.count == 2)
        #expect(try decodeRequest(requests[1])["adStage"] as? String == "cut")
        #expect(result.adRemovalOutcome == "noAds")
        #expect(result.removedSeconds == 0)
    }

    @Test func labelledLeftInFromWorkerAndParseRejectionAreReported() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(rejectedExtra: true), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            let breaks = try #require(request["labelledBreaks"] as? [[String: Any]])
            #expect(breaks.count == 1)
            let leftIn: [[String: Any]] = [[
                "startSeconds": 0.0, "endSeconds": 1.0, "kind": "sponsor", "label": "acceptable-cut",
                "advertisers": ["Skip"], "reason": "acceptable-cut",
            ]]
            return (
                Self.cutResponse(audioPath: request["outputPath"] as? String ?? "", leftIn: leftIn),
                Fixture.cuttingAudio
            )
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let status = StatusLog()
        let result = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID, onStatus: { status.append($0.stage, detail: $0.detail) })
        #expect(result.adRemovalOutcome == "cut")
        let leftInStages = status.entries.filter { $0.stage.hasPrefix("ads.left-in.") }
        #expect(leftInStages.count == 2)
        #expect(leftInStages.contains(where: { $0.detail.contains("acceptable-cut") }))
        #expect(leftInStages.contains(where: { $0.detail.contains("malformed") }))
    }

    /// A cue file that repeats an ID is a worker fault; reporting left-in breaks must not trap on it.
    @Test func aRepeatedCueIDDoesNotStopLeftInReporting() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(rejectedExtra: true), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(
            to: fixture.workDirectory,
            extraCues: [LabellerCue(id: 3, start: 10, end: 12, text: Self.cueTexts[3])])
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            return (Self.cutResponse(audioPath: request["outputPath"] as? String ?? ""), Fixture.cuttingAudio)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let status = StatusLog()
        let result = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID, onStatus: { status.append($0.stage, detail: $0.detail) })
        #expect(result.adRemovalOutcome == "cut")
        #expect(status.entries.contains { $0.stage.hasPrefix("ads.left-in.") })
    }

    @Test func labelledShareCeilingKeepsWholeOriginal() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            return (Self.shareCeilingResponse(audioPath: fixture.audioURL.path), nil)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let result = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.removedSeconds == 0)
        #expect(result.warning?.contains("unresolved commercial spans") == true)
        #expect(try Data(contentsOf: result.mediaURL) == Fixture.originalBody)
    }

    @Test func labelledCueMismatchRestartsOnceThenKeepsOriginal() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, index in
            let stage = request["adStage"] as? String
            if stage == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            if stage == "cut" {
                return ([
                    "ok": false, "code": "labelled-cues-mismatch",
                    "message": "aligned transcript digest does not match labellerCuesDigest",
                ], nil)
            }
            // Fallback whole-original call after the second mismatch.
            #expect(stage == nil)
            #expect(request["removeAds"] as? Bool == false)
            return ([
                "ok": true, "timing": "aligned", "audioPath": fixture.audioURL.path, "audioChanged": false,
                "durationSeconds": 12, "text": "Kept.", "cues": [[String: Any]](),
                "removedSeconds": 0, "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
                "report": ["outcome": "disabled", "rawNominations": [[String: Any]]()],
            ], nil)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let result = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        let requests = await worker.allRequests()
        let stages = try requests.map { try decodeRequest($0)["adStage"] as? String }
        #expect(stages.filter { $0 == "transcript" }.count == 2)
        #expect(stages.filter { $0 == "cut" }.count == 2)
        #expect(stages.filter { $0 == nil }.count == 1)
        #expect(sender.requestCount == 2)
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.warning?.contains("labelled cues digest mismatch") == true)
        #expect(result.removedSeconds == 0)
    }

    /// A cue file that fails its digest is a local fault: no labelling request,
    /// one restart, then the whole original. It must never read as a provider failure.
    @Test func cueFileFailingItsDigestKeepsOriginalWithoutLabelling() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned", "durationSeconds": 12,
                    "labellerCuesPath": cue.path, "labellerCuesDigest": String(repeating: "0", count: 64),
                ], nil)
            }
            #expect(request["adStage"] == nil)
            #expect(request["removeAds"] as? Bool == false)
            return ([
                "ok": true, "timing": "aligned", "audioPath": fixture.audioURL.path, "audioChanged": false,
                "durationSeconds": 12, "text": "Kept.", "cues": [[String: Any]](),
                "removedSeconds": 0, "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
                "report": ["outcome": "disabled", "rawNominations": [[String: Any]]()],
            ], nil)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let result = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        let stages = try await worker.allRequests().map { try decodeRequest($0)["adStage"] as? String }
        #expect(stages == ["transcript", "transcript", nil])
        #expect(sender.requestCount == 0)
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.removedSeconds == 0)
    }

    @Test func labelledCueMismatchRestartsOnceThenSucceeds() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, index in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            if index == 1 {
                return ([
                    "ok": false, "code": "labelled-cues-mismatch",
                    "message": "aligned transcript digest does not match labellerCuesDigest",
                ], nil)
            }
            return (Self.cutResponse(audioPath: request["outputPath"] as? String ?? ""), Fixture.cuttingAudio)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let result = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        let requests = await worker.allRequests()
        #expect(requests.count == 4)
        #expect(sender.requestCount == 2)
        #expect(result.adRemovalOutcome == "cut")
    }

    @Test(arguments: [
        (removeAds: false, adFree: false),
        (removeAds: true, adFree: true),
    ])
    func labelledPathSkippedWhenAdsOffOrAdFree(argument: (removeAds: Bool, adFree: Bool)) async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let stub = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
        ])
        let labelling = configureLabelling(defaults: defaults, sender: sender, adFree: argument.adFree)
        _ = try await labelledPipeline(fixture, runner: stub, labelling: labelling).prepare(
            episodeID: fixture.episodeID,
            policy: PodcastPreparationPolicySnapshot(
                transcriptPolicy: .bestAvailable, removeAds: argument.removeAds))
        let request = try decodeRequest(try #require(await stub.lastRequest()))
        #expect(request["adStage"] == nil)
        #expect(sender.requestCount == 0)
    }

    @Test(arguments: [
        "shadow",
        "routeLocal",
    ])
    func labelledPathSkippedWhenShadowOrLocal(mode: String) async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let stub = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
        ])
        let labelling: PodcastLabellingServices
        switch mode {
        case "shadow":
            labelling = configureLabelling(defaults: defaults, sender: sender, shadow: true)
        default:
            labelling = configureLabelling(defaults: defaults, sender: sender, confirmed: false)
        }
        _ = try await labelledPipeline(fixture, runner: stub, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        let request = try decodeRequest(try #require(await stub.lastRequest()))
        #expect(request["adStage"] == nil)
        #expect(sender.requestCount == 0)
    }

    @Test func labelledCutWorksThroughPrepareAgain() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: "podcast-preparation-v15")
            .prepare(episodeID: fixture.episodeID)
        let candidate = try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
        let staged = try fixture.staged(Fixture.originalBody)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            return (Self.cutResponse(audioPath: request["outputPath"] as? String ?? ""), Self.recutAudio)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let outcome = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepareAgain(candidate: candidate, stage: { staged })
        guard case .prepared(let result) = outcome else {
            Issue.record("expected prepared, got \(outcome)")
            return
        }
        let requests = await worker.allRequests()
        #expect(requests.count == 2)
        #expect(try decodeRequest(requests[0])["adStage"] as? String == "transcript")
        #expect(try decodeRequest(requests[1])["adStage"] as? String == "cut")
        #expect(sender.requestCount == 1)
        #expect(result.adRemovalOutcome == "cut")
    }

    /// A failure that never gets better stops at once: the original is published with the reason.
    @Test func labellerKeyRejectionPublishesTheOriginalWithTheReason() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [.fail(.keyRejected)])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            #expect(request["adStage"] == nil)
            #expect(request["removeAds"] as? Bool == false)
            return ([
                "ok": true, "timing": "aligned", "audioPath": fixture.audioURL.path, "audioChanged": false,
                "durationSeconds": 12, "text": "Kept.", "cues": [[String: Any]](),
                "removedSeconds": 0, "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
                "report": ["outcome": "disabled", "rawNominations": [[String: Any]]()],
            ], nil)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let result = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        let stages = try await worker.allRequests().map { try decodeRequest($0)["adStage"] as? String }
        #expect(stages == ["transcript", nil])
        #expect(sender.requestCount == 1)
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.warning == "original audio includes ads: Provider key was rejected. Update it in Settings.")
    }

    @Test func labelledProvenanceChangesPolicyDigest() {
        let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)
        let local = PodcastPreparationPipeline.policyDigest(policy)
        #expect(local == Self.localPolicyDigestPin)

        let remote = LabelledRunProvenance(
            route: "remote", modelID: "model-a", level: "low",
            promptVersion: EpisodeLabeller.promptVersion)
        let remoteDigest = PodcastPreparationPipeline.policyDigest(policy, labelled: remote)
        #expect(remoteDigest != local)

        let otherModel = LabelledRunProvenance(
            route: "remote", modelID: "model-b", level: "low",
            promptVersion: EpisodeLabeller.promptVersion)
        #expect(PodcastPreparationPipeline.policyDigest(policy, labelled: otherModel) != remoteDigest)

        let otherLevel = LabelledRunProvenance(
            route: "remote", modelID: "model-a", level: "high",
            promptVersion: EpisodeLabeller.promptVersion)
        #expect(PodcastPreparationPipeline.policyDigest(policy, labelled: otherLevel) != remoteDigest)

        let otherPrompt = LabelledRunProvenance(
            route: "remote", modelID: "model-a", level: "low", promptVersion: "labeller-prompt-v0")
        #expect(PodcastPreparationPipeline.policyDigest(policy, labelled: otherPrompt) != remoteDigest)
    }
}
