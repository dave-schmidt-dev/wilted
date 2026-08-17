import Foundation

public struct FixtureRun: Codable, Sendable {
    public let id: String
    public let outcome: ExtractionOutcome
    public let passed: Bool
    public let detail: String?
}

public struct CorpusSummary: Codable, Sendable {
    public let total: Int
    public let passed: Int
    public let failed: Int
    public let results: [FixtureRun]
}

public struct CorpusRunner: Sendable {
    private let extractor = NativeStaticExtractor()

    public init() {}

    public func run(
        fixturesDirectory: URL,
        onStatus: @Sendable (String, ExtractionStatus) -> Void = { _, _ in }
    ) async throws -> CorpusSummary {
        let manifest = try FixtureManifest.load(from: fixturesDirectory)
        var runs: [FixtureRun] = []
        for fixture in manifest.fixtures {
            try Task.checkCancellation()
            let fileURL = fixturesDirectory.appendingPathComponent(fixture.file)
            let data = try Data(contentsOf: fileURL)
            guard FixtureManifest.sha256(data) == fixture.sha256 else {
                throw ManifestError.hashMismatch(fixture.id)
            }
            guard let sourceURL = URL(string: fixture.sourceURL) else {
                throw ExtractionError.invalidURL
            }
            let result = try await extractor.extract(.init(sourceURL: sourceURL, html: data)) {
                onStatus(fixture.id, $0)
            }
            let titleMatches = result.title == fixture.expected.title
            let bodyMatches = fixture.expected.bodyMarkers.allSatisfy { result.body?.contains($0) == true }
            let metadataMatches = result.metadata == fixture.expected.metadata
            let passed = result.outcome == fixture.expected.outcome && titleMatches && bodyMatches && metadataMatches
            runs.append(.init(
                id: fixture.id,
                outcome: result.outcome,
                passed: passed,
                detail: passed ? nil : "expected outcome, title, body markers, or metadata did not match"
            ))
        }
        let passed = runs.filter(\.passed).count
        return CorpusSummary(total: runs.count, passed: passed, failed: runs.count - passed, results: runs)
    }
}
