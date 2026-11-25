import Foundation
import SwiftUI
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryNotebookViewTests: XCTestCase {
    func testEmptyOfflineAndUnreadableStatesRemainAccessibleInLightAndDark() async throws {
        await HostedAccessibility.prepare()
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }

        fixture.model.notebookPhoneState.bind(ownerToken: nil, deviceID: "phone", generation: 0, reviewHold: false)
        fixture.model.notebookPhoneState.notice = "Saved on this phone · waiting to sync"
        for dark in [false, true] {
            let hosted = HostedView(
                LibraryNotebookView(model: fixture.model, player: fixture.makePlayer()), dark: dark)
            XCTAssertNotNil(hosted.element("wilted-notebook-empty"), "empty state remains visible, dark=\(dark)")
            XCTAssertNotNil(hosted.element("wilted-notebook-notice"), "offline status remains visible, dark=\(dark)")
        }

        let unreadableURL = fixture.scratch.appendingPathComponent("unreadable-notebook.json")
        try Data("not-json".utf8).write(to: unreadableURL)
        let failedModel = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "Offline fixture"),
            store: InMemoryLibraryStore(), deviceID: "phone", mediaCache: fixture.cache,
            notebookOutboxURL: unreadableURL)
        XCTAssertTrue(failedModel.notebookPhoneState.readFailed)
        for dark in [false, true] {
            let hosted = HostedView(
                LibraryNotebookView(model: failedModel, player: fixture.makePlayer()), dark: dark)
            XCTAssertNotNil(hosted.element("wilted-notebook-empty"), "error does not hide retained empty state, dark=\(dark)")
            XCTAssertNotNil(hosted.element("wilted-notebook-notice"), "read error has a visible status, dark=\(dark)")
        }
    }
}
