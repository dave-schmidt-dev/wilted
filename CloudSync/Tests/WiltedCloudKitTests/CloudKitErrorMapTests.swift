import CloudKit
import Foundation
import Testing
@testable import WiltedCloudKit

/// The mapped error keeps the server's requested wait, so the transport gate waits as long as iCloud asked.
struct CloudKitErrorMapTests {
    @Test func aRateLimitKeepsTheServersWaitInItsMessage() {
        let error = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 41.2])
        guard case let .cloudKit(code, message) = CloudKitSyncError.map(error) else {
            Issue.record("expected a CloudKit error"); return
        }
        #expect(code == CKError.Code.requestRateLimited.rawValue)
        #expect(message.hasSuffix("Retry after 42 seconds"), "\(message)")
    }

    @Test func anErrorWithoutAWaitKeepsItsDescription() {
        let error = CKError(.serviceUnavailable)
        guard case let .cloudKit(_, message) = CloudKitSyncError.map(error) else {
            Issue.record("expected a CloudKit error"); return
        }
        #expect(message == error.localizedDescription)
        #expect(!message.contains("Retry after"))
    }
}
