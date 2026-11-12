import Foundation
import Testing
@testable import WiltedProducer

struct EpisodeLabellerTests {
    // MARK: Fixture pairs

    private struct Fixtures: Decodable {
        struct Break: Decodable {
            var startSegment: Int
            var endSegment: Int
            var kind: String
            var label: String
            var advertisers: [String]
        }
        struct Rejected: Decodable {
            var `break`: Break
            var reason: String
        }
        struct Expected: Decodable {
            var breaks: [Break]
            var rejected: [Rejected]
        }
        struct Pair: Decodable {
            var showTitle: String
            var cues: [LabellerCue]
            var durationSeconds: Double
            var prompt: String
            var reply: String
            var expected: Expected

            enum CodingKeys: String, CodingKey {
                case showTitle = "show_title"
                case cues
                case durationSeconds = "duration_seconds"
                case prompt, reply, expected
            }
        }
        var pairs: [String: Pair]
    }

    private static func loadFixtures() throws -> Fixtures {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/labeller-fixtures.json")
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }

    @Test(arguments: ["short", "long", "ad_free", "bad_cue_id"])
    func matchesTheFixturePair(name: String) throws {
        let pair = try #require(try Self.loadFixtures().pairs[name])
        #expect(EpisodeLabeller.prompt(showTitle: pair.showTitle, cues: pair.cues) == pair.prompt)

        let result = try EpisodeLabeller.parse(
            reply: pair.reply, cues: pair.cues, duration: pair.durationSeconds).get()
        #expect(result.breaks.count == pair.expected.breaks.count)
        for (actual, expected) in zip(result.breaks, pair.expected.breaks) {
            #expect(actual.startCue == expected.startSegment)
            #expect(actual.endCue == expected.endSegment)
            #expect(actual.kind.rawValue == expected.kind)
            #expect(actual.label.rawValue == expected.label)
            #expect(actual.advertisers == expected.advertisers)
            let start = pair.cues.first { $0.id == expected.startSegment }
            let end = pair.cues.first { $0.id == expected.endSegment }
            #expect(actual.startSeconds == start?.start)
            #expect(actual.endSeconds == end?.end)
        }
        #expect(result.rejected.count == pair.expected.rejected.count)
        for (actual, expected) in zip(result.rejected, pair.expected.rejected) {
            #expect(actual.startSegment == expected.break.startSegment)
            #expect(actual.endSegment == expected.break.endSegment)
            #expect(actual.reason.rawValue == expected.reason)
        }
    }

    // MARK: Inline cases

    private let cues = [
        LabellerCue(id: 0, start: 0, end: 10, text: "  Hello from the invented show.  "),
        LabellerCue(id: 1, start: 10, end: 20.5, text: "Sponsored by Fizzbolt."),
        LabellerCue(id: 2, start: 20.5, end: 30, text: "Back to the show."),
        LabellerCue(id: 3, start: 30, end: 700, text: "A very long stretch."),
    ]

    private func reply(start: Int, end: Int, kind: String = "sponsor", label: String = "must-cut") -> String {
        "{\"breaks\":[{\"startSegment\":\(start),\"endSegment\":\(end),\"kind\":\"\(kind)\","
            + "\"label\":\"\(label)\",\"advertisers\":[\"Fizzbolt\"]}]}"
    }

    @Test func buildsPromptLinesWithTrimmedTextAndTwoDecimals() {
        let prompt = EpisodeLabeller.prompt(showTitle: "Invented", cues: cues)
        #expect(prompt.contains("The show is: Invented. "))
        #expect(prompt.contains("TRANSCRIPT:\n#0 [0.00-10.00] Hello from the invented show.\n#1 [10.00-20.50] Sponsored"))
        #expect(prompt.hasSuffix("#3 [30.00-700.00] A very long stretch.\n"))
    }

