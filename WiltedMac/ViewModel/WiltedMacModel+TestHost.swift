import Foundation

extension WiltedMacModel {
    /// One temporary state root for an XCTest-hosted app process. Keeping it
    /// process-scoped lets the app composition root and directly constructed
    /// models agree on their test-only library without reaching the owner's.
    static let testHostStateDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment
        let temporaryRoot = environment["WILTED_TEST_TMPDIR"].flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let processID = ProcessInfo.processInfo.processIdentifier
        return temporaryRoot.appendingPathComponent(
            "wilted-test-host-\(processID)-\(UUID().uuidString)", isDirectory: true
        )
    }()
}
