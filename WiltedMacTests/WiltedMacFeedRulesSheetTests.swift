import AppKit
import CryptoKit
import SwiftUI
import Vision
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// B7c-2.4: the match rules open from the feed gear as a resizable sheet with a
/// live preview beside the editor. The model runs against a temporary library.
@MainActor
final class WiltedMacFeedRulesSheetTests: XCTestCase {
    private let feedURL = URL(string: "https://feeds.example.test/rules-sheet.xml")!
    private let skipFights = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private let keepGuests = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
    private let seededAt = Timestamp(Date(timeIntervalSince1970: 1_672_531_200))
    private let minimum = CGSize(width: WiltedMacFeedRulesView.width, height: WiltedMacFeedRulesView.height)
    private let wide = CGSize(width: 1_100, height: 760)

    /// A retired fight companion (history), a downloaded kept one a Skip rule
    /// would retire, a guest episode to keep and a new fight companion to skip.
    private enum Seed { case undecided, retired, downloadedKeep }

    private struct Spec {
        let guid: String
        let title: String
        let day: Int
        var seed: Seed = .undecided
        var enclosureURL: URL { URL(string: "https://media.example.test/\(guid).mp3")! }
        var published: Date { Date(timeIntervalSince1970: 1_704_000_000 + Double(day) * 86_400) }
    }

    private var specs: [Spec] {
        [
            Spec(guid: "old", title: "Fight Companion - January 5", day: 1, seed: .retired),
            Spec(guid: "downloaded", title: "Fight Companion - March 1", day: 2, seed: .downloadedKeep),
            Spec(guid: "guest", title: "#2101 - Guest Interview", day: 3),
            Spec(guid: "fresh", title: "Fight Companion - March 8", day: 4),
        ]
    }

    @MainActor private struct Fixture {
        let model: WiltedMacModel
        let board: WiltedMacFeedPolicyBoard
        let editor: WiltedMacFeedRulesEditor
        let subscription: WiltedMacSubscription

        var sheet: WiltedMacFeedRulesView {
            WiltedMacFeedRulesView(editor: editor, subscription: subscription, resolved: board.resolved(for: subscription.id))
        }
    }

    // MARK: The sheet at its minimum and a wide size, light and dark

    func testSheetShowsTitleEditorHistoryRowAudioFlagAndApplyWithoutAPreviewButton() async throws {
        let fixture = try await makeFixture()
        fixture.editor.preview()
        await fixture.editor.task?.value
        let plan = try XCTUnwrap(fixture.editor.plan)
        XCTAssertTrue(plan.rows.contains { $0.outcome == .history }, "the fixture has a history row")
        XCTAssertTrue(plan.rows.contains { $0.deletesDownloadedAudio }, "the fixture has a row that deletes audio")
        XCTAssertEqual(WiltedMacFeedRulesPreview.audioDeletions(in: plan), 1, "Apply asks first: Undo cannot restore audio")
        XCTAssertEqual(WiltedMacFeedRulesPreview.audioDeletions(in: nil), 0)
        XCTAssertTrue(fixture.editor.canApply)

        for scheme in [ColorScheme.light, .dark] {
            for size in [minimum, wide] {
                let host = WiltedMacRulesSheetCapture.host(fixture.sheet, size: size, scheme: scheme)
                await fixture.editor.task?.value  // the preview the sheet runs as it opens
                XCTAssertNil(fixture.editor.progress, "rendered after the opening preview settled")
                XCTAssertTrue(fixture.editor.canApply)
                let name = "rules-sheet-\(scheme == .dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
                let shown = try WiltedMacRulesSheetCapture.text(host, name: name, in: self)
                for text in [
                    "Match rules for Rules Sheet Feed", "Done", "Rule 1", "Rule 2", "Add rule", "Rule results",
                    "Apply to existing", "Automatic decisions", "1 Keep to Skip", "January 5", "retired or finished",
                ] {
                    XCTAssertTrue(shown.contains(text), "\(text) in \(name): \(shown)")
                }
                XCTAssertTrue(shown.localizedCaseInsensitiveContains("deletes downloaded audio"), "\(name): \(shown)")
                XCTAssertFalse(shown.contains("Preview"), "live preview has no Preview button: \(name): \(shown)")
                XCTAssertFalse(shown.contains("Checking episodes"), "settled: \(name): \(shown)")
            }
        }
    }

    // MARK: Live preview

