import Dispatch
import Foundation
import XCTest
@testable import WiltedDomain

final class TimestampTests: XCTestCase {
    func testTimestampValidationRejectsInvalidFormats() {
        let invalidFormats = [
            "",
            "   ",
            "2026-08-17",
            "12:00:00Z",
            "2026-08-17T12:00:00",
            "2026-08-17T12:00:00z",
            "2026-08-17T12:00:00+00:00",
            "2026-08-17T12:00:00-05:00",
            "2026-08-17T12:00:00.Z",
            "2026-08-17 12:00:00Z",
            "2026/08/17T12:00:00Z",
            "2026-08-1aT12:00:00Z",
            "2026-08-17T12:00:00Z ",
            " 2026-08-17T12:00:00Z",
            "2026-08-17T12:00:00Zextra",
            "not-a-timestamp",
        ]

        for invalid in invalidFormats {
            XCTAssertThrowsError(try Timestamp(iso8601: invalid), "expected failure for: \(invalid)") { error in
                guard case let DomainError.invalidValue(field, reason) = error else {
                    return XCTFail("expected DomainError.invalidValue for \(invalid), got \(error)")
                }
                XCTAssertEqual(field, "timestamp")
                XCTAssertEqual(reason, "must be UTC ISO 8601 ending in Z")
            }
        }
    }

    func testParsingMatchesPreviousFormatterAcrossDateAndFractionPrecision() throws {
        let values = [
            "2026-08-17T12:34:56Z",
            "2026-08-17T12:34:56.1Z",
            "2026-08-17T12:34:56.12Z",
            "2026-08-17T12:34:56.123Z",
            "2026-08-17T12:34:56.1234Z",
            "2026-08-17T12:34:56.123456789Z",
            "2024-02-29T23:59:59.999Z",
            // ISO8601DateFormatter historically normalizes these calendar values;
            // timestamp caching must preserve that established behavior.
            "2026-02-31T12:00:00Z",
            "2023-02-29T12:00:00Z",
            "2026-04-31T12:00:00Z",
            "2026-08-17T24:00:00Z",
            "2026-08-17T12:60:00Z",
            "2026-08-17T12:00:60Z",
            "2026-08-17T12:34:56.123Ztail",
            "2026-08-17T12:34:56.123+00:00",
        ]

        for value in values {
            let previousResult = previousFormatterDate(from: value)
            if let previousResult {
                let actual = try Timestamp(iso8601: value)
                XCTAssertEqual(actual.date, previousResult, "parser changed for \(value)")
                XCTAssertEqual(actual.description, previousFormatterString(for: previousResult),
                               "formatter changed for \(value)")
            } else {
                XCTAssertThrowsError(try Timestamp(iso8601: value), "expected previous behavior for: \(value)")
            }
        }
    }

    func testExactSerializedFractionalFormsAndPrecisionRoundTrip() throws {
        // Integer seconds serialize without fractional portion
        let whole = try Timestamp(iso8601: "2026-08-17T12:00:00Z")
        XCTAssertEqual(whole.description, "2026-08-17T12:00:00Z")
        let wholeData = try JSONEncoder().encode(whole)
        XCTAssertEqual(String(decoding: wholeData, as: UTF8.self), #""2026-08-17T12:00:00Z""#)
        XCTAssertEqual(try JSONDecoder().decode(Timestamp.self, from: wholeData), whole)

        // Fractional seconds round-trip exactly
        let fractional = try Timestamp(iso8601: "2026-08-17T12:00:00.125Z")
        XCTAssertEqual(fractional.description, "2026-08-17T12:00:00.125Z")
        let fractionalData = try JSONEncoder().encode(fractional)
        XCTAssertEqual(String(decoding: fractionalData, as: UTF8.self), #""2026-08-17T12:00:00.125Z""#)
        XCTAssertEqual(try JSONDecoder().decode(Timestamp.self, from: fractionalData), fractional)

        // Millisecond precision round-trips
        for fraction in ["001", "050", "125", "500", "999"] {
            let str = "2026-08-17T12:00:00.\(fraction)Z"
            let ts = try Timestamp(iso8601: str)
            XCTAssertEqual(ts.description, str)
            let enc = try JSONEncoder().encode(ts)
            XCTAssertEqual(try JSONDecoder().decode(Timestamp.self, from: enc), ts)
        }

        // Zero-fraction normalizes to integer seconds format
        let zeroFrac = try Timestamp(iso8601: "2026-08-17T12:00:00.000Z")
        XCTAssertEqual(zeroFrac.description, "2026-08-17T12:00:00Z")

        // Comparable preserves fractional ordering
        let t1 = try Timestamp(iso8601: "2026-08-17T12:00:00.124Z")
        let t2 = try Timestamp(iso8601: "2026-08-17T12:00:00.125Z")
        let t3 = try Timestamp(iso8601: "2026-08-17T12:00:00.126Z")
        XCTAssertTrue(t1 < t2)
        XCTAssertTrue(t2 < t3)
        XCTAssertEqual([t3, t1, t2].sorted(), [t1, t2, t3])
    }

    func testConcurrentParsingAndFormatting() {
        let fixtures = [
            "2026-08-17T12:00:00Z",
            "2026-08-17T12:00:00.125Z",
            "2026-08-17T12:00:01.500Z",
            "2026-01-01T00:00:00Z",
            "2024-02-29T23:59:59.999Z",
        ]

        DispatchQueue.concurrentPerform(iterations: 1_000) { i in
            let input = fixtures[i % fixtures.count]
            do {
                let ts = try Timestamp(iso8601: input)
                let desc = ts.description
                XCTAssertTrue(desc.hasSuffix("Z"))
                XCTAssertEqual(ts.description, input)
            } catch {
                XCTFail("Concurrent parse failed for \(input): \(error)")
            }
        }
    }

    private func previousFormatterDate(from value: String) -> Date? {
        guard value.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#,
            options: .regularExpression
        ) != nil else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func previousFormatterString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = date.timeIntervalSince1970.rounded() == date.timeIntervalSince1970
            ? [.withInternetDateTime]
            : [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
