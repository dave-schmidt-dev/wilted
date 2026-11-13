import Foundation
import Testing
@testable import WiltedProducer

/// Phase 2 acceptance run: the product's labelling request, reply validation and break
/// objects, driven from pinned cue files kept outside the repository.
///
/// Both tests need `WILTED_LABELLED_ACCEPTANCE_DIR` to name a directory of `cases/<id>/`
/// folders (`cues.json` plus `case.json`), so the normal suite skips them and the repository
/// holds no third-party text. Nothing here prints or records transcript, prompt or reply
/// text: messages carry case IDs, counts, seconds and failure kinds only.
@Suite("Labelled acceptance replay")
struct LabelledAcceptanceReplayTests {
    private static let environment = ProcessInfo.processInfo.environment

    /// The acceptance directory, when the variable names one that exists.
    private static let root: URL? = {
        guard let path = environment["WILTED_LABELLED_ACCEPTANCE_DIR"], !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    private static let enabled = root != nil
    private static let liveEnabled = root != nil && environment["WILTED_LABELLED_ACCEPTANCE_LIVE"] == "1"

    private struct CaseFile: Decodable {
        var id: String
        var show: String
        var durationSeconds: Double
        var cuesDigest: String
    }

    private struct LoadedCase {
        var folder: URL
        var info: CaseFile
        var cues: [LabellerCue]
    }

    private static func caseFolders() throws -> [URL] {
        let cases = try #require(root).appendingPathComponent("cases", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: cases, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("case.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reads `case.json` and decodes `cues.json` with the product decoder, digest checked.
    private static func load(_ folder: URL) throws -> LoadedCase {
        let info = try JSONDecoder().decode(CaseFile.self, from: Data(contentsOf: folder.appendingPathComponent("case.json")))
        let data = try Data(contentsOf: folder.appendingPathComponent("cues.json"))
        let cues = try PodcastPreparationPipeline.decodeLabellerCues(data, expectedDigest: info.cuesDigest)
        return LoadedCase(folder: folder, info: info, cues: cues)
    }

    /// The break objects `labelledAttempt` sends to the worker's cut stage, unchanged.
    private static func workerBreaks(_ reply: LabellerReply) -> [[String: Any]] {
        reply.breaks.map { breakValue -> [String: Any] in
            [
                "start": breakValue.startSeconds,
                "end": breakValue.endSeconds,
                "kind": breakValue.kind.rawValue,
                "label": breakValue.label.rawValue,
                "advertisers": breakValue.advertisers,
            ]
        }
    }

    private static func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    /// What `breaks.json` holds for one saved reply: the break objects and rejected counts.
    private static func outcome(of loaded: LoadedCase, replyText: String) throws -> Data {
        var document: [String: Any] = [
            "id": loaded.info.id, "cuesDigest": loaded.info.cuesDigest,
            "durationSeconds": loaded.info.durationSeconds, "promptVersion": EpisodeLabeller.promptVersion,
        ]
        switch EpisodeLabeller.parse(reply: replyText, cues: loaded.cues, duration: loaded.info.durationSeconds) {
        case .success(let reply):
            var rejected: [String: Int] = [:]
            for entry in reply.rejected { rejected[entry.reason.rawValue, default: 0] += 1 }
            document["labelledBreaks"] = workerBreaks(reply)
            document["rejectedByReason"] = rejected
            document["rejectedCount"] = reply.rejected.count
        case .failure(let failure):
            document["unusable"] = failure.kind
        }
        return try encode(document)
    }

    @Test(.enabled(if: LabelledAcceptanceReplayTests.enabled))
    func replaySavedReplies() throws {
        var replayed = 0
        for folder in try Self.caseFolders() {
            let replyURL = folder.appendingPathComponent("reply.txt")
            guard FileManager.default.fileExists(atPath: replyURL.path) else { continue }
            let loaded = try Self.load(folder)
            let replyText = try String(contentsOf: replyURL, encoding: .utf8)
            let produced = try Self.outcome(of: loaded, replyText: replyText)
            try produced.write(to: folder.appendingPathComponent("breaks.json"), options: .atomic)
            let expectedURL = folder.appendingPathComponent("breaks.expected.json")
            if FileManager.default.fileExists(atPath: expectedURL.path) {
                let expected = try Data(contentsOf: expectedURL)
                #expect(produced == expected, "breaks differ from the saved fixture for case \(loaded.info.id)")
            } else {
                try produced.write(to: expectedURL, options: .atomic)
            }
            replayed += 1
        }
        #expect(replayed > 0, "no case folder under cases/ holds a saved reply")
        print("replayed \(replayed) cases")
    }

    @Test(.enabled(if: LabelledAcceptanceReplayTests.liveEnabled))
    func sendMissingRepliesLive() async throws {
        let suite = "wilted-acceptance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AdLabellerPreferences(preferences: defaults)
        let sender = OpenCodeCLILabellerSender(
            homeDirectory: OwnedTestTemp.root.appendingPathComponent("acceptance-\(UUID().uuidString)"))
        var sent = 0
        for folder in try Self.caseFolders() {
            let replyURL = folder.appendingPathComponent("reply.txt")
            guard !FileManager.default.fileExists(atPath: replyURL.path) else { continue }
            let loaded = try Self.load(folder)
            let request = LabellerRequest(
                prompt: EpisodeLabeller.prompt(showTitle: loaded.info.show, cues: loaded.cues),
                modelID: preferences.modelID, reasoningLevel: preferences.level)
            let started = ContinuousClock.now
            let response: LabellerResponse
            do {
                response = try await sender.send(request, onRequestStarted: {}, onProgress: { _ in })
            } catch let failure as LabellerFailure {
                Issue.record("live request failed: kind \(failure.kind), case \(loaded.info.id), sent \(sent)")
                return
            } catch {
                Issue.record("live request failed: kind transport, case \(loaded.info.id), sent \(sent)")
                return
            }
            sent += 1
            let elapsed = ContinuousClock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            try Data(response.text.utf8).write(to: replyURL, options: .atomic)
            var usage: [String: Any] = [:]
            if let value = response.usage.promptTokens { usage["promptTokens"] = value }
            if let value = response.usage.completionTokens { usage["completionTokens"] = value }
            if let value = response.usage.reasoningTokens { usage["reasoningTokens"] = value }
            var usable = true
            if case .failure = EpisodeLabeller.parse(
                reply: response.text, cues: loaded.cues, duration: loaded.info.durationSeconds) { usable = false }
            let meta: [String: Any] = [
                "id": loaded.info.id, "seconds": (seconds * 10).rounded() / 10, "usage": usage,
                "model": request.modelID, "level": request.reasoningLevel,
                "promptVersion": EpisodeLabeller.promptVersion, "transport": OpenCodeCLILabellerSender.transportName,
                "replyBytes": response.text.utf8.count, "usable": usable,
            ]
            try Self.encode(meta).write(to: folder.appendingPathComponent("reply.meta.json"), options: .atomic)
            print("case \(loaded.info.id) answered in \(String(format: "%.1f", seconds)) s, usable \(usable)")
        }
        print("live requests sent: \(sent)")
    }
}
