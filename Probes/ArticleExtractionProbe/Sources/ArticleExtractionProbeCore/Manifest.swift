import CryptoKit
import Foundation

public struct FixtureManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let operation: String
    public let provenance: String
    public let license: String
    public let fixtures: [Fixture]

    public struct Fixture: Codable, Sendable {
        public let id: String
        public let file: String
        public let sourceURL: String
        public let sha256: String
        public let provenance: String
        public let license: String
        public let intentionalCondition: String
        public let expected: Expected
    }

    public struct Expected: Codable, Sendable {
        public let outcome: ExtractionOutcome
        public let title: String?
        public let bodyMarkers: [String]
        public let metadata: ArticleMetadata
    }

    public static func load(from directory: URL) throws -> FixtureManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(FixtureManifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.operation == "extract-static-html" else {
            throw ManifestError.unsupportedManifest
        }
        guard manifest.fixtures.count == 10,
              Set(manifest.fixtures.map(\.id)).count == 10,
              Set(manifest.fixtures.map(\.file)).count == 10 else {
            throw ManifestError.invalidCorpus
        }
        return manifest
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ManifestError: Error, LocalizedError {
    case unsupportedManifest
    case invalidCorpus
    case hashMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedManifest: "Unknown manifest schema or operation."
        case .invalidCorpus: "Fixture corpus must contain exactly ten unique entries."
        case .hashMismatch(let id): "Fixture hash mismatch: \(id)"
        }
    }
}
