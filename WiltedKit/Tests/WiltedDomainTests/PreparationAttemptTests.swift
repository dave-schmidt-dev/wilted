import Foundation
import XCTest
@testable import WiltedDomain

final class PreparationAttemptTests: XCTestCase {
    func testAttemptRoundTripLegacyAndValidation() throws {
        let attempt = try PreparationAttemptIdentity(requestSequence: 7, attemptCount: 2)
        let status = try PreparationStatus(stage: .extracting, detail: "Working", cancellable: true,
                                          emittedAt: Timestamp(Date()), attempt: attempt)
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(PreparationStatus.self, from: data).attempt, attempt)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "attempt")
        XCTAssertNil(try JSONDecoder().decode(PreparationStatus.self,
            from: JSONSerialization.data(withJSONObject: legacy)).attempt)
        XCTAssertThrowsError(try PreparationAttemptIdentity(requestSequence: 7, attemptCount: 0))
        XCTAssertThrowsError(try JSONDecoder().decode(PreparationAttemptIdentity.self,
            from: Data(#"{"requestSequence":7,"attemptCount":0}"#.utf8)))
        XCTAssertNotEqual(attempt.key, try PreparationAttemptIdentity(requestSequence: 7, attemptCount: 3).key)
    }
}
