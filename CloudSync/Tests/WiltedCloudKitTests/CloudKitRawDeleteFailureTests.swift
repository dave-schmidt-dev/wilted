import CloudKit
import XCTest
@testable import WiltedCloudKit

final class CloudKitRawDeleteFailureTests: XCTestCase {
    func testUnknownItemPartialFailuresAreIdempotent() {
        let zone = CKRecordZone.ID(zoneName: "WiltedLibraryZone", ownerName: "_defaultOwner")
        let first = CKRecord.ID(recordName: "devicelink:fixture-a", zoneID: zone)
        let second = CKRecord.ID(recordName: "devicelink:fixture-b", zoneID: zone)
        let missing = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [first: CKError(.unknownItem), second: CKError(.unknownItem)]
        ])

        XCTAssertTrue(CloudKitRawDeleteFailure.isIdempotent(missing))
    }

    func testPartialFailureWithAnyOtherRecordErrorRemainsRetryable() {
        let zone = CKRecordZone.ID(zoneName: "WiltedLibraryZone", ownerName: "_defaultOwner")
        let missingID = CKRecord.ID(recordName: "devicelink:fixture-a", zoneID: zone)
        let failingID = CKRecord.ID(recordName: "devicelink:fixture-b", zoneID: zone)
        let partial = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                missingID: CKError(.unknownItem),
                failingID: CKError(.networkFailure)
            ]
        ])

        XCTAssertFalse(CloudKitRawDeleteFailure.isIdempotent(partial))
    }
}
