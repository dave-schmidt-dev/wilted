import Foundation
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacTestHostIsolationTests: XCTestCase {
    func testDefaultModelStateStaysOutsideTheOwnerLibrary() {
        XCTAssertTrue(WiltedMacModel.hostsTests, "this regression test requires XCTest's app host")

        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())

        assertUsesTestHostState(model, ownerStateDirectory: productionStateDirectory())
    }

    func testLaunchModelStateStaysOutsideTheOwnerLibrary() {
        XCTAssertTrue(WiltedMacModel.hostsTests, "this regression test requires XCTest's app host")

        let model = WiltedMacApp.makeLaunchModel(
            arguments: [], preferences: WiltedMacTestPreferences.ephemeral()
        )

        assertUsesTestHostState(model, ownerStateDirectory: productionStateDirectory())
    }

    private func assertUsesTestHostState(_ model: WiltedMacModel, ownerStateDirectory: URL,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let stateDirectory = model.libraryURL.deletingLastPathComponent()
        XCTAssertFalse(isInside(stateDirectory, ownerStateDirectory),
                       "the library state must not resolve under the owner's directory", file: file, line: line)
        XCTAssertFalse(isInside(model.libraryURL, ownerStateDirectory),
                       "the library must not resolve under the owner's directory", file: file, line: line)
        XCTAssertFalse(isInside(model.mediaDirectory, ownerStateDirectory),
                       "the media directory must not resolve under the owner's directory", file: file, line: line)
    }

    /// Mirrors the production path calculation without creating or opening the
    /// directory, so this test never touches the owner's library.
    private func productionStateDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Wilted", isDirectory: true).standardizedFileURL
    }

    private func isInside(_ candidate: URL, _ directory: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().path
        let directoryPath = directory.resolvingSymlinksInPath().path
        return candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
    }
}
