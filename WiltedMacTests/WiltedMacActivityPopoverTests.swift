import AppKit
import SwiftUI
import Vision
import XCTest
@testable import WiltedMac

/// The Activity popover's content and the sidebar sync line that opens it, rendered offscreen and
/// read back. No test here opens a real popover: that needs a window on screen.
@MainActor
final class WiltedMacActivityPopoverTests: XCTestCase {
    /// `recognizedText` insets the view by 24 points on each side, so the canvas is wider than the content.
    private static let popoverCanvas = CGSize(width: WiltedMacActivityContent.width + 100, height: 520)

    func testContentShowsTheTitleAndTheUploadedAheadCountForTenUploadedTargets() async throws {
        let model = await fixtureModel(media: WiltedMacMediaActivity(preupload: .init(targetCount: 10, uploadedCount: 10)))
        let lines = try WiltedMacHeadless.recognizedText(
            WiltedMacActivityContent(model: model), size: Self.popoverCanvas)
        let text = lines.joined(separator: " ")
        XCTAssertTrue(lines.contains("Activity"), "the title: \(lines)")
        XCTAssertTrue(text.contains("Uploaded ahead"), "the row's label: \(lines)")
        XCTAssertTrue(text.contains("10 of 10 in iCloud"), "the row's value: \(lines)")
        XCTAssertTrue(text.contains("This Mac"), "the second group is drawn too: \(lines)")
        await model.close()
    }

    func testContentSaysICloudStorageIsFullForAStorageFullPause() async throws {
        let model = await fixtureModel(media: Self.storageFull)
        let lines = try WiltedMacHeadless.recognizedText(
            WiltedMacActivityContent(model: model), size: Self.popoverCanvas)
        // The value wraps beside its label, and lines are ordered by height, so a label can be
        // read between the two halves of the value. Only the values are joined.
        let summary = model.activitySummary
        let labels = Set(summary.groups.flatMap { [$0.title] + $0.rows.map(\.label) } + ["Activity"])
        let values = lines.filter { !labels.contains($0) }.joined(separator: " ")
        XCTAssertTrue(values.contains("iCloud storage is full"), "values=\(values) lines=\(lines)")
        XCTAssertTrue(values.contains("Paused until"), "values=\(values) lines=\(lines)")
        await model.close()
    }

