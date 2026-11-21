import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacDeviceRemovalPromptTests: XCTestCase {
    func testCancelAndUnconfirmedRemovalNeverCallDelete() async {
        let prompt = WiltedMacDeviceRemovalPrompt()
        var deletes = 0
        await prompt.confirm { deletes += 1 }
        prompt.ask()
        prompt.cancel()
        await prompt.confirm { deletes += 1 }
        XCTAssertEqual(deletes, 0)
        XCTAssertFalse(prompt.isPresented)
    }

    func testConfirmedFailureKeepsPromptForRetryAndPreventsDuplicateDelete() async {
        let prompt = WiltedMacDeviceRemovalPrompt()
        var deletes = 0
        prompt.ask()
        await prompt.confirm {
            deletes += 1
            await prompt.confirm { deletes += 1 }
            throw CocoaError(.fileWriteUnknown)
        }
        XCTAssertEqual(deletes, 1)
        XCTAssertNotNil(prompt.errorMessage)
        XCTAssertTrue(prompt.isPresented)
        await prompt.confirm { deletes += 1 }
        XCTAssertEqual(deletes, 2)
        XCTAssertFalse(prompt.isPresented)
    }

    func testRemovalCopyWarnsOnlyForAnInFlightTransfer() {
        let ordinary = WiltedMacDeviceRemovalConfirmation.message(transferInFlight: false)
        XCTAssertTrue(ordinary.contains("link again later"))
        XCTAssertFalse(ordinary.contains("transfer"))
        XCTAssertTrue(WiltedMacDeviceRemovalConfirmation.message(transferInFlight: true).contains("transfer"))
    }
}
