import Foundation
import XCTest
@testable import ArticleExtractionProbeCore

final class ArticleExtractionProbeCoreTests: XCTestCase {
    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    func testManifestDispatchesExactlyTenUniqueFixturesWithMatchingHashes() throws {
        let manifest = try FixtureManifest.load(from: fixturesDirectory)
        XCTAssertEqual(manifest.fixtures.count, 10)
        XCTAssertEqual(Set(manifest.fixtures.map(\.id)).count, 10)
        for fixture in manifest.fixtures {
            let data = try Data(contentsOf: fixturesDirectory.appendingPathComponent(fixture.file))
            XCTAssertEqual(FixtureManifest.sha256(data), fixture.sha256, fixture.id)
            XCTAssertEqual(fixture.license, "MIT")
            XCTAssertTrue(fixture.provenance.lowercased().contains("synthetic"))
        }
    }

    func testCorpusMatchesAllOutcomesMarkersTitlesMetadataAndEmitsStatus() async throws {
        let recorder = StatusRecorder()
        let summary = try await CorpusRunner().run(fixturesDirectory: fixturesDirectory) { id, status in
            recorder.append("\(id):\(status.rawValue)")
        }
        XCTAssertEqual(summary.total, 10)
        XCTAssertEqual(summary.passed, 10)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(Set(summary.results.map(\.id)).count, 10)
        XCTAssertEqual(recorder.values.filter { $0.hasSuffix(":finished") }.count, 10)
    }

    func testMalformedAndCharsetCasesAreExplicitAndExtracted() async throws {
        let manifest = try FixtureManifest.load(from: fixturesDirectory)
        let malformed = try XCTUnwrap(manifest.fixtures.first { $0.id == "malformed" })
        let charset = try XCTUnwrap(manifest.fixtures.first { $0.id == "utf8-charset" })
        XCTAssertTrue(malformed.intentionalCondition.contains("intentionally"))
        XCTAssertTrue(charset.intentionalCondition.contains("UTF-8"))

        for fixture in [malformed, charset] {
            let data = try Data(contentsOf: fixturesDirectory.appendingPathComponent(fixture.file))
            let result = try await NativeStaticExtractor().extract(.init(
                sourceURL: try XCTUnwrap(URL(string: fixture.sourceURL)),
                html: data
            ))
            XCTAssertEqual(result.outcome, .extracted)
            for marker in fixture.expected.bodyMarkers {
                XCTAssertTrue(result.body?.contains(marker) == true, "\(fixture.id): \(marker)")
            }
        }
    }

    func testScriptOnlyIsControlledUnsupportedAndNeverUsesScriptPayload() async throws {
        let manifest = try FixtureManifest.load(from: fixturesDirectory)
        let fixture = try XCTUnwrap(manifest.fixtures.first { $0.id == "script-rendered" })
        let result = try await NativeStaticExtractor().extract(.init(
            sourceURL: try XCTUnwrap(URL(string: fixture.sourceURL)),
            html: try Data(contentsOf: fixturesDirectory.appendingPathComponent(fixture.file))
        ))
        XCTAssertEqual(result.outcome, .controlledUnsupported)
        XCTAssertNil(result.body)
        XCTAssertEqual(result.reason, "javascript-required")
    }

    func testControlledOutcomeFixturesContainNoProbeOracleMarker() throws {
        let manifest = try FixtureManifest.load(from: fixturesDirectory)
        let controlledIDs = ["consent-wall", "paywall-headline-only", "script-rendered"]
        for id in controlledIDs {
            let fixture = try XCTUnwrap(manifest.fixtures.first { $0.id == id })
            let html = try String(contentsOf: fixturesDirectory.appendingPathComponent(fixture.file), encoding: .utf8)
            XCTAssertFalse(html.lowercased().contains("wilted-outcome"), id)
        }
    }

    func testCancellationIsObservableAndDoesNotFinish() async {
        let recorder = StatusRecorder()
        let task = Task {
            await Task.yield()
            return try await NativeStaticExtractor().extract(.init(
                sourceURL: URL(string: "https://example.test/cancel")!,
                html: Data("<html><body><main>content</main></body></html>".utf8)
            )) { recorder.append($0.rawValue) }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cooperative cancellation")
        } catch is CancellationError {
            XCTAssertFalse(recorder.values.contains(ExtractionStatus.finished.rawValue))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidURLFailsBeforeDecodingOrExtraction() async {
        let recorder = StatusRecorder()
        do {
            _ = try await NativeStaticExtractor().extract(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/not-an-http-url"),
                html: Data([0xff, 0xfe])
            )) { recorder.append($0.rawValue) }
            XCTFail("Expected invalid URL")
        } catch let error as ExtractionError {
            XCTAssertEqual(error, .invalidURL)
            XCTAssertEqual(recorder.values, [ExtractionStatus.validatingURL.rawValue])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnknownManifestOperationAndOutcomeFailClosed() throws {
        let original = try String(contentsOf: fixturesDirectory.appendingPathComponent("manifest.json"), encoding: .utf8)
        let changed = original.replacingOccurrences(of: "extract-static-html", with: "execute-browser")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(changed.utf8).write(to: temporary.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try FixtureManifest.load(from: temporary)) { error in
            guard case ManifestError.unsupportedManifest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ExtractionOutcome.self, from: Data("\"browserRequired\"".utf8)))
    }
}

private final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
