import AppKit
import SwiftUI
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacPublicationStatusTests: XCTestCase {
    private func rootText(pending: Bool = false, failed: Bool = false) async throws -> String {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-library-sync", "sent"])
        model.librarySyncActivity.isSyncing = pending
        model.librarySyncActivity.sendFailed = failed
        let text = try WiltedMacHeadless.recognizedText(WiltedMacRootView(model: model), size: CGSize(width: 1400, height: 900)).joined(separator: " ")
        await model.close()
        return text.lowercased()
    }
    func testStartupDoesNotHideUnknownAuthorPublicationAge() async throws {
        let text = try await rootText()
        XCTAssertTrue(text.contains("mac publication unknown"), text)
    }
    func testPendingRoundDisclosesSavedLibrary() async throws {
        let text = try await rootText(pending: true)
        XCTAssertTrue(text.contains("saved library") && text.contains("pending"), text)
    }
    func testFailedRoundDisclosesSavedLibrary() async throws {
        let text = try await rootText(failed: true)
        XCTAssertTrue(text.contains("saved library") && text.contains("failed"), text)
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
        let text = try WiltedMacHeadless.recognizedText(WiltedMacRootView(model: model), size: CGSize(width: 1400, height: 900)).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("mac last published"), text)
        XCTAssertTrue(text.contains("unverified"), text)
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
                    let text = try WiltedMacHeadless.recognizedText(root, size: CGSize(width: width, height: 900)).joined(separator: " ").lowercased()
                    let expected = context == "unknown" ? "mac publication unknown" : "saved mac last published"
                    XCTAssertTrue(text.contains(expected), text)
                    if context == "pending" { XCTAssertTrue(text.contains("refresh pending"), text) }
                    if context == "failed" { XCTAssertTrue(text.contains("refresh failed"), text) }
                    if context == "held" { XCTAssertTrue(text.contains("account review required"), text) }
                }
            }
            await model.close()
        }
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
