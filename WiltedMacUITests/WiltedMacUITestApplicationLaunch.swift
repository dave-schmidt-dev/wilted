import AppKit
import XCTest

/// Sends the public reopen event only to the already-running synthetic test target.
@MainActor
enum WiltedMacUITestApplicationLaunch {
    static func reopenFixture(_ app: XCUIApplication) throws {
        let arguments = app.launchArguments
        guard arguments.contains("--wilted-ui-fixture-ready") || arguments.contains("--wilted-ui-fixture-playing"),
              let stateIndex = arguments.firstIndex(of: "--wilted-ui-fixture-state-directory"),
              arguments.indices.contains(stateIndex + 1) else {
            throw LaunchError.refused("An explicit synthetic fixture and state directory are required.")
        }
        let statePath = URL(fileURLWithPath: arguments[stateIndex + 1]).standardizedFileURL.resolvingSymlinksInPath().path
        let temporaryPath = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard statePath.hasPrefix(temporaryPath + "/wilted-") else {
            throw LaunchError.refused("Fixture state must belong to the test runner temporary directory.")
        }
        let runner = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard runner.lastPathComponent == "WiltedMacUITests-Runner.app" else {
            throw LaunchError.refused("The expected native UI runner bundle layout is unavailable.")
        }
        let products = runner.deletingLastPathComponent()
        guard products.deletingLastPathComponent().lastPathComponent == "Products",
              products.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Build" else {
            throw LaunchError.refused("The UI runner must be inside native build products.")
        }
        let targetURL = products.appendingPathComponent("WiltedMac.app", isDirectory: true)
        let bundleID = "com.zerodelta.wilted.mac"
        guard let target = Bundle(url: targetURL), target.bundleIdentifier == bundleID,
              let executableURL = target.executableURL else {
            throw LaunchError.refused("The sibling test target bundle identity is unavailable.")
        }
        let expectedBundlePath = targetURL.standardizedFileURL.resolvingSymlinksInPath().path
        let expectedExecutablePath = executableURL.standardizedFileURL.resolvingSymlinksInPath().path
        // The installed owner app shares the bundle ID. Only the exact sibling
        // build product participates in the fixture's single-process contract.
        let isSiblingFixture: (NSRunningApplication) -> Bool = { candidate in
            !candidate.isTerminated &&
                candidate.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == expectedBundlePath &&
                candidate.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path == expectedExecutablePath
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter(isSiblingFixture)
        guard running.count == 1, let application = running.first else {
            throw LaunchError.refused("Exactly one already-running sibling fixture target is required.")
        }
        let expectedPID = application.processIdentifier
        let completed = XCTestExpectation(description: "Same-process fixture LaunchServices reopen")
        let result = LaunchResult()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = arguments
        NSWorkspace.shared.openApplication(at: targetURL, configuration: configuration) { reopened, error in
            let failure: String?
            if error != nil {
                failure = "LaunchServices rejected the fixture reopen event."
            } else if let reopened,
                      reopened.processIdentifier == expectedPID,
                      !reopened.isTerminated,
                      reopened.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == expectedBundlePath,
                      reopened.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path == expectedExecutablePath {
                failure = nil
            } else {
                failure = "LaunchServices returned a different process or executable identity."
            }
            result.complete(failure: failure)
            completed.fulfill()
        }
        guard XCTWaiter.wait(for: [completed], timeout: 5) == .completed else {
            throw LaunchError.refused("The fixture reopen callback exceeded its five-second bound.")
        }
        if let failure = result.failure { throw LaunchError.refused(failure) }
        let current = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter(isSiblingFixture)
        guard current.count == 1, let reopened = current.first,
              reopened.processIdentifier == expectedPID, !reopened.isTerminated,
              reopened.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == expectedBundlePath,
              reopened.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path == expectedExecutablePath else {
            throw LaunchError.refused("Fixture identity changed during the reopen event.")
        }
    }

    private enum LaunchError: Error {
        case refused(String)
    }
}

/// The concurrent AppKit callback shares only a locked result with the main-actor waiter.
private final class LaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var failureMessage: String?

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failureMessage
    }

    func complete(failure: String?) {
        lock.lock()
        defer { lock.unlock() }
        failureMessage = failure
    }
}
