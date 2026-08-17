import ArticleExtractionProbeCore
import Foundation

@main
struct ArticleExtractionProbeCLI {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 3, arguments[1] == "--fixtures" else {
                throw CLIError.usage
            }
            let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
            let summary = try await CorpusRunner().run(fixturesDirectory: directory) { id, status in
                let line = "status fixture=\(id) stage=\(status.rawValue)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(summary))
            FileHandle.standardOutput.write(Data("\n".utf8))
            if summary.failed > 0 { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }
}

enum CLIError: Error, LocalizedError {
    case usage
    var errorDescription: String? { "usage: article-extraction-probe --fixtures <directory>" }
}
