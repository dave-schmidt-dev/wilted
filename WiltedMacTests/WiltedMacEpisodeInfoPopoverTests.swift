import AppKit
import SwiftUI
import Vision
import WiltedDomain
import XCTest
@testable import WiltedMac

/// The shared episode info popover: the Notes/Transcript tabs, the transcript
/// read's states, and the by-ID open History and the rules preview use. The
/// shipping surfaces build the source from the model and the store; these
/// tests hand the popover stubs and read what it draws.
@MainActor
final class WiltedMacEpisodeInfoPopoverTests: XCTestCase {
    private let savedTranscript = "The saved transcript for this episode."
    private let popoverSize = CGSize(width: 500, height: 440)

    // MARK: The tabs

    func testNotesIsDefaultAndNoTranscriptTabWithoutASource() async throws {
        let withoutSource = try WiltedMacHeadless.recognizedText(
            WiltedMacEpisodeNotes(info: info(), prefix: "wilted-feeds") { EmptyView() },
            size: popoverSize).joined(separator: "\n")
        XCTAssertTrue(withoutSource.contains("Exact notes for this episode"), withoutSource)
        XCTAssertFalse(withoutSource.contains("Transcript"), "no source, no transcript tab: \(withoutSource)")

        let stub = TranscriptReadStub(result: .none)
        let withSource = try WiltedMacHeadless.recognizedText(
            WiltedMacEpisodeNotes(info: info(), prefix: "wilted-feeds", source: stub.source()) { EmptyView() },
            size: popoverSize).joined(separator: "\n")
        XCTAssertTrue(withSource.contains("Notes"), withSource)
        XCTAssertTrue(withSource.contains("Transcript"), withSource)
        XCTAssertTrue(withSource.contains("Exact notes for this episode"), "Notes is the default tab: \(withSource)")
        let calls = await stub.callCount()
        XCTAssertEqual(calls, 0, "the default tab reads nothing")
    }

    func testTranscriptTabLoadsLazilyAndShowsSavedText() async throws {
        let stub = TranscriptReadStub(
            result: .loaded(WiltedMacTranscript(availability: .available, text: savedTranscript)))

        let notesWindow = host(
            WiltedMacEpisodeNotes(
                info: info(), prefix: "wilted-larder", source: stub.source(), initialSection: .notes
            ) { EmptyView() })
        defer { close(notesWindow) }
        await settle()
        let notesReads = await stub.callCount()
        XCTAssertEqual(notesReads, 0, "the Notes tab never reads the transcript")
        XCTAssertTrue(try text(of: notesWindow).contains("Exact notes for this episode"))

        let transcriptWindow = host(
            WiltedMacEpisodeNotes(
                info: info(), prefix: "wilted-larder", source: stub.source(), initialSection: .transcript
            ) { EmptyView() })
        defer { close(transcriptWindow) }
        await waitForReads(stub)
        await settle()
        let transcriptReads = await stub.callCount()
        XCTAssertEqual(transcriptReads, 1, "showing the tab reads the saved transcript once")
        let shown = try text(of: transcriptWindow)
        XCTAssertTrue(shown.contains(savedTranscript), shown)
        XCTAssertTrue(shown.contains("Info episode"), shown)
    }

    func testTranscriptNoneShowsNeutralCopy() async throws {
        let stub = TranscriptReadStub(result: .none)
        let window = host(
            WiltedMacEpisodeNotes(
                info: info(), prefix: "wilted-feed-history", source: stub.source(), initialSection: .transcript
            ) { EmptyView() })
        defer { close(window) }
        await waitForReads(stub)
        await settle()
        let shown = try text(of: window)
        XCTAssertTrue(shown.contains("No transcript was saved for this episode."), shown)
        XCTAssertFalse(shown.contains("Prepare this episode"), "the neutral copy never sends them to preparation: \(shown)")
    }

    func testTranscriptFailureOffersRetry() async throws {
        let stub = TranscriptReadStub(result: .failed)
        let window = host(
            WiltedMacEpisodeNotes(
                info: info(), prefix: "wilted-player", source: stub.source(), initialSection: .transcript
            ) { EmptyView() })
        defer { close(window) }
        await waitForReads(stub)
        await settle()
        let shown = try text(of: window)
        let failureReads = await stub.callCount()
        XCTAssertEqual(failureReads, 1)
        XCTAssertTrue(shown.contains("Could not read the saved transcript."), shown)
        XCTAssertTrue(shown.contains("Retry"), shown)
        XCTAssertFalse(shown.contains("Prepare this episode"), shown)
    }

