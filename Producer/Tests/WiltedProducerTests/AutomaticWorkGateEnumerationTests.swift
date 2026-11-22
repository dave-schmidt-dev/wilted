import Foundation
import XCTest

/// Walks the Mac app's source and checks that every start of a download or a
/// preparation is either the owner's own action (listed below, with the reason)
/// or marked automatic, and that the automatic marker reaches the one gate that
/// leaves a possible-duplicate flag alone. A new call site fails here until it
/// is classified, so a new automatic path cannot slip past the flag.
final class AutomaticWorkGateEnumerationTests: XCTestCase {
    /// Every function that starts a transfer or a preparation, directly or in bulk. Recovery of a
    /// claim an earlier launch left (`startClaimedDownload`) and the two settings-driven bulk
    /// actions are here too, because they are where an automatic marker is most easily dropped.
    private static let sinks = [
        "downloadEpisode", "prepareEpisode", "prepareDeferredEpisodeNow", "startClaimedDownload",
        "downloadAllAvailableLarderEpisodes", "prepareAllDownloadedLarderEpisodes",
    ]

    /// Calls made because the owner pressed something, or that carry a store
    /// claim already taken through the flag-aware claim. Count per file and call.
    private static let ownerOrClaimed: [String: Int] = [
        // A download the store already claimed through the flag-aware claim.
        "EpisodeAdmissionService.swift|downloadEpisode": 1,
        // The Larder's "Download all" and "Prepare all" buttons. The settings call the same two
        // actions with the automatic marker, in WiltedMacModel+Automation.swift.
        "WiltedMacLarderView+Sections.swift|downloadAllAvailableLarderEpisodes": 1,
        "WiltedMacLarderView+Sections.swift|prepareAllDownloadedLarderEpisodes": 1,
        // Buttons on a Larder row: Download, Prepare, Retry, and the Queued override.
        "WiltedMacLarderView+Rows.swift|downloadEpisode": 1,
        "WiltedMacLarderView+Rows.swift|prepareEpisode": 2,
        "WiltedMacLarderView+Rows.swift|prepareDeferredEpisodeNow": 1,
        // The Queued override itself; the bulk pass skips a flagged row before it.
        "WiltedMacModel+Downloads.swift|prepareEpisode": 1,
        "WiltedMacModel+LarderBulkWork.swift|prepareDeferredEpisodeNow": 1,
        // Retry from the activity list, and Prepare now on a deferred job.
        "WiltedMacModel+Preparation.swift|prepareEpisode": 2,
        "WiltedMacModel+PrepareAgain.swift|prepareEpisode": 1,
        // Retry and Download again from a row.
        "WiltedMacModel+Subscriptions.swift|downloadEpisode": 2,
    ]

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func macSources() throws -> [(name: String, text: String)] {
        let base = root.appendingPathComponent("WiltedMac")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        return try (walker.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.map {
            ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8))
        }
    }

    /// Every call of a sink: its file, its name, and the text between the parentheses.
    private func calls(in sources: [(name: String, text: String)]) -> [(file: String, name: String, args: String)] {
        let pattern = try! NSRegularExpression(pattern: "\\b(" + Self.sinks.joined(separator: "|") + ")\\(")
        var found: [(String, String, String)] = []
        for (file, text) in sources {
            let ns = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let before = ns.substring(with: NSRange(location: max(0, match.range.location - 12),
                                                        length: min(12, match.range.location)))
                if before.range(of: "func\\s+$", options: .regularExpression) != nil { continue }
                var depth = 1
                var index = match.range.location + match.range.length
                while depth > 0, index < ns.length {
                    let ch = ns.character(at: index)
                    if ch == 40 { depth += 1 } else if ch == 41 { depth -= 1 }
                    index += 1
                }
                let start = match.range.location + match.range.length
                found.append((file, ns.substring(with: match.range(at: 1)),
                              ns.substring(with: NSRange(location: start, length: max(0, index - 1 - start)))))
            }
        }
        return found
    }

    func testEveryStartOfDownloadOrPreparationIsOwnerChosenOrAutomaticAndGated() throws {
        let sources = try macSources()
        XCTAssertGreaterThan(sources.count, 100, "the scan must really read the Mac sources")
        var unmarked: [String: Int] = [:]
        for call in calls(in: sources) {
            let marked = call.args.contains("automatic: true") || call.args.contains("automatic: automatic")
            if !marked { unmarked["\(call.file)|\(call.name)", default: 0] += 1 }
        }
        XCTAssertEqual(
            unmarked, Self.ownerOrClaimed,
            "a start of a download or preparation is neither marked automatic nor on the owner's list"
        )
    }

    func testTheGateIsReachedAtEverySink() throws {
        let sources = Dictionary(uniqueKeysWithValues: try macSources().map { ($0.name, $0.text) })
        func source(_ name: String) throws -> String { try XCTUnwrap(sources[name], name) }

        let gate = try source("WiltedMacModel+AutomaticWorkGate.swift")
        XCTAssertTrue(gate.contains("automaticWorkGate(episodeID) != .clear"), "unknown blocks like held")
        XCTAssertTrue(gate.contains("guard let held = possibleDuplicateHeldIDs else { return store != nil ? .unknown : .clear }"),
                      "an unreadable list is unknown, not clear")
        XCTAssertTrue(gate.contains("?? true"), "a failed fresh read blocks")
        XCTAssertTrue(gate.contains("guard automaticWorkGate(episodeID) == .held else { return }"),
                      "an unreadable list gives up no waiting work")

        // Recovery of a claim an earlier launch left behind goes through the gate twice: the list
        // it offers leaves flagged episodes out, and the start itself asks again.
        XCTAssertTrue(try source("WiltedMacModel+Library.swift")
            .contains("if automatic, await automaticWorkIsHeldFresh(episodeID) { return }"))
        let automation = try source("WiltedMacModel+Automation.swift")
        XCTAssertTrue(automation.contains("guard let held = await refreshPossibleDuplicateHolds(from: store) else { return [] }"))
        XCTAssertTrue(automation.contains(".filter { !held.contains($0) }"))

        let preparation = try source("WiltedMacModel+Preparation.swift")
        XCTAssertEqual(preparation.components(separatedBy: "if automatic, automaticWorkIsHeld(episode.id)").count - 1, 2,
                       "both prepare entry points ask the gate")

        let downloads = try source("WiltedMacModel+Downloads.swift")
        XCTAssertTrue(downloads.contains("if automatic, automaticWorkIsHeld(episode.id) { return }"))
        XCTAssertTrue(downloads.contains("scope: automatic ? .automaticNotInFlight : .notInFlight"))
        XCTAssertTrue(downloads.contains("if await automaticWorkIsHeldFresh(episode.id) { return true }"),
                      "a landing download asks the store afresh")
        let admit = try XCTUnwrap(downloads.range(of: "func admitAutomaticPreparation("))
        XCTAssertTrue(downloads[admit.upperBound...].prefix(200).contains("automaticWorkIsHeld(episode.id)"),
                      "automatic admission asks the gate first")

        let admission = try source("EpisodeAdmissionService.swift")
        XCTAssertEqual(admission.components(separatedBy: "podcastEpisodeIdentityReviewHeldIDs").count - 1, 2,
                       "automatic admission and the Keep download both read the flags")
        XCTAssertTrue(try source("WiltedMacModel+FeedRules.swift").contains("podcastEpisodeIdentityReviewHeldIDs"),
                      "Apply Rules leaves flagged rows alone")
    }

    func testTheOldLinkReviewFlowIsGone() throws {
        let sources = try macSources()
        XCTAssertFalse(sources.contains { $0.name.contains("EpisodeIdentityReview") })
        XCTAssertFalse(sources.contains { $0.text.contains("Review Possible Duplicate") })
    }
}