    func testOpeningTheSheetPreviewsAtOnce() async throws {
        let fixture = try await makeFixture()
        XCTAssertNil(fixture.editor.plan, "nothing has previewed before the sheet opens")
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: minimum), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: fixture.sheet)
        defer { window.contentView = nil; window.close() }
        await WiltedMacHeadless.eventually("the sheet previews when it opens", timeout: .seconds(5)) {
            fixture.editor.plan != nil
        }
        await fixture.editor.task?.value
        XCTAssertEqual(fixture.editor.plan?.rows.count, specs.count)
    }

    func testSheetShowsProgressWhileAnEditWaitsAndWhileItsPreviewRuns() async throws {
        let fixture = try await makeFixture()
        let host = WiltedMacRulesSheetCapture.host(fixture.sheet, size: minimum)
        await fixture.editor.task?.value  // the preview the sheet runs as it opens
        let opened = try WiltedMacRulesSheetCapture.text(host, name: "rules-sheet-opened", in: self)
        XCTAssertTrue(opened.contains("Automatic decisions"), opened)
        let gate = RulesStepGate()
        fixture.editor.stepHookForTesting = { done in if done == 1 { await gate.pause() } }

        let first = try XCTUnwrap(fixture.editor.drafts.first)
        fixture.editor.update(first.id) { $0.include = "Fight Companion - March" }
        XCTAssertNil(fixture.editor.plan, "an edit clears the plan until its preview lands")
        XCTAssertFalse(fixture.editor.canApply, "Apply waits for the edit's preview")
        let waiting = try WiltedMacRulesSheetCapture.text(host, name: "rules-sheet-edit-waiting", in: self)
        XCTAssertTrue(waiting.contains("Checking episodes"), waiting)
        XCTAssertFalse(waiting.contains("Cancel"), "nothing runs while editing pauses: \(waiting)")
        XCTAssertTrue(waiting.contains("Automatic decisions"), "the last results stay, dimmed: \(waiting)")

        await gate.waitUntilEntered()
        await WiltedMacHeadless.eventually("the first step's progress") { fixture.editor.progress?.done == 1 }
        let running = try WiltedMacRulesSheetCapture.text(host, name: "rules-sheet-preview-running", in: self)
        XCTAssertTrue(running.contains("Checked 1 of \(specs.count) episodes"), running)
        XCTAssertTrue(running.contains("Cancel"), running)

        await gate.release()
        await fixture.editor.task?.value
        fixture.editor.stepHookForTesting = nil
        XCTAssertNil(fixture.editor.progress)
        XCTAssertEqual(
            fixture.editor.plan?.rows.first { $0.title == "Fight Companion - January 5" }?.outcome, .history,
            "the edited rule no longer matches January, which stays history either way"
        )
    }

    // MARK: The gear opens a sheet; the popover page is gone

    func testGearOpensTheRulesSheetAndThePopoverPagePathIsGone() throws {
        XCTAssertEqual(WiltedMacFeedRulesView.width, 720)
        XCTAssertEqual(WiltedMacFeedRulesView.height, 560)
        XCTAssertEqual(WiltedMacFeedPolicyContent.width, 460, "the popover itself keeps its width")

        let policy = try WiltedMacHeadless.viewSource("WiltedMacFeedPolicyView.swift")
        XCTAssertTrue(policy.contains(".sheet(isPresented: $isEditingRules) {"), "the sheet hangs on the gear")
        XCTAssertTrue(policy.contains("openRules: { isPresented = false; isEditingRules = true }"),
                      "opening the rules closes the popover and opens the sheet")
        XCTAssertTrue(policy.contains("open: openRules"))
        XCTAssertTrue(policy.contains("dismiss: { isEditingRules = false }"))
        for retired in ["showsRules", "back:"] {
            XCTAssertFalse(policy.contains(retired), "\(retired) is the retired popover page path")
        }

        let rules = try WiltedMacHeadless.viewSource("WiltedMacFeedRulesView.swift")
        let preview = try WiltedMacHeadless.viewSource("WiltedMacFeedRulesPreviewView.swift")
        for retired in ["back:", "wilted-feed-rules-back", "maximumHeight", "Back to feed settings"] {
            XCTAssertFalse(rules.contains(retired), retired)
        }
        for source in [rules, preview] {
            XCTAssertFalse(source.contains("Button(\"Preview\")"))
            XCTAssertFalse(source.contains("\"wilted-feed-rules-preview\""))
        }
        XCTAssertTrue(preview.contains(".confirmationDialog("), "Apply confirms before deleting audio")
        XCTAssertTrue(preview.contains("if Self.audioDeletions(in: editor.plan) > 0 { isConfirmingApply = true } else { editor.apply() }"))
        XCTAssertTrue(preview.contains("\"wilted-feed-rules-apply-confirm\""))
        XCTAssertTrue(rules.contains("minWidth: Self.width"))
        XCTAssertTrue(rules.contains("minHeight: Self.height"))
        let task = try XCTUnwrap(rules.range(of: ".task {"))
        XCTAssertTrue(rules[task.upperBound...].prefix(120).contains("editor.preview()"), "opening previews at once")

        // The details sheet hosts the same gear, so the rules sheet stacks over it.
        let details = try WiltedMacHeadless.viewSource("WiltedMacFeedDetailsView.swift")
        XCTAssertTrue(details.contains("WiltedMacFeedPolicyButton(board: board, subscription: subscription)"))
    }

    // MARK: Fixture

    private func makeFixture() async throws -> Fixture {
        let directory = wiltedTemporaryDirectory("feed-rules-sheet")
        let (feedURL, specs, at) = (feedURL, specs, seededAt)
        let rules = EpisodeMatchRules(rules: [
            .init(id: skipFights, field: .title, includePattern: "Fight Companion", action: .skip),
            .init(id: keepGuests, field: .title, includePattern: "^#", action: .keep),
        ])
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let ids = Dictionary(uniqueKeysWithValues: try specs.map { spec in
            (spec.guid, try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: spec.guid, enclosureURL: spec.enclosureURL))
        })
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Rules Sheet Feed", createdAt: at
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: at))
                var queued: [ItemID] = []
                for spec in specs {
                    let id = ids[spec.guid]!
                    try await store.save(episode: try PodcastEpisode(
                        itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: spec.guid, title: spec.title,
                        publishedTime: Timestamp(spec.published), enclosureURL: spec.enclosureURL,
                        enclosureMediaType: "audio/mpeg", createdAt: at
                    ))
                    switch spec.seed {
                    case .undecided: continue
                    case .retired: _ = try await store.retireEpisode(id, at: at); continue
                    case .downloadedKeep: break
                    }
                    try await store.save(episodeDecision: .init(episodeID: id, decision: .keep, source: .policy, decidedAt: at))
                    queued.append(id)
                    // Inside the library directory, where a Skip may delete it.
                    let audio = Data("rules-sheet-audio".utf8)
                    let mediaURL = url.deletingLastPathComponent().appendingPathComponent("\(spec.guid).mp3")
                    try audio.write(to: mediaURL)
                    try await store.save(download: PodcastDownload(
                        episodeID: id, status: .completed, bytesReceived: Int64(audio.count),
                        expectedByteCount: Int64(audio.count), localURL: mediaURL,
                        contentHash: "sha256:" + SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined(),
                        updatedAt: at
                    ))
                }
                try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: queued, currentEpisodeID: nil))
                try await store.save(
                    feedAutomationPolicy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .off),
                    for: feedID
                )
                try await store.replaceEpisodeMatchRules(rules, for: feedID)
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        let editor = board.rulesEditor(for: feedID.rawValue)
        editor.loadIfNeeded()
        let subscription = try XCTUnwrap(model.subscriptions.first { $0.id == feedID.rawValue })
        return Fixture(model: model, board: board, editor: editor, subscription: subscription)
    }
}