    func testFullSidebarStillDrawsItsSyncLine() async throws {
        let model = await fixtureModel(media: nil, arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])
        let sidebar = WiltedMacSidebar(model: model, mode: .full, onSelect: { _ in })
        // The column widens with the text scale (the model starts at Large), as the shell lays it out.
        let size = CGSize(width: WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: model.textScale), height: 700)
        XCTAssertFalse(sidebar.publicationSummary.isEmpty)
        // As plain status text, and in the warning colour while uploads are paused for storage.
        for media in [nil, Self.storageFull] {
            model.librarySyncActivity.media = media
            let lines = try footerLines(sidebar.environment(\.wiltedTextScale, model.textScale), size: size)
            let text = lines.joined(separator: " ")
            XCTAssertTrue(
                text.localizedCaseInsensitiveContains(sidebar.publicationSummary),
                "paused=\(media != nil) expected=\(sidebar.publicationSummary) lines=\(lines)")
            XCTAssertFalse(text.localizedCaseInsensitiveContains("Click for activity"), "the hint is in the help, not drawn: \(lines)")
        }
        await model.close()
    }

    func testRailFooterHelpSaysICloudStorageIsFullAndEndsWithTheClickHint() async throws {
        let model = await fixtureModel(media: Self.storageFull)
        let rail = WiltedMacSidebar(model: model, mode: .rail, onSelect: { _ in })
        XCTAssertTrue(rail.uploadsPausedForStorage)
        XCTAssertTrue(rail.publicationNeedsAttention)
        XCTAssertTrue(
            rail.publicationHelp.contains("Uploads ahead of time are paused: iCloud storage is full."),
            rail.publicationHelp)
        XCTAssertTrue(rail.publicationHelp.hasPrefix(rail.publicationSummary), rail.publicationHelp)
        XCTAssertTrue(rail.publicationHelp.hasSuffix(" Click for activity."), rail.publicationHelp)

        // The rail draws the status as an icon only: the pause changes the pixels (the warning
        // triangle in the warning colour), and clearing it puts the plain icon back.
        let size = CGSize(width: WiltedMacShellLayout.railWidth, height: 700)
        let paused = footerStrip(try WiltedMacHeadless.render(rail, size: size))
        if let footer = accessibilityLabel(of: rail, size: size, identifier: "wilted-sidebar-publication-status") {
            // Offscreen SwiftUI does not always vend its accessibility tree; when it does, it agrees.
            XCTAssertEqual(footer, rail.publicationHelp)
        }
        model.librarySyncActivity.media = WiltedMacMediaActivity(preupload: .init(targetCount: 10, uploadedCount: 2))
        XCTAssertFalse(rail.publicationNeedsAttention)
        let clear = footerStrip(try WiltedMacHeadless.render(rail, size: size))
        XCTAssertFalse(paused.isEmpty)
        XCTAssertNotEqual(paused, clear, "the rail icon shows the pause")
        await model.close()
    }

    func testFooterHelpEndsWithTheClickHintAndNamesStorageOnlyWhileUploadsArePausedForIt() async {
        let model = await fixtureModel(media: nil)
        for mode in [WiltedMacSidebarMode.full, .rail] {
            let sidebar = WiltedMacSidebar(model: model, mode: mode, onSelect: { _ in })
            model.librarySyncActivity.media = nil
            XCTAssertTrue(sidebar.publicationHelp.hasSuffix(" Click for activity."), sidebar.publicationHelp)
            XCTAssertTrue(sidebar.publicationHelp.contains(model.libraryPublicationDetail), sidebar.publicationHelp)
            XCTAssertFalse(sidebar.publicationHelp.contains("storage is full"), sidebar.publicationHelp)
            XCTAssertFalse(sidebar.publicationNeedsAttention)

            // A pause to retry is not a storage problem and does not colour the footer.
            model.librarySyncActivity.media = WiltedMacMediaActivity(preupload: .init(
                targetCount: 10, uploadedCount: 2, pausedUntil: Date().addingTimeInterval(600), pauseReason: .retrying))
            XCTAssertFalse(sidebar.publicationHelp.contains("storage is full"), sidebar.publicationHelp)
            XCTAssertFalse(sidebar.publicationNeedsAttention)

            model.librarySyncActivity.media = Self.storageFull
            XCTAssertTrue(sidebar.publicationHelp.contains("iCloud storage is full"), sidebar.publicationHelp)
            XCTAssertTrue(sidebar.publicationHelp.hasSuffix(" Click for activity."), sidebar.publicationHelp)
            XCTAssertTrue(sidebar.publicationNeedsAttention)
        }
        // A failed round still warns on its own, as it did before the footer was a button.
        model.librarySyncActivity.media = nil
        model.librarySyncActivity.sendFailed = true
        XCTAssertTrue(WiltedMacSidebar(model: model, mode: .rail, onSelect: { _ in }).publicationNeedsAttention)
        await model.close()
    }

    func testSettingsHasNoActivityRows() throws {
        let settings = try WiltedMacHeadless.viewSource("WiltedMacSettingsView.swift")
        XCTAssertFalse(settings.contains("wilted-activity-"), "the Activity rows live in the popover only")
    }

    func testThePopoverHasNoControlsAndTheFooterButtonOpensIt() throws {
        let popover = try WiltedMacHeadless.viewSource("WiltedMacActivityPopover.swift")
        for control in ["Button", "Toggle(", "Menu(", "Picker(", "Link(", "TextField(", ".onTapGesture"] {
            XCTAssertFalse(popover.contains(control), "the popover shows state only; found \(control)")
        }
        XCTAssertTrue(popover.contains(#"identifier: "wilted-activity-\(row.id)""#))
        XCTAssertTrue(popover.contains("TimelineView(.periodic(from: .now, by: 30))"), "the request rate re-reads its counters")
        XCTAssertTrue(popover.contains("await model.refreshMediaActivity()"))

        let sidebar = try WiltedMacHeadless.viewSource("WiltedMacSidebar.swift")
        XCTAssertTrue(sidebar.contains("@State private var isActivityPresented = false"), "the open flag is view state")
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "WiltedMacActivityContent(model: model)", in: sidebar), 1)
        XCTAssertEqual(
            WiltedMacHeadless.occurrences(of: #".accessibilityIdentifier("wilted-sidebar-publication-status")"#, in: sidebar), 1,
            "one footer serves the full sidebar and the rail")
        let start = try XCTUnwrap(sidebar.range(of: "private var publicationFooter: some View"))
        let end = try XCTUnwrap(sidebar.range(of: "func row(_ destination", range: start.upperBound..<sidebar.endIndex))
        let footer = String(sidebar[start.upperBound..<end.lowerBound])
        for needed in [
            "Button {", "isActivityPresented = true", ".buttonStyle(.plain)", ".help(publicationHelp)",
            ".accessibilityLabel(publicationHelp)", #".accessibilityIdentifier("wilted-sidebar-publication-status")"#,
            ".popover(isPresented: $isActivityPresented", "WiltedMacActivityContent(model: model)",
        ] {
            XCTAssertTrue(footer.contains(needed), "the footer button is missing \(needed)")
        }
        XCTAssertFalse(
            footer.contains(".accessibilityElement(children: .ignore)"),
            "that would replace the button with a bare element and lose its press action")
    }

    // MARK: - Fixtures

    private static let storageFull = WiltedMacMediaActivity(preupload: .init(
        targetCount: 10, uploadedCount: 2, pausedUntil: Date().addingTimeInterval(3600), pauseReason: .storageFull))

    /// A fixture model with no running library sync, so the popover's refresh cannot replace `media`.
    private func fixtureModel(
        media: WiltedMacMediaActivity?, arguments: [String] = ["--wilted-ui-fixture-ready"]
    ) async -> WiltedMacModel {
        let model = await WiltedMacHeadless.model(self, arguments, suffix: "activity-popover")
        XCTAssertNil(model.librarySyncController, "a running sync would overwrite the injected activity")
        model.librarySyncActivity.media = media
        return model
    }

    /// The sidebar's text at its actual width. The shared reader's margin would narrow a 168-point
    /// sidebar and clip the footer, so this draws at twice the size instead and lets language
    /// correction tell a small "y" from a "v", as the publication status tests do.
    private func footerLines<V: View>(_ view: V, size: CGSize) throws -> [String] {
        let doubled = try WiltedMacHeadless.render(
            view.frame(width: size.width, height: size.height)
                .scaleEffect(2, anchor: .topLeading)
                .frame(width: size.width * 2, height: size.height * 2, alignment: .topLeading),
            size: CGSize(width: size.width * 2, height: size.height * 2))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: XCTUnwrap(doubled.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// The colours of the bottom 24 points of a 1x render: the rail's status icon and its padding,
    /// below the Ready total, so nothing else in the column can change them.
    private func footerStrip(_ bitmap: NSBitmapImageRep) -> [UInt32] {
        var colors: [UInt32] = []
        for y in max(0, bitmap.pixelsHigh - 24)..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = UInt32((color.redComponent * 255).rounded())
                let green = UInt32((color.greenComponent * 255).rounded())
                let blue = UInt32((color.blueComponent * 255).rounded())
                colors.append((red << 16) | (green << 8) | blue)
            }
        }
        return colors
    }

    /// The accessibility label of the element with `identifier`, or nil when the offscreen view
    /// vends no such element.
    private func accessibilityLabel<V: View>(of view: V, size: CGSize, identifier: String) -> String? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        var seen = Set<ObjectIdentifier>()
        func find(_ value: Any, depth: Int) -> String? {
            guard depth < 32, let node = value as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return nil }
            if node.accessibilityIdentifier() == identifier { return WiltedMacHeadless.accessibilityLabel(of: node) }
            for child in node.accessibilityChildren() ?? [] {
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return find(host, depth: 0)
    }
}
