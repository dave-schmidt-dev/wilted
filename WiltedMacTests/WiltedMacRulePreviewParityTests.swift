import AppKit
import SwiftUI
import XCTest
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacRulePreviewParityTests: XCTestCase {
    func testFeedAndPlaylistPreviewRowsRenderLarderMetadataAndContiguousOrdinals() async throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let publishedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let episode = WiltedMacEpisode(
            id: "preview-parity-episode", title: "Garden Morning 203", feedTitle: "Garden Radio",
            summary: "", artworkURL: nil, releasedAt: publishedAt, publishedAt: publishedAt,
            sourceDurationSeconds: 3_723, durationSeconds: 3_723, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        model.installEpisodeForTesting(episode)

        let playlistRow = WiltedMacPlaylistPreviewRow(
            model: model, entryID: episode.id, position: 2, total: 3)
        let playlistText = try renderedText(playlistRow, size: CGSize(width: 680, height: 150))
        for fact in [episode.title, episode.feedTitle, "1h 02m", publishedAt.formatted(date: .numeric, time: .omitted), "02"] {
            XCTAssertTrue(playlistText.contains(fact), "playlist preview draws \(fact): \(playlistText)")
        }

        let ruleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let ruleRow = FeedRulesPreviewRow(
            episodeID: episode.id, title: episode.title, result: .skip(ruleID: ruleID), ruleNumber: 1,
            current: .undecided, isKept: false, outcome: .skip, deletesDownloadedAudio: false,
            presentation: episode.presentation)
        let feedRow = WiltedMacFeedRulesPreviewRow(
            row: ruleRow, position: 2, total: 3,
            source: model.episodeInfoSource(id: episode.id, showTitle: episode.feedTitle))
        let feedText = try renderedText(feedRow, size: CGSize(width: 760, height: 170))
        for fact in [episode.title, episode.feedTitle, "1h 02m", publishedAt.formatted(date: .numeric, time: .omitted), "Skip (rule 1)"] {
            XCTAssertTrue(feedText.contains(fact), "feed preview draws \(fact): \(feedText)")
        }
        XCTAssertTrue(feedText.contains("02"), "feed preview draws ordinal: \(feedText)")
        for (appearance, colorScheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let playlistCapture = playlistRow
                .environment(\.colorScheme, colorScheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(WiltedTheme.color(.page, scheme: colorScheme))
            let playlistBitmap = try WiltedMacHeadless.render(
                playlistCapture, size: CGSize(width: 680, height: 150))
            try retain(playlistBitmap, named: "rule-preview-smart-playlist-\(appearance)")
            let feedCapture = feedRow
                .environment(\.colorScheme, colorScheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(WiltedTheme.color(.page, scheme: colorScheme))
            let feedBitmap = try WiltedMacHeadless.render(
                feedCapture, size: CGSize(width: 760, height: 170))
            try retain(feedBitmap, named: "rule-preview-feed-rules-\(appearance)")
        }
        await model.close()
    }

    func testRulePreviewRowAccessibilityValuesWhenSwiftUIAXIsAvailable() async throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let publishedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let episode = WiltedMacEpisode(
            id: "preview-parity-episode", title: "Garden Morning 203", feedTitle: "Garden Radio",
            summary: "", artworkURL: nil, releasedAt: publishedAt, publishedAt: publishedAt,
            sourceDurationSeconds: 3_723, durationSeconds: 3_723, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        model.installEpisodeForTesting(episode)

        let playlistRow = WiltedMacPlaylistPreviewRow(
            model: model, entryID: episode.id, position: 2, total: 3)
        let ruleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let ruleRow = FeedRulesPreviewRow(
            episodeID: episode.id, title: episode.title, result: .skip(ruleID: ruleID), ruleNumber: 1,
            current: .undecided, isKept: false, outcome: .skip, deletesDownloadedAudio: false,
            presentation: episode.presentation)
        let feedRow = WiltedMacFeedRulesPreviewRow(
            row: ruleRow, position: 2, total: 3,
            source: model.episodeInfoSource(id: episode.id, showTitle: episode.feedTitle))

        let appKitIdentifier = "preview-parity-appkit-positive-control"
        let swiftUIIdentifier = "preview-parity-swiftui-positive-control"
        let playlistIdentifier = "wilted-playlist-preview-row-\(episode.id)"
        let feedIdentifier = "wilted-feed-rules-row-\(episode.id)"
        let content = VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Button("SwiftUI AX positive control") {}
                .accessibilityIdentifier(swiftUIIdentifier)
                .accessibilityValue("swiftui-positive-value")
            playlistRow
            feedRow
        }
        let snapshot = accessibilitySnapshot(
            content,
            identifiers: [appKitIdentifier, swiftUIIdentifier, playlistIdentifier, feedIdentifier],
            appKitPositiveControlIdentifier: appKitIdentifier,
            size: CGSize(width: 760, height: 430))

        let appKitNodes = snapshot.nodes(for: appKitIdentifier)
        _ = try XCTUnwrap(
            appKitNodes.first { $0.label == "AppKit AX positive control" },
            "AppKit AX positive control missing expected identifier/text: \(snapshot.diagnostic(for: appKitIdentifier))")

        let swiftUINodes = snapshot.nodes(for: swiftUIIdentifier)
        guard !swiftUINodes.isEmpty else {
            let details = "AppKit positive control found (\(snapshot.diagnostic(for: appKitIdentifier))); "
                + "ordinary SwiftUI Button AX node absent. "
                + "SwiftUI nodes: \(snapshot.diagnostic(for: swiftUIIdentifier))"
            await model.close()
            throw XCTSkip("Headless AX limitation: \(details)")
        }

        XCTAssertEqual(
            snapshot.values(for: playlistIdentifier).first, "2 of 3",
            "matching playlist AX nodes: \(snapshot.diagnostic(for: playlistIdentifier))")
        XCTAssertEqual(
            snapshot.values(for: feedIdentifier).first, "2 of 3",
            "matching feed AX nodes: \(snapshot.diagnostic(for: feedIdentifier))")
        await model.close()
    }

    func testPreviewSortPreferencesPersistIndependentlyInTheModelsSuite() async {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let feedSettings = WiltedMacRulePreviewSortPreferences.Value(sort: .alphabetical, direction: .descending)
        let playlistSettings = WiltedMacRulePreviewSortPreferences.Value(sort: .length, direction: .ascending)

        WiltedMacRulePreviewSortPreferences.store(
            feedSettings, in: model.preferences, prefix: WiltedMacRulePreviewSortPreferences.feedRulesPrefix)
        WiltedMacRulePreviewSortPreferences.store(
            playlistSettings, in: model.preferences, prefix: WiltedMacRulePreviewSortPreferences.playlistRulesPrefix)

        XCTAssertEqual(
            WiltedMacRulePreviewSortPreferences.restore(
                from: model.preferences, prefix: WiltedMacRulePreviewSortPreferences.feedRulesPrefix),
            feedSettings)
        XCTAssertEqual(
            WiltedMacRulePreviewSortPreferences.restore(
                from: model.preferences, prefix: WiltedMacRulePreviewSortPreferences.playlistRulesPrefix),
            playlistSettings)
        await model.close()
    }

    func testPlaylistRulePreviewUsesLarderSortsAndKeepsItsCustomOrder() async {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let newest = Date(timeIntervalSince1970: 1_710_000_000)
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let episodes = [
            WiltedMacEpisode(
                id: "rule-order-alpha", title: "Alpha", feedTitle: "Order Show", summary: "",
                artworkURL: nil, releasedAt: newest, publishedAt: older,
                sourceDurationSeconds: 600, durationSeconds: 600, playbackSeconds: 0,
                downloadState: .completed, preparationState: .prepared(summary: "Ready")),
            WiltedMacEpisode(
                id: "rule-order-zulu", title: "Zulu", feedTitle: "Order Show", summary: "",
                artworkURL: nil, releasedAt: older, publishedAt: newest,
                sourceDurationSeconds: 120, durationSeconds: 120, playbackSeconds: 0,
                downloadState: .completed, preparationState: .prepared(summary: "Ready")),
            WiltedMacEpisode(
                id: "rule-order-middle", title: "Middle", feedTitle: "Order Show", summary: "",
                artworkURL: nil, releasedAt: Date(), publishedAt: nil,
                sourceDurationSeconds: nil, durationSeconds: nil, playbackSeconds: 0,
                downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        ]
        episodes.forEach(model.installEpisodeForTesting)
        let entries = episodes.map { WiltedMacPlaylistRulePreview.Entry(id: $0.id, title: $0.title) }

        XCTAssertEqual(
            WiltedMacPlaylistRulePreviewOrdering.orderedEntries(
                entries, model: model, sort: .custom, direction: .ascending).map(\.id),
            entries.map(\.id))
        XCTAssertEqual(
            WiltedMacPlaylistRulePreviewOrdering.orderedEntries(
                entries, model: model, sort: .alphabetical, direction: .ascending).map(\.id),
            ["rule-order-alpha", "rule-order-middle", "rule-order-zulu"])
        XCTAssertEqual(
            WiltedMacPlaylistRulePreviewOrdering.orderedEntries(
                entries, model: model, sort: .length, direction: .ascending).map(\.id),
            ["rule-order-zulu", "rule-order-alpha", "rule-order-middle"])
        XCTAssertEqual(
            WiltedMacPlaylistRulePreviewOrdering.orderedEntries(
                entries, model: model, sort: .age, direction: .ascending).map(\.id),
            ["rule-order-zulu", "rule-order-alpha", "rule-order-middle"],
            "age uses actual publication dates and leaves unknown publication last")
        await model.close()
    }

    func testFeedPreviewOrdinalsStayContiguousAcrossVisibleVerdictGroups() {
        func row(_ id: String, _ outcome: FeedRulesOutcome) -> FeedRulesPreviewRow {
            FeedRulesPreviewRow(
                episodeID: id, title: id, result: .noMatch, ruleNumber: nil,
                current: .undecided, isKept: false, outcome: outcome, deletesDownloadedAudio: false)
        }
        let sections = WiltedMacFeedRulesPreviewSections(rows: [
            row("held", .waiting), row("automatic", .keepToSkip), row("skip", .skip), row("keep", .keep)
        ])

        XCTAssertEqual(sections.undecided.map(\.id), ["skip", "keep"])
        XCTAssertEqual(sections.automatic.map(\.id), ["automatic"])
        XCTAssertEqual(sections.unchanged.map(\.id), ["held"])
        XCTAssertEqual(sections.total, 4)
        XCTAssertEqual(sections.positions, ["skip": 1, "keep": 2, "automatic": 3, "held": 4])
    }

    private func renderedText<V: View>(_ view: V, size: CGSize) throws -> String {
        try WiltedMacHeadless.recognizedLines(view, size: size).map(\.text).joined(separator: " ")
    }

    private func retain(_ bitmap: NSBitmapImageRep, named name: String) throws {
        let attachment = XCTAttachment(
            data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func accessibilitySnapshot<V: View>(
        _ view: V,
        identifiers: Set<String>,
        appKitPositiveControlIdentifier: String,
        size: CGSize
    ) -> PreviewAXSnapshot {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        host.frame = NSRect(x: 0, y: 36, width: size.width, height: size.height - 36)
        container.addSubview(host)
        let positiveControl = NSButton(title: "AppKit AX positive control", target: nil, action: nil)
        positiveControl.setAccessibilityIdentifier(appKitPositiveControlIdentifier)
        positiveControl.setAccessibilityLabel("AppKit AX positive control")
        positiveControl.frame = NSRect(x: 8, y: 4, width: 240, height: 28)
        container.addSubview(positiveControl)
        window.contentView = container
        host.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }

        var seen = Set<ObjectIdentifier>()
        var matches: [String: [PreviewAXNode]] = [:]
        func text(_ value: Any?) -> String? {
            (value as? String) ?? (value as? NSAttributedString)?.string
        }
        func visit(_ value: Any, depth: Int = 0) {
            guard depth < 32, let node = value as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
            if let identifier = node.accessibilityIdentifier(), identifiers.contains(identifier) {
                let rawValue = node.accessibilityValue()
                let rawLabel = node.accessibilityLabel()
                let valueText = text(rawValue)
                let labelText = text(rawLabel)
                matches[identifier, default: []].append(PreviewAXNode(
                    depth: depth,
                    value: valueText,
                    label: labelText,
                    rawValue: valueText == nil ? String(describing: rawValue) : nil,
                    rawLabel: labelText == nil ? String(describing: rawLabel) : nil))
            }
            for child in node.accessibilityChildren() ?? [] {
                visit(child, depth: depth + 1)
            }
            if let view = value as? NSView {
                for child in view.subviews {
                    visit(child, depth: depth + 1)
                }
            }
        }
        visit(container)
        return PreviewAXSnapshot(matches: matches)
    }

    private struct PreviewAXNode {
        let depth: Int
        let value: String?
        let label: String?
        let rawValue: String?
        let rawLabel: String?

        var diagnostic: String {
            "depth=\(depth) value=\(value.map(String.init(reflecting:)) ?? rawValue ?? "<nil>") "
                + "label=\(label.map(String.init(reflecting:)) ?? rawLabel ?? "<nil>")"
        }
    }

    private struct PreviewAXSnapshot {
        let matches: [String: [PreviewAXNode]]

        func nodes(for identifier: String) -> [PreviewAXNode] { matches[identifier] ?? [] }
        func values(for identifier: String) -> [String] { nodes(for: identifier).compactMap(\.value) }
        func diagnostic(for identifier: String) -> String {
            let values = nodes(for: identifier).map(\.diagnostic)
            return values.isEmpty ? "no matching AX nodes" : values.joined(separator: "; ")
        }
    }
}
