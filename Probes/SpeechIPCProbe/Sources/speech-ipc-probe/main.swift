import Foundation
import SpeechIPCProbeCore

private let emitStatus: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data("stage=\(message)\n".utf8))
}

private func emitJSON(_ object: [String: Any], to handle: FileHandle) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    handle.write(data)
    handle.write(Data([0x0A]))
}

private func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    guard let mode = arguments.first, ["selftest", "status", "protocol-mismatch", "tts-cancel"].contains(mode) else {
        throw SpeechIPCError.invalidControlJSON
    }
    guard let socketPath = value(after: "--socket", in: arguments) else {
        throw SpeechIPCError.invalidSocketPath("--socket is required")
    }
    let client = SpeechIPCClient(socketPath: socketPath, status: emitStatus)
    let output: [String: Any]
    switch mode {
    case "selftest":
        output = ["mode": mode, "ok": true, "result": try client.selftest()]
    case "status":
        output = ["mode": mode, "ok": true, "result": try client.statusSnapshot()]
    case "protocol-mismatch":
        output = ["mode": mode, "ok": true, "error": try client.protocolMismatch().jsonObject]
    case "tts-cancel":
        guard let text = value(after: "--text", in: arguments), !text.isEmpty, text.utf8.count <= 500 else {
            throw SpeechIPCError.invalidControlJSON
        }
        output = ["mode": mode, "ok": true, "result": try client.cancelTTSAfterFirstAudio(text: text).jsonObject]
    default:
        fatalError("validated mode")
    }
    emitJSON(output, to: .standardOutput)
} catch {
    emitJSON(["ok": false, "error": String(describing: error)], to: .standardOutput)
    exit(1)
}