    @Test func acceptsAValidReply() throws {
        let result = try EpisodeLabeller.parse(reply: reply(start: 1, end: 2), cues: cues, duration: 700).get()
        #expect(result.rejected.isEmpty)
        #expect(result.breaks == [LabelledBreak(
            kind: .sponsor, label: .mustCut, advertisers: ["Fizzbolt"],
            startCue: 1, endCue: 2, startSeconds: 10, endSeconds: 30)])
    }

    @Test(arguments: [
        (5, 6, "sponsor", "must-cut", RejectedBreakReason.unknownCueID),
        (2, 1, "sponsor", "must-cut", .invertedRange),
        (0, 3, "sponsor", "must-cut", .tooLong),
        (1, 2, "sponsor", "must-cut", .outsideEpisode),
        (1, 2, "podcast", "must-cut", .unknownKindOrLabel),
        (1, 2, "sponsor", "maybe", .unknownKindOrLabel),
    ])
    func rejectsABadBreakAndKeepsTheRest(start: Int, end: Int, kind: String, label: String,
                                         reason: RejectedBreakReason) throws {
        // Duration 25 puts cue 2's end (30) outside the episode for the fifth-row style cases.
        let duration = reason == .outsideEpisode ? 25.0 : 700.0
        let good = "{\"startSegment\":0,\"endSegment\":0,\"kind\":\"sponsor\",\"label\":\"acceptable-cut\",\"advertisers\":[]}"
        let bad = "{\"startSegment\":\(start),\"endSegment\":\(end),\"kind\":\"\(kind)\","
            + "\"label\":\"\(label)\",\"advertisers\":[\"Fizzbolt\"]}"
        let result = try EpisodeLabeller.parse(
            reply: "{\"breaks\":[\(good),\(bad)]}", cues: cues, duration: duration).get()
        #expect(result.breaks.count == 1)
        #expect(result.rejected.map(\.reason) == [reason])
        #expect(result.rejected.first?.startSegment == start)
        #expect(result.rejected.first?.endSegment == end)
    }

    @Test(arguments: ["```json\n%@\n```", "```\n%@\n```", "  \n%@\n  "])
    func acceptsFencesAndSurroundingWhitespace(template: String) throws {
        let wrapped = template.replacingOccurrences(of: "%@", with: reply(start: 1, end: 2))
        let result = try EpisodeLabeller.parse(reply: wrapped, cues: cues, duration: 700).get()
        #expect(result.breaks.count == 1)
    }

    @Test(arguments: ["I could not find any ads.", "[]", "{\"breaks\":3}", "{}", "",
                      "[{\"startSegment\":1}]"])
    func refusesAnythingThatIsNotABreaksObject(text: String) {
        #expect(EpisodeLabeller.parse(reply: text, cues: cues, duration: 700) == .failure(.unusableAnswer))
    }

    @Test func aBreakWithoutAdvertisersIsKept() throws {
        let cues = [LabellerCue(id: 0, start: 0, end: 10, text: "invented words")]
        let reply = #"{"breaks":[{"startSegment":0,"endSegment":0,"kind":"sponsor","label":"must-cut"}]}"#
        let parsed = try EpisodeLabeller.parse(reply: reply, cues: cues, duration: 10).get()
        #expect(parsed.breaks.count == 1)
        #expect(parsed.breaks.first?.advertisers == [])
    }

    @Test func emptyBreaksListIsAValidAnswer() throws {
        let result = try EpisodeLabeller.parse(reply: "{\"breaks\":[]}", cues: cues, duration: 700).get()
        #expect(result == LabellerReply(breaks: [], rejected: []))
    }

    @Test func failureKindsAreStableAndCarryNoData() {
        #expect(LabellerFailure.rateLimited(retryAfter: 30).kind == LabellerFailure.rateLimited(retryAfter: nil).kind)
        let kinds = [LabellerFailure.rateLimited(retryAfter: nil), .temporary, .keyRejected,
                     .modelUnavailable, .usageLimit, .unusableAnswer].map(\.kind)
        #expect(Set(kinds).count == kinds.count)
        #expect(EpisodeLabeller.promptVersion == "labeller-prompt-v1")
    }
}
