import Foundation
import Testing
import WiltedLibrary
@testable import WiltedProducer

private struct ArticleFixtureLoader: ArticleLoading {
    let html: Data

    func load(_ url: URL, maximumBytes: Int, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> Data {
        onProgress(1)
        return html
    }
}

@Suite("Private article narration")
struct ArticleNarrationCoordinatorTests {
    @Test func resolvedRuntimeUsesBundledHelperAndCheckoutGpuGate() {
        let home = URL(fileURLWithPath: "/fixture-home", isDirectory: true)
        let configuration = ArticleNarrationConfiguration.resolved(home: home)
        let bundledHelper = Bundle.main.url(forResource: "article_voice", withExtension: "py")
        let expectedHelper = bundledHelper
            ?? home.appending(path: "Documents/Projects/wilted/Producer/Runtime/src/wilted/article_voice.py")

        #expect(configuration.helperURL == expectedHelper)
        #expect(configuration.workerDirectory == home.appending(path: "Documents/Projects/wilted/Producer/Workers"))
    }

    @Test func coordinatorExtractsLocallyAndReturnsOnlyAudioAndStoryMetadata() async throws {
        let root = OwnedTestTemp.root.appending(path: "article-narration-test-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let model = home.appending(path: "Documents/Projects/chatterbox/models/chatterbox-turbo-8bit", directoryHint: .isDirectory)
        let references = home.appending(path: "Documents/Projects/chatterbox/reference-audio/prepared", directoryHint: .isDirectory)
        let workers = home.appending(path: "Documents/Projects/wilted/Producer/Workers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        let workerPackage = workers.appending(path: "wilted_worker", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workerPackage, withIntermediateDirectories: true)
        for name in ["__init__.py", "gpu_admission.py", "reporting.py", "constants.py"] {
            try Data().write(to: workerPackage.appending(path: name))
        }
        try Data("model".utf8).write(to: model.appending(path: "model.safetensors"))
        try Data("{}".utf8).write(to: model.appending(path: "config.json"))
        try Data("fixture".utf8).write(to: references.appending(path: "casey-reference.wav"))
        let python = home.appending(path: ".venvs/speech/bin/python")
        let helper = home.appending(path: "Documents/Projects/wilted/Producer/Runtime/src/wilted/article_voice.py")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: python)
        try Data().write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)

        let body = "Full story body stays in the local handoff."
        let html = Data("<html><head><title>Story title</title></head><body><main><p>\(body)</p></main></body></html>".utf8)
        let coordinator = ArticleNarrationCoordinator(
            configuration: ArticleNarrationConfiguration(
                pythonURL: python, helperURL: helper, modelDirectory: model, referenceDirectory: references,
                workerDirectory: workers
            ),
            extractor: NativeArticleExtractor(loader: ArticleFixtureLoader(html: html)),
            synthesize: { textURL, outputURL, voiceID, progress in
                guard voiceID == .caseyKasem,
                      try String(contentsOf: textURL, encoding: .utf8) == body else {
                    throw ArticleNarrationError.invalidRequest
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: textURL.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                guard permissions & 0o777 == 0o600 else { throw ArticleNarrationError.invalidRequest }
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try (Data("RIFF".utf8) + Data(repeating: 0, count: 64)).write(to: outputURL)
                progress(ArticleNarrationProgress(stage: .synthesizing, fraction: 1))
                return ArticleNarrationCoordinator.SynthesisMetadata(duration: 4, byteCount: 68)
            }
        )
        let request = ArticleNarrationRequest(
            requestID: "request-1", storyID: "story-1", originalURL: URL(string: "https://news.example/story")!,
            voiceID: .caseyKasem, voiceRevision: ArticleNarrationCoordinator.voiceRevision(for: .caseyKasem),
            ownerToken: "owner", generation: 0
        )
        let output = root.appending(path: "audio/story.m4a")

        let result = try await coordinator.narrate(request, outputURL: output)

        #expect(result.audioURL == output)
        #expect(result.title == "Story title")
        #expect(result.canonicalURL.absoluteString == "https://news.example/story")
        #expect(result.mediaType == "audio/mp4")
        #expect(result.duration == 4)
        #expect(result.voiceRevision == request.voiceRevision)
        #expect(result.contentHash.count == 64)
        #expect(!String(describing: result).contains(body))
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func unavailableVoiceIsReportedBeforeFetching() async throws {
        let root = OwnedTestTemp.root.appending(path: "article-voice-test-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ArticleNarrationConfiguration(
            pythonURL: root.appending(path: "python"), helperURL: root.appending(path: "helper.py"),
            modelDirectory: root.appending(path: "model"), referenceDirectory: root.appending(path: "refs")
        )
        let coordinator = ArticleNarrationCoordinator(
            configuration: config,
            extractor: NativeArticleExtractor(loader: ArticleFixtureLoader(html: Data()))
        )
        let request = ArticleNarrationRequest(
            requestID: "request-1", storyID: "story-1", originalURL: URL(string: "https://news.example/story")!,
            voiceID: .caseyKasem, voiceRevision: ArticleNarrationCoordinator.voiceRevision(for: .caseyKasem),
            ownerToken: "owner", generation: 1
        )

        do {
            _ = try await coordinator.narrate(request, outputURL: root.appending(path: "audio.m4a"))
            Issue.record("Unavailable narration runtime should fail visibly")
        } catch let error as ArticleNarrationError {
            #expect(error == .runtimeUnavailable)
        }
    }

    @Test func shortTextKeepsBoundedLongInstructionsAndRejectsOverlongAudio() async throws {
        let root = OwnedTestTemp.root.appending(path: "long-short-text-test-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appending(path: "model", directoryHint: .isDirectory)
        let references = root.appending(path: "references", directoryHint: .isDirectory)
        let workers = root.appending(path: "workers", directoryHint: .isDirectory)
        let package = workers.appending(path: "wilted_worker", directoryHint: .isDirectory)
        for directory in [model, references, package] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("model".utf8).write(to: model.appending(path: "model.safetensors"))
        try Data("{}".utf8).write(to: model.appending(path: "config.json"))
        try Data("voice".utf8).write(to: references.appending(path: "casey-reference.wav"))
        for name in ["__init__.py", "gpu_admission.py", "reporting.py", "constants.py"] {
            try Data().write(to: package.appending(path: name))
        }
        let python = root.appending(path: "python")
        let helper = root.appending(path: "article_voice.py")
        try Data().write(to: python)
        try Data().write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)

        let text = String(repeating: "Use extra caution and follow official safety directions. ", count: 120)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinator = ArticleNarrationCoordinator(
            configuration: ArticleNarrationConfiguration(
                pythonURL: python, helperURL: helper, modelDirectory: model, referenceDirectory: references,
                workerDirectory: workers, encoderURL: URL(fileURLWithPath: "/usr/bin/true")),
            extractor: NativeArticleExtractor(loader: ArticleFixtureLoader(html: Data())),
            synthesize: { textURL, outputURL, _, _ in
                guard try String(contentsOf: textURL, encoding: .utf8) == normalizedText else {
                    throw ArticleNarrationError.invalidRequest
                }
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (Data("RIFF".utf8) + Data(repeating: 0, count: 64)).write(to: outputURL)
                return ArticleNarrationCoordinator.SynthesisMetadata(duration: 901, byteCount: 68)
            })
        let output = root.appending(path: "result/alert.m4a")

        #expect(ArticleNarrationCoordinator.maximumShortTextUTF8Bytes == Bulletin.maximumTextUTF8Bytes)
        #expect(ArticleNarrationCoordinator.maximumShortTextDuration == 900)
        do {
            _ = try await coordinator.synthesizeShortText(text, voiceID: .caseyKasem, outputURL: output)
            Issue.record("audio beyond the shared short-alert duration limit must not be offered")
        } catch let error as ArticleNarrationError {
            #expect(error == .invalidAudio)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