// MARK: - Capture

/// Renders a view at the size a window gives it, in light or dark, and reads its
/// text back from a 2x bitmap. A tall fixed canvas shrinks body text until Vision
/// misreads it, and so does one wide image of both sheet columns ("Autamatic",
/// "rule 2"), so a sheet is read as its editor column and its results column.
@MainActor
enum WiltedMacRulesSheetCapture {
    /// Hosts `view` at `size`. Rendering the same host again keeps its state, so the
    /// sheet's opening preview runs once, as it does in the app.
    static func host<V: View>(_ view: V, size: CGSize, scheme: ColorScheme = .light) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(WiltedTheme.color(.card, scheme: scheme))
            .environment(\.colorScheme, scheme)))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    static func text<V: View>(
        _ view: V, size: CGSize, scheme: ColorScheme = .light, columns: Bool = true, name: String, in test: XCTestCase
    ) throws -> String {
        try text(host(view, size: size, scheme: scheme), columns: columns, name: name, in: test)
    }

    static func text(_ host: NSView, columns: Bool = true, name: String, in test: XCTestCase) throws -> String {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let size = host.bounds.size
        let scale: CGFloat = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        try XCTUnwrap(host.appearance).performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
        if let directory = ProcessInfo.processInfo.environment["WILTED_WALKTHROUGH_CAPTURE_DIR"] {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        let image = try XCTUnwrap(bitmap.cgImage)
        let (width, height) = (CGFloat(image.width), CGFloat(image.height))
        // The editor column ends at its widest or at half the sheet, whichever is less.
        let split = min(WiltedMacFeedRulesView.editorMaxWidth, size.width / 2) * scale
        let crops = columns
            ? [CGRect(x: 0, y: 0, width: split, height: height), CGRect(x: split, y: 0, width: width - split, height: height)]
            : [CGRect(x: 0, y: 0, width: width, height: height)]
        return try crops.map { try read(XCTUnwrap(image.cropping(to: $0))) }.joined(separator: " ")
    }

    private static func read(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

/// Holds a rules evaluation at a step until the test lets it go.
private actor RulesStepGate {
    private var hasEntered = false
    private var isReleased = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        hasEntered = true
        arrivals.forEach { $0.resume() }
        arrivals = []
        guard !isReleased else { return }
        await withCheckedContinuation { releases.append($0) }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        isReleased = true
        releases.forEach { $0.resume() }
        releases = []
    }
}
