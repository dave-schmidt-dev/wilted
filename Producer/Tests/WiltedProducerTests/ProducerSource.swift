import CryptoKit
import Foundation

enum ProducerSource {
    static func workerSourceHash(root: URL) throws -> String {
        let worker = root.appendingPathComponent("Producer/Workers/wilted_pipeline.py")
        var hasher = SHA256()
        hasher.update(data: try Data(contentsOf: worker))

        let package = worker.deletingLastPathComponent().appendingPathComponent("wilted_worker")
        for file in try pythonFiles(in: package) {
            let relativePath = file.path.dropFirst(package.path.count + 1)
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func pipelineSources(root: URL) throws -> [URL] {
        let producer = root.appendingPathComponent("Producer/Sources/WiltedProducer")
        let pipeline = producer.appendingPathComponent("PodcastPreparationPipeline.swift")
        let preparation = producer.appendingPathComponent("Preparation")
        var sources = FileManager.default.fileExists(atPath: pipeline.path) ? [pipeline] : []
        if FileManager.default.fileExists(atPath: preparation.path) {
            let files = try FileManager.default.contentsOfDirectory(
                at: preparation,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            sources += try files
                .filter { $0.pathExtension == "swift" }
                .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return sources
    }

    static func pipelineSourceHash(root: URL) throws -> String {
        let sources = try pipelineSources(root: root)
        let marker = "public static let pipelineSourceHash = \""
        let markerSource = try sources.first { source in
            try String(contentsOf: source, encoding: .utf8).contains(marker)
        }
        guard let markerSource else { throw CocoaError(.fileReadCorruptFile) }
        var hasher = SHA256()
        for source in [markerSource] + sources.filter({ $0 != markerSource }) {
            var contents = try Data(contentsOf: source)
            if source == markerSource {
                var text = try String(contentsOf: source, encoding: .utf8)
                let markerRange = try requireRange(of: marker, in: text)
                let valueStart = markerRange.upperBound
                let valueEnd = try requireQuote(after: valueStart, in: text)
                text.replaceSubrange(valueStart..<valueEnd, with: "<normalized>")
                contents = Data(text.utf8)
            } else {
                let relativePath = source.path.dropFirst(root.path.count + 1)
                hasher.update(data: Data(relativePath.utf8))
                hasher.update(data: Data([0]))
            }
            hasher.update(data: contents)
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func pythonFiles(in package: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: package.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: package,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            if file.lastPathComponent == "__pycache__" {
                enumerator.skipDescendants()
                continue
            }
            guard file.pathExtension == "py" else { continue }
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func requireRange(of marker: String, in text: String) throws -> Range<String.Index> {
        guard let range = text.range(of: marker) else { throw CocoaError(.fileReadCorruptFile) }
        return range
    }

    private static func requireQuote(after index: String.Index, in text: String) throws -> String.Index {
        guard let quote = text[index...].firstIndex(of: "\"") else { throw CocoaError(.fileReadCorruptFile) }
        return quote
    }
}
