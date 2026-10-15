import Foundation
import XCTest
@testable import WiltedDomain

final class TranscriptWordTests: XCTestCase {
    func testValidWordRoundTripsWithAllFields() throws {
        let word = try TranscriptWord(
            startSeconds: 1.0,
            endSeconds: 1.5,
            text: "Hello",
            rawText: "hello"
        )
        XCTAssertEqual(word.startSeconds, 1.0)
        XCTAssertEqual(word.endSeconds, 1.5)
        XCTAssertEqual(word.text, "Hello")
        XCTAssertEqual(word.rawText, "hello")

        let decoded = try JSONDecoder().decode(TranscriptWord.self, from: JSONEncoder().encode(word))
        XCTAssertEqual(decoded, word)
    }

    func testMinimalWordRoundTripsAndOmitsOptionalKeys() throws {
        let word = try TranscriptWord(startSeconds: 0.0, endSeconds: 0.8, text: "word")
        XCTAssertNil(word.rawText)

        let encoded = try JSONEncoder().encode(word)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNil(jsonObject?["rawText"])
        XCTAssertEqual(jsonObject?["text"] as? String, "word")

        let decoded = try JSONDecoder().decode(TranscriptWord.self, from: encoded)
        XCTAssertEqual(decoded, word)
    }

    func testBackwardDecodeToleratesProvisionalTokenKeys() throws {
        let json = """
        {"startSeconds":1.0,"endSeconds":1.5,"text":"Hello","rawText":"hello","token":" Hello","tokens":[" He","llo"]}
        """
        let decoded = try JSONDecoder().decode(TranscriptWord.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.startSeconds, 1.0)
        XCTAssertEqual(decoded.endSeconds, 1.5)
        XCTAssertEqual(decoded.text, "Hello")
        XCTAssertEqual(decoded.rawText, "hello")

        let reencoded = try JSONEncoder().encode(decoded)
        let jsonObject = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        XCTAssertNil(jsonObject?["token"])
        XCTAssertNil(jsonObject?["tokens"])
    }

    func testIndividualWordsRejectImpossibleTiming() throws {
        XCTAssertThrowsError(try TranscriptWord(startSeconds: -0.5, endSeconds: 1.0, text: "negative"))
        XCTAssertThrowsError(try TranscriptWord(startSeconds: 2.0, endSeconds: 1.0, text: "backwards"))
        XCTAssertThrowsError(try TranscriptWord(startSeconds: .nan, endSeconds: 1.0, text: "nan"))
        XCTAssertThrowsError(try TranscriptWord(startSeconds: 0.0, endSeconds: .infinity, text: "infinity"))
    }

    func testEmptyAndWhitespaceTextAreRejected() throws {
        XCTAssertThrowsError(try TranscriptWord(startSeconds: 0.0, endSeconds: 1.0, text: ""))
        XCTAssertThrowsError(try TranscriptWord(startSeconds: 0.0, endSeconds: 1.0, text: "   \n\t  "))
    }

    func testWhitespaceTrimming() throws {
        let word = try TranscriptWord(
            startSeconds: 0.0,
            endSeconds: 1.0,
            text: "  trimmed  ",
            rawText: "  raw  "
        )
        XCTAssertEqual(word.text, "trimmed")
        XCTAssertEqual(word.rawText, "raw")
    }
}
