import Foundation
import XCTest
@testable import WiltedMac

/// Drains the bundle while managed roots remain owned until the host is terminal.
@MainActor
final class WiltedMacTestBundleObserver: NSObject, @preconcurrency XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let stateDirectory = WiltedMacModel.testHostStateDirectory
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stateDirectory.path) else { return }

        do {
            try WiltedMacTestTemporaryState.dispose(root: stateDirectory)
        } catch {
            XCTFail("Could not dispose XCTest host root: \(error)")
        }
    }
}
