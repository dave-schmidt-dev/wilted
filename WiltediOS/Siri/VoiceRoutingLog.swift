import Foundation
@preconcurrency import Intents
import OSLog

/// Builds and keeps voice routing records.
///
/// Keeps the last 50 voice routing lines in a small file in the app's own container and logs each
/// line through the system log with public privacy.
final class VoiceRoutingLog: @unchecked Sendable {
    static let maxLines = 50
    static let fileName = "voice-routing.log"

    private static let logger = Logger(subsystem: "com.zerodelta.wilted", category: "VoiceRouting")

    static let shared = VoiceRoutingLog()

    private let lock = NSLock()
    private let fileURL: URL?
    private var buffer: [String] = []

    init(fileURL: URL? = VoiceRoutingLog.defaultFileURL()) {
        self.fileURL = fileURL
        if let fileURL, let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            let loaded = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            self.buffer = Array(loaded.suffix(Self.maxLines))
        }
    }

    static func defaultFileURL() -> URL? {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Wilted", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(fileName, isDirectory: false)
        }
        return nil
    }

    /// Formats a SiriKit request line with all required search and preselection fields.
    static func siriKitLine(path: String, outcome: String, search: INMediaSearch?, prechosen: Bool) -> String {
        VoiceRoutingLine.siriKit(path: path, outcome: outcome, search: search, prechosen: prechosen)
    }

    /// Formats an App Intent request line.
    static func appIntentLine(
        path: String,
        command: String,
        outcome: String? = nil
    ) -> String {
        if let outcome {
            return "\(path): command=\(command), outcome=\(outcome)"
        }
        return "\(path): command=\(command)"
    }

    /// Logs a SiriKit voice routing event.
    func logSiriKit(
        path: String,
        outcome: String,
        search: INMediaSearch?,
        prechosen: Bool
    ) {
        log(Self.stamp() + Self.siriKitLine(path: path, outcome: outcome, search: search, prechosen: prechosen))
    }

    /// Logs an App Intent voice routing event.
    func logAppIntent(
        path: String,
        command: String,
        outcome: String? = nil
    ) {
        log(Self.stamp() + Self.appIntentLine(path: path, command: command, outcome: outcome))
    }

    /// Local date and time, so a line can be matched to a moment in a drive.
    static func stamp(_ date: Date = Date()) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
            .timeZone(separator: .omitted)) + " "
    }

    /// Appends one routing line to the in-memory buffer, writes to disk (keeping the last 50 lines),
    /// and logs through OSLog with public privacy.
    func log(_ line: String) {
        lock.withLock {
            buffer.append(line)
            if buffer.count > Self.maxLines {
                buffer.removeFirst(buffer.count - Self.maxLines)
            }
            if let fileURL {
                let text = buffer.joined(separator: "\n") + "\n"
                try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
        Self.logger.info("\(line, privacy: .public)")
    }

    /// The kept lines, oldest first and newest last.
    func lines() -> [String] {
        lock.withLock { buffer }
    }

    /// Clears both the in-memory buffer and the backing file (used by tests).
    func clear() {
        lock.withLock {
            buffer.removeAll()
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}
