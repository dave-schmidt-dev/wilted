import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedVisualSystemTests {
    func testMacSettingsExposeThisMacLifetimeStatisticsWithStableIdentifiers() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: sourceRoot)
        XCTAssertTrue(source.contains("WiltedScreenCopy.lifetimeStatisticsScope"))
        for identifierName in [
            "WiltedScreenCopy.audioProcessedIdentifier",
            "WiltedScreenCopy.speechGeneratedIdentifier",
            "WiltedScreenCopy.confirmedAdTimeRemovedIdentifier",
            "WiltedScreenCopy.fasterPlaybackTimeSavedIdentifier",
        ] {
            XCTAssertTrue(source.contains(identifierName))
        }
    }

}
