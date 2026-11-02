import Foundation
import XCTest
@testable import WiltediOS

/// The system calls background-task launch and expiration handlers on its own queue. Before the
/// fix, a handler written inside main-actor code trapped there (Swift 6 isolation check), so the
/// iPhone crashed the moment Get audio submitted its background download.
final class LibraryBackgroundTransferCallbackTests: XCTestCase {
    func testALaunchHandlerCalledOffTheMainThreadRunsItsBodyOnTheMainThread() async {
        let ran = expectation(description: "body ran")
        let sent = Marker()
        let callback = mainActorCallback { (received: Marker) in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(received === sent)
            ran.fulfill()
        }
        DispatchQueue.global(qos: .utility).async { callback(sent) }
        await fulfillment(of: [ran], timeout: 5)
    }

    func testAnExpirationHandlerCalledOffTheMainThreadRunsItsBodyOnTheMainThread() async {
        let ran = expectation(description: "body ran")
        let callback = mainActorCallback {
            XCTAssertTrue(Thread.isMainThread)
            ran.fulfill()
        }
        DispatchQueue.global(qos: .utility).async { callback() }
        await fulfillment(of: [ran], timeout: 5)
    }
}

private final class Marker: Sendable {}
