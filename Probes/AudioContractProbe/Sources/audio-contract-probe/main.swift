import AudioContractProbeCore
import Foundation

func printUsage() {
    FileHandle.standardError.write(Data("usage: audio-contract-probe [--output <path>] | --sizing [--output-dir <path>]\n".utf8))
}

var outputURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("wilted-audio-contract-probe-\(UUID().uuidString).m4a")
var sizingMode = false
var sizingOutputDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wilted-audio-contract-sizing-\(UUID().uuidString)")
var index = 1
while index < CommandLine.arguments.count {
    switch CommandLine.arguments[index] {
    case "--sizing":
        sizingMode = true
        index += 1
    case "--output":
        guard index + 1 < CommandLine.arguments.count else {
            printUsage()
            exit(2)
        }
        outputURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        index += 2
    case "--output-dir":
        guard index + 1 < CommandLine.arguments.count else {
            printUsage()
            exit(2)
        }
        sizingOutputDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        index += 2
    case "--help", "-h":
        printUsage()
        exit(0)
    default:
        printUsage()
        exit(2)
    }
}

do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if sizingMode {
        let report = try AudioContractProbe().measureRepresentativeSizes(
            outputDirectory: sizingOutputDirectory
        ) { stage in
            FileHandle.standardError.write(Data("\(stage)\n".utf8))
        }
        FileHandle.standardOutput.write(try encoder.encode(report))
    } else {
        let report = try AudioContractProbe().run(outputURL: outputURL) { stage in
            FileHandle.standardError.write(Data("\(stage)\n".utf8))
        }
        FileHandle.standardOutput.write(try encoder.encode(report))
    }
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("error=\(error.localizedDescription)\n".utf8))
    exit(1)
}
