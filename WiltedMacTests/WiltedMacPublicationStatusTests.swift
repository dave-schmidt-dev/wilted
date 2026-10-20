import AppKit
import SwiftUI
import Vision
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacPublicationStatusTests: XCTestCase {
    func testKnownAndUnknownPublicationStatusIsOneSidebarFooterLine() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])
        for scale in [WiltedTheme.TextScale.standard, .large] {
            model.setTextScale(scale)
            let width = WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: scale)
            let sidebar = WiltedMacSidebar(model: model, mode: .full, onSelect: { _ in })
                .environment(\.wiltedTextScale, scale)
            model.librarySyncActivity.publication = nil
            let unknown = try capturePublicationEvidence(sidebar, model: model, size: CGSize(width: width, height: 700), name: "isolated-unknown-\(scale)")
            XCTAssertTrue(unknown.localizedCaseInsensitiveContains("Device sync status unknown"), "actual width=\(width): \(unknown)")
            model.librarySyncActivity.publication = try LibraryPublication(id: "sidebar-known",
                publishedAt: Date().addingTimeInterval(-300), writerDeviceID: "synthetic-mac")
            let known = try capturePublicationEvidence(sidebar, model: model, size: CGSize(width: width, height: 700), name: "isolated-known-\(scale)")
            let expected = WiltedPublicationAge.macSidebarSummary(
                model.librarySyncActivity.publication?.publishedAt, verified: model.libraryPublicationVerified,
                held: model.libraryAccountStatus?.needsReview == true)
            XCTAssertTrue(known.localizedCaseInsensitiveContains(expected), "actual width=\(width), expected=\(expected): \(known)")
            XCTAssertFalse(model.libraryPublicationVerified)
            XCTAssertTrue(known.localizedCaseInsensitiveContains("Device sync status unknown"), known)
        }
        await model.close()
    }

    func testShippingRootHasNoFullWidthPublicationBand() throws {
        let root = try WiltedMacHeadless.viewSource("WiltedMacRootView.swift")
        XCTAssertFalse(root.contains("WiltedPublicationNotice("))
        let sidebar = try WiltedMacHeadless.viewSource("WiltedMacSidebar.swift")
        XCTAssertTrue(sidebar.contains("wilted-sidebar-publication-status"))
    }

    private func rootText(pending: Bool = false, failed: Bool = false) async throws -> String {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-library-sync", "sent"])
        model.librarySyncActivity.isSyncing = pending
        model.librarySyncActivity.sendFailed = failed
        let text = try capturePublicationEvidence(WiltedMacRootView(model: model), model: model, size: CGSize(width: 1400, height: 900), name: "root-pending-\(pending)-failed-\(failed)")
        await model.close()
        return text.lowercased()
    }
    func testStartupDoesNotHideUnknownAuthorPublicationAge() async throws {
        let text = try await rootText()
        XCTAssertTrue(text.contains("device sync status unknown"), text)
    }
    func testPendingRoundDisclosesSavedLibrary() async throws {
        let text = try await rootText(pending: true)
        XCTAssertTrue(text.contains("device sync status unknown"), text)
        XCTAssertTrue(WiltedPublicationAge.qualifier(verified: false, pending: true, failed: false, held: false)?.contains("pending") == true)
    }
    func testFailedRoundDisclosesSavedLibrary() async throws {
        let text = try await rootText(failed: true)
        XCTAssertTrue(text.contains("device sync status unknown"), text)
        XCTAssertTrue(WiltedPublicationAge.qualifier(verified: false, pending: false, failed: true, held: false)?.contains("failed") == true)
    }
    func testColdBoundReceiptIsShownSavedUnverifiedWithoutOpeningAccountGate() async throws {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("publication-status-cold"), storeBootstrap: { try LocalLibraryStore(url: $0) }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap(); await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        let owner = CloudKitAccountIdentity.token(for: "synthetic-publication-owner")
        try await store.save(libraryAccountBinding: LocalLibraryAccountBinding(state: .bound, ownerToken: owner))
        let receipt = try LibraryPublication(id: "saved-author", publishedAt: Date(timeIntervalSince1970: 1700000000), writerDeviceID: "mac")
        try await WiltedMacLibraryPublicationStore.store(store).save(.init(ownerToken: owner, fulfilled: receipt))
        let fixture = WiltedMacLibraryAccountFixture()
        let transport = InMemoryLibraryTransport(deviceID: "mac", server: InMemoryLibraryServer(writerDeviceID: "mac"))
        XCTAssertTrue(model.startLibrarySyncIfEnabled(environment: ["WILTED_LIBRARY_SYNC": "1"], transport: transport, account: fixture.source))
        await WiltedMacHeadless.eventually("binding hydrated") { model.libraryAccount?.binding != nil }
        await model.librarySyncController?.publicationHydration?.value
        XCTAssertEqual(model.librarySyncActivity.publication, receipt)
        let text = try capturePublicationEvidence(WiltedMacRootView(model: model), model: model, size: CGSize(width: 1400, height: 900), name: "root-cold").lowercased()
        XCTAssertTrue(text.contains("device sync status unknown"), text)
        XCTAssertTrue(model.libraryPublicationQualifier?.contains("unverified") == true)
        XCTAssertFalse(model.libraryAccount?.gate.isOpen ?? true)
        let durable = try await WiltedMacLibraryPublicationStore.store(store).load(owner: owner)
        XCTAssertEqual(durable.fulfilled, receipt)
        XCTAssertNil(durable.pending)
        await model.close()
    }
    func testLateSavedReceiptReadRejectsChangedOwnerBinding() async throws {
        let owner = CloudKitAccountIdentity.token(for: "owner-before")
        let nextOwner = CloudKitAccountIdentity.token(for: "owner-after")
        let binding = try LocalLibraryAccountBinding(state: .bound, ownerToken: owner)
        let box = StatusBindingBox(binding)
        let barrier = PublicationBarrier()
        let receipt = try LibraryPublication(id: "prior", publishedAt: Date(timeIntervalSince1970: 1000), writerDeviceID: "mac")
        let bytes = try JSONEncoder().encode(WiltedMacLibraryPublicationEnvelope(ownerToken: owner, fulfilled: receipt))
        let store = WiltedMacLibraryPublicationStore(loadBytes: { _ in await barrier.hold(); return bytes }, saveBytes: { _, _ in XCTFail("Display hydration must not write") })
        let read = Task { try await store.displayPublication(binding: binding, currentBinding: { await box.value }) }
        await barrier.wait()
        await box.set(try LocalLibraryAccountBinding(state: .quarantined, ownerToken: owner, candidateToken: nextOwner, reason: .ownerMismatch))
        await barrier.release()
        do { _ = try await read.value; XCTFail("Late old-owner receipt was accepted") }
        catch { XCTAssertEqual(error as? LibraryTransportError, .superseded) }
    }
    func testFuturePublicationDateAndMissingReceiptNeverClaimFreshness() {
        let now = Date(timeIntervalSince1970: 2000)
        XCTAssertEqual(WiltedPublicationAge.summary(now.addingTimeInterval(1), verified: true, now: now), "Mac publication clock uncertain")
        XCTAssertEqual(WiltedPublicationAge.summary(nil, verified: true, now: now), "Mac publication unknown")
        let old = WiltedPublicationAge.summary(now.addingTimeInterval(-100), verified: false, now: now)
        XCTAssertTrue(old.hasPrefix("Saved Mac last published"))
        XCTAssertFalse(old.lowercased().contains("fresh"))
        XCTAssertEqual(WiltedPublicationAge.macSidebarSummary(nil, verified: true, held: false, now: now), "Device sync status unknown")
        XCTAssertEqual(WiltedPublicationAge.macSidebarSummary(now.addingTimeInterval(1), verified: true, held: false, now: now), "Device sync status unknown")
    }
    func testSidebarPublicationRequiresVerifiedUnheldOwnerEvenWithSavedTime() {
        let now = Date(timeIntervalSince1970: 2000)
        let saved = now.addingTimeInterval(-300)
        let unknown = "Device sync status unknown"
        XCTAssertEqual(WiltedPublicationAge.macSidebarSummary(saved, verified: false, held: false, now: now), unknown)
        XCTAssertEqual(WiltedPublicationAge.macSidebarSummary(saved, verified: true, held: true, now: now), unknown)
        XCTAssertEqual(WiltedPublicationAge.macSidebarSummary(saved, verified: false, held: true, now: now), unknown)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        XCTAssertEqual(WiltedPublicationAge.macSidebarSummary(saved, verified: true, held: false, now: now),
                       "Sent to devices \(formatter.localizedString(for: saved, relativeTo: now))")
        XCTAssertEqual(WiltedPublicationAge.macSidebarSummary(nil, verified: true, held: false, now: now), unknown)
        XCTAssertEqual(WiltedPublicationAge.macSidebarSummary(now.addingTimeInterval(1), verified: true, held: false, now: now), unknown)
    }

    func testShippingRootAgeStatusRendersAtSystemAndLargeMinimumWidths() async throws {
        for context in ["unknown", "pending", "failed", "held"] {
            let scenario = context == "held" ? "unbound" : "sent"
            let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-library-sync", scenario])
            if context != "unknown" {
                model.librarySyncActivity.publication = try LibraryPublication(id: "render-saved", publishedAt: Date(timeIntervalSince1970: 1700000000), writerDeviceID: "mac")
            }
            model.librarySyncActivity.isSyncing = context == "pending"
            model.librarySyncActivity.sendFailed = context == "failed"
            for (scale, width) in [(WiltedTheme.TextScale.standard, CGFloat(576)), (.large, 672), (.large, 1400)] {
                model.textScale = scale
                for scheme in [ColorScheme.light, .dark] {
                    let root = WiltedMacRootView(model: model).environment(\.colorScheme, scheme)
                    let bitmap = try WiltedMacHeadless.render(root, size: CGSize(width: width, height: 900))
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                    attachment.name = "publication-root-\(context)-\(Int(width))-\(scheme == .dark ? "dark" : "light")"
                    attachment.lifetime = .keepAlways; add(attachment)
                    let text = try capturePublicationEvidence(root, model: model, size: CGSize(width: width, height: 900), name: "root-\(context)-\(scale)-\(Int(width))-\(scheme)", fullSidebar: width == 1400).lowercased()
                    let expected = model.libraryPublicationVerified && model.libraryAccountStatus?.needsReview != true
                        && model.librarySyncActivity.publication != nil ? "sent to devices" : "device sync status unknown"
                    // The icon rail has a status glyph; native help and accessibility retain the exact status.
                    if width == 1400 { XCTAssertTrue(text.contains(expected), text) }
                    XCTAssertEqual(bitmap.pixelsWide, Int(width))
                    if context == "pending" { XCTAssertTrue(model.libraryPublicationQualifier?.contains("refresh pending") == true) }
                    if context == "failed" { XCTAssertTrue(model.libraryPublicationQualifier?.contains("refresh failed") == true) }
                    if context == "held" { XCTAssertTrue(model.libraryPublicationQualifier?.contains("account review required") == true) }
                }
            }
            await model.close()
        }
    }
    /// Uses the actual content proposal. The general OCR helper's 24-point internal margin
    /// would turn a 168-point sidebar into a 120-point sidebar and create test-only clipping.
    private func capturePublicationEvidence<V: View>(
        _ view: V, model: WiltedMacModel, size: CGSize, name: String, fullSidebar: Bool = true
    ) throws -> String {
        let content = view.frame(width: size.width, height: size.height)
        let bitmap = try WiltedMacHeadless.render(content, size: size)
        let image = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        image.name = "footer-native-\(name)"; image.lifetime = .keepAlways; add(image)

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let nodes = nativeAccessibilityNodes(host)
        let footer = nodes.first { $0.identifier == "wilted-sidebar-publication-status" }
        let summary = WiltedPublicationAge.macSidebarSummary(
            model.librarySyncActivity.publication?.publishedAt, verified: model.libraryPublicationVerified,
            held: model.libraryAccountStatus?.needsReview == true)
        let pointSize = WiltedTheme.scaled(NSFont.preferredFont(forTextStyle: .caption1).pointSize, scale: model.textScale)
        let font = NSFont.systemFont(ofSize: pointSize)
        let textWidth = (summary as NSString).size(withAttributes: [.font: font]).width
        let sidebarWidth = WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: model.textScale)
        let available = sidebarWidth - 2 * WiltedTheme.Spacing.small
        if fullSidebar {
            XCTAssertLessThanOrEqual(textWidth, available, "Native font must fit without shrinking or ellipsis")
            if let footer {
                XCTAssertTrue(footer.label.hasPrefix(summary), "Native AX must preserve the exact footer text")
                // Offscreen screen coordinates can differ; a vended footer still needs real extent.
                XCTAssertFalse(footer.frame.isEmpty, "A native AX footer must have a nonempty frame")
                XCTAssertGreaterThanOrEqual(footer.frame.width, textWidth)
            }
        }
        let metrics = XCTAttachment(string: "hostBounds=\(host.bounds) sidebarWidth=\(sidebarWidth) footerAvailable=\(available) font=\(font.fontName) pointSize=\(pointSize) textWidth=\(textWidth) AXFooter=\(String(describing: footer)) AXNodes=\(nodes)")
        metrics.name = "footer-measurements-\(name)"; metrics.lifetime = .keepAlways; add(metrics)

        // Upscale only the drawing; the shipping view still receives its actual point dimensions.
        // English language correction distinguishes a low-resolution y from v without changing UI.
        let doubled = try WiltedMacHeadless.render(
            content.scaleEffect(2, anchor: .topLeading)
                .frame(width: size.width * 2, height: size.height * 2, alignment: .topLeading),
            size: CGSize(width: size.width * 2, height: size.height * 2))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]; request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: XCTUnwrap(doubled.cgImage)).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        if fullSidebar {
            let line = try XCTUnwrap(lines.first(where: { $0.localizedCaseInsensitiveContains("device") }),
                                     "The actual full sidebar must draw a recognized device sync footer line: \(lines)")
            XCTAssertFalse(line.contains("...") || line.contains("…"), "Actual pixels must not truncate the footer: \(line)")
        }
        let ocr = XCTAttachment(string: lines.joined(separator: "\n"))
        ocr.name = "footer-OCR-\(name)"; ocr.lifetime = .keepAlways; add(ocr)
        // Where AppKit vends the native tree, AX establishes exact spelling. Pixel capture and
        // font/bounds checks above independently establish fit; absent AX still requires exact OCR.
        return lines.joined(separator: " ") + (footer.map { " " + $0.label } ?? "")
    }

    private func nativeAccessibilityNodes(_ root: Any) -> [(identifier: String, label: String, frame: CGRect)] {
        var seen = Set<ObjectIdentifier>()
        var result: [(identifier: String, label: String, frame: CGRect)] = []
        func visit(_ value: Any, depth: Int) {
            guard depth < 32, let node = value as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
            result.append((node.accessibilityIdentifier() ?? "", WiltedMacHeadless.accessibilityLabel(of: node) ?? "",
                           node.accessibilityFrame()))
            for child in node.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return result
    }

    func testReviewNamesUnavailableIdentityAndPublicationConsequence() {
        XCTAssertTrue(WiltedMacLibrarySyncStatus.reviewExplanation.lowercased().contains("name unavailable"))
        XCTAssertTrue(WiltedMacLibrarySyncStatus.reviewExplanation.lowercased().contains("send"))
        XCTAssertTrue(WiltedMacLibrarySyncStatus.reviewExplanation.lowercased().contains("keep held"))
    }
}

private actor StatusBindingBox {
    var value: LocalLibraryAccountBinding
    init(_ value: LocalLibraryAccountBinding) { self.value = value }
    func set(_ value: LocalLibraryAccountBinding) { self.value = value }
}