    func testTranscriptNotesTranscriptSwitchKeepsOneSavedRead() async throws {
        let stub = TranscriptReadStub(
            result: .loaded(WiltedMacTranscript(availability: .available, text: savedTranscript)))
        let window = host(WiltedMacEpisodeNotes(
            info: info(), prefix: "wilted-larder", source: stub.source(), initialSection: .transcript
        ) { EmptyView() })
        defer { close(window) }
        await waitForReads(stub)
        await settle()
        let first = try text(of: window)
        XCTAssertTrue(first.contains(savedTranscript), first)

        try selectTab("Notes", in: window)
        await settle()
        let notes = try text(of: window)
        XCTAssertTrue(notes.contains("Exact notes for this episode"), notes)
        XCTAssertFalse(notes.contains(savedTranscript), notes)
        try selectTab("Transcript", in: window)
        await settle()
        let restored = try text(of: window)
        XCTAssertTrue(restored.contains(savedTranscript), restored)
        let reads = await stub.callCount()
        XCTAssertEqual(reads, 1, "the popover owns the loaded transcript across tab switches")
    }

    // MARK: Opening by identity

    func testByIDPopoverShowsLoadingThenNotesNotFoundAndError() async throws {
        let gate = BootstrapGate()
        let source = WiltedMacEpisodeInfoSource(
            loadInfo: { await gate.hold(); return .notFound },
            loadTranscript: { .none })
        let window = host(
            WiltedMacEpisodeInfoPopoverContent<EmptyView>(
                id: "gone", seed: nil, prefix: "wilted-feed-history", source: source, initialSection: .notes
            ) { EmptyView() })
        defer { close(window) }

        await gate.waitUntilHeld()
        let loading = try text(of: window)
        XCTAssertTrue(loading.contains("Loading episode"), loading)
        await gate.release()
        await settle()
        let notFound = try text(of: window)
        XCTAssertTrue(notFound.contains("No saved details for this episode."), notFound)
        XCTAssertFalse(notFound.contains("Loading episode"), notFound)

        let failed = WiltedMacEpisodeInfoSource(loadInfo: { .failed }, loadTranscript: { .none })
        let failedWindow = host(
            WiltedMacEpisodeInfoPopoverContent<EmptyView>(
                id: "gone", seed: nil, prefix: "wilted-feed-history", source: failed, initialSection: .notes
            ) { EmptyView() })
        defer { close(failedWindow) }
        await settle()
        let expectedError = "Could not load this episode's details."
        let nativeText = semanticText(of: accessibilityNodes(in: failedWindow))
        // AppKit can vend this static copy semantically. If the hidden host does
        // not, language correction is confined to this fixed English fallback.
        let error: String
        if nativeText.contains(expectedError) {
            error = nativeText
        } else {
            let recognized = try text(of: failedWindow, usesLanguageCorrection: true)
            // Vision confuses the single "o" glyph in "load" with "a" in
            // this offscreen render. Normalize only this exact English line.
            error = recognized.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line == "Could not laad this episode's details." ? expectedError : String(line)
            }.joined(separator: "\n")
        }
        XCTAssertTrue(error.contains(expectedError), error)
        XCTAssertTrue(error.contains("Retry"), error)
    }

    // MARK: The episode shapes

    /// Headless rendering cannot read identifiers, so the shared pattern is
    /// pinned where it is declared: every episode-name surface must key the
    /// same popover the same way.
    func testInfoPopoverIdentifiersKeepTheSharedPattern() throws {
        let notes = try WiltedMacHeadless.viewSource("WiltedMacEpisodeNotes.swift")
        let section = try WiltedMacHeadless.viewSource("WiltedMacEpisodeTranscriptSection.swift")
        let popover = try WiltedMacHeadless.viewSource("WiltedMacEpisodeInfoPopover.swift")
        for identifier in [
            "\\(prefix)-show-notes-\\(id)",
            "\\(prefix)-notes-popover-\\(info.id)",
            "\\(prefix)-notes-metadata-\\(info.id)",
            "\\(prefix)-notes-text-\\(info.id)",
            "\\(prefix)-notes-unavailable-\\(info.id)",
            "\\(prefix)-notes-tabs-\\(info.id)",
        ] {
            XCTAssertTrue(notes.contains(identifier), identifier)
        }
        for identifier in [
            "\\(prefix)-transcript-text-\\(id)",
            "\\(prefix)-transcript-loading-\\(id)",
            "\\(prefix)-transcript-none-\\(id)",
            "\\(prefix)-transcript-error-\\(id)",
            "\\(prefix)-notes-retry-\\(id)",
        ] {
            XCTAssertTrue(section.contains(identifier), identifier)
        }
        for identifier in [
            "\\(prefix)-notes-loading-\\(id)",
            "\\(prefix)-notes-unavailable-\\(id)",
            "\\(prefix)-notes-retry-\\(id)",
        ] {
            XCTAssertTrue(popover.contains(identifier), identifier)
        }
    }

    /// A stored episode keeps the facts the store wrote and the show title the
    /// caller already knew; nothing is inferred from the feed.
    func testStoredEpisodeProjectsItsOwnFactsAndNotes() throws {
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/info.xml"))
        let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/info.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let itemID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "info", enclosureURL: enclosure)
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = try PodcastEpisode(
            itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: "info",
            title: "Stored episode", publishedTime: Timestamp(published), enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", durationSeconds: 1_234, notes: "Stored notes",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_000_000)))
        let info = WiltedMacEpisodeInfo(stored: stored, showTitle: "Stored show")

        XCTAssertEqual(info.id, itemID.rawValue)
        XCTAssertEqual(info.title, "Stored episode")
        XCTAssertEqual(info.presentation.showTitle, "Stored show")
        XCTAssertEqual(info.presentation.publishedAt, published)
        XCTAssertEqual(info.presentation.sourceDurationSeconds, 1_234)
        XCTAssertNil(info.presentation.playableDurationSeconds, "a stored source record is never pre-playable")
        XCTAssertEqual(info.notes, "Stored notes")

        let blankID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "blank", enclosureURL: enclosure)
        let linkless = try PodcastEpisode(
            itemID: blankID, feedID: feedID, feedURL: feedURL, rssGUID: "blank", title: "Undated",
            enclosureURL: enclosure, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(published))
        let unknown = WiltedMacEpisodeInfo(stored: linkless, showTitle: nil)
        XCTAssertNil(unknown.presentation.showTitle)
        XCTAssertNil(unknown.presentation.publishedAt)
        XCTAssertNil(unknown.presentation.sourceDurationSeconds)
    }

    // MARK: Fixtures

    private func info(notes: String? = "Exact notes for this episode") -> WiltedMacEpisodeInfo {
        WiltedMacEpisodeInfo(
            id: "info-episode",
            title: "Info episode",
            presentation: WiltedMacEpisodePresentation(
                title: "Info episode", showTitle: "Info show",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sourceDurationSeconds: 600, playableDurationSeconds: nil),
            notes: notes
        )
    }

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: popoverSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    /// Uses AppKit's in-process controls and accessibility actions; the window
    /// stays hidden and no global pointer, keyboard, or screen state is used.
    private func selectTab(_ label: String, in window: NSWindow) throws {
        let root = try XCTUnwrap(window.contentView)
        func segmentedControl(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap { segmentedControl($0) }.first
        }
        if let control = segmentedControl(root),
           let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == label }) {
            control.setSelected(true, forSegment: index)
            XCTAssertTrue(control.sendAction(control.action, to: control.target), "native segmented action rejected")
            return
        }
        let nodes = accessibilityNodes(in: window)
        let tab = try XCTUnwrap(nodes.first { $0.accessibilityLabel() == label },
                               "Hidden host did not vend the \(label) segment. Native AX nodes: \(describe(nodes))")
        XCTAssertTrue(tab.accessibilityPerformPress(), "native AX press rejected \(label) segment")
    }

    private func accessibilityNodes(in window: NSWindow) -> [NSAccessibilityProtocol] {
        var seen = Set<ObjectIdentifier>()
        var nodes: [NSAccessibilityProtocol] = []
        func visit(_ value: Any, depth: Int) {
            guard depth < 32, let node = value as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
            nodes.append(node)
            for child in node.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
            if let view = value as? NSView {
                for child in view.subviews { visit(child, depth: depth + 1) }
            }
        }
        if let root = window.contentView { visit(root, depth: 0) }
        return nodes
    }

    /// SwiftUI static text can vend its displayed copy as AXValue rather than
    /// AXLabel; native buttons can use AXTitle. Read all three text fields.
    private func semanticText(of nodes: [NSAccessibilityProtocol]) -> String {
        nodes.flatMap { node -> [String] in
            let value = node.accessibilityValue()
            let textValue = (value as? String) ?? (value as? NSAttributedString)?.string
            return [node.accessibilityLabel(), node.accessibilityTitle(), textValue].compactMap { $0 }
        }.joined(separator: "\n")
    }

    private func describe(_ nodes: [NSAccessibilityProtocol]) -> String {
        nodes.map { "\($0.accessibilityRole()?.rawValue ?? "unknown"):\($0.accessibilityIdentifier() ?? ""):\($0.accessibilityLabel() ?? "")" }
            .joined(separator: ", ")
    }

    /// Lets the view's `.task` resume and SwiftUI draw the state it produced.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Waits until the popover's read has run: `.task` starts only once the
    /// view is hosted in its window.
    private func waitForReads(_ stub: TranscriptReadStub, _ expected: Int = 1) async {
        for _ in 0..<300 {
            if await stub.callCount() >= expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the popover never read the transcript")
    }

    private func text(of window: NSWindow, usesLanguageCorrection: Bool = false) throws -> String {
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let size = host.bounds.size
        let scale: CGFloat = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let capture = XCTAttachment(image: NSImage(cgImage: image, size: size))
        capture.name = "Episode info popover"
        capture.lifetime = .keepAlways
        add(capture)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// Counts transcript reads and answers with the one queued result. An actor,
/// so the popover's read and the test's count meet without shared state.
private actor TranscriptReadStub {
    private let result: WiltedMacEpisodeTranscriptLoad
    private var calls = 0

    init(result: WiltedMacEpisodeTranscriptLoad) {
        self.result = result
    }

    nonisolated func source() -> WiltedMacEpisodeInfoSource {
        WiltedMacEpisodeInfoSource(
            loadInfo: { .notFound },
            loadTranscript: { [self] in await record() })
    }

    func callCount() -> Int { calls }

    private func record() -> WiltedMacEpisodeTranscriptLoad {
        calls += 1
        return result
    }
}
