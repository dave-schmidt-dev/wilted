import Foundation
import XCTest
@testable import WiltedMac

/// Removes the XCTest host's process-scoped library root after the bundle ends.
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
            try fileManager.removeItem(at: stateDirectory)
        } catch {
            NSLog("Could not remove Wilted XCTest host state at %@: %@", stateDirectory.path, error.localizedDescription)
        }
    }
}
