import Foundation
import OSLog

/// A normalized, captured log entry extracted from the unified log store.
struct WiltedMacLogArchiveEntry: Equatable, Sendable {
    /// Normalized severity levels representing the unified log entry levels.
    enum Level: Int, Sendable {
        case undefined, debug, info, notice, error, fault

        /// Maps from OSLogEntryLog.Level by case rather than raw integer representation.
        init(_ level: OSLogEntryLog.Level) {
            switch level {
            case .undefined: self = .undefined
            case .debug: self = .debug
            case .info: self = .info
            case .notice: self = .notice
            case .error: self = .error
            case .fault: self = .fault
            @unknown default: self = .undefined
            }
        }

        /// Whether this entry qualifies for inclusion in the rotating archive file.
        var isArchived: Bool { self == .error || self == .fault }
    }

    /// One component of a log message, containing the format literal and typed argument.
    struct Component: Equatable, Sendable {
        var literal: String
        var placeholder: String
        var argument: Argument

        /// The typed parameter extracted from the log message component.
        enum Argument: Equatable, Sendable {
            case none, string(String), signed(Int64), unsigned(UInt64), double(Double), data, redacted
        }

        init(literal: String, placeholder: String, argument: Argument) {
            self.literal = literal
            self.placeholder = placeholder
            self.argument = argument
        }
    }

    typealias Argument = Component.Argument

    var date: Date
    var level: Level
    var subsystem: String
    var category: String
    var components: [Component]

    init(date: Date, level: Level, subsystem: String, category: String, components: [Component]) {
        self.date = date
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.components = components
    }

    /// Creates an archive entry by mapping components from a unified log entry.
    init(_ entry: OSLogEntryLog) {
        self.date = entry.date
        self.level = Level(entry.level)
        self.subsystem = entry.subsystem
        self.category = entry.category
        self.components = entry.components.map { c in
            let placeholder = c.placeholder
            let argument: Argument
            switch c.argumentCategory {
            case .string: argument = c.argumentStringValue.map(Argument.string) ?? .redacted
            case .int64: argument = .signed(c.argumentInt64Value)
            case .uInt64: argument = .unsigned(c.argumentUInt64Value)
            case .double: argument = .double(c.argumentDoubleValue)
            case .data: argument = .data
            case .undefined: argument = placeholder.isEmpty ? .none : .redacted
            @unknown default: argument = .redacted
            }
            return Component(literal: c.formatSubstring, placeholder: placeholder, argument: argument)
        }
    }
}

/// Formatter that transforms archive entries into single-line capped strings under strict privacy rules.
enum WiltedMacLogLine: Sendable {
    static let maximumBytes = 4096

    /// Escapes control characters and backslashes to preserve single-line formatting.
    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": result.append("\\\\")
            case "\n": result.append("\\n")
            case "\r": result.append("\\r")
            case "\t": result.append("\\t")
            default:
                if scalar.properties.generalCategory == .control {
                    result.append("?")
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// Truncates a string on a Character boundary so its UTF-8 count does not exceed `maximumBytes`.
    static func truncateToUTF8Bytes(_ string: String, maximumBytes: Int, suffix: String = "") -> String {
        if string.utf8.count <= maximumBytes { return string }
        let budget = max(0, maximumBytes - suffix.utf8.count)
        var currentBytes = 0, endIndex = string.startIndex
        for index in string.indices {
            let charBytes = string[index].utf8.count
            if currentBytes + charBytes > budget { break }
            currentBytes += charBytes
            endIndex = string.index(after: index)
        }
        return String(string[..<endIndex]) + suffix
    }

    /// Renders an argument according to the unified log privacy rule:
    /// - Parses privacy annotations between `{` and `}` in the placeholder.
    /// - If `private` or `sensitive` is present, renders `<private>` regardless of argument.
    /// - `.string` is shown only when `public` is present; default-privacy strings render as `<private>`.
    /// - Scalars (.signed, .unsigned, .double) are public by default; renders `true`/`false` if `bool` is set.
    /// - `.data` renders `<data>` if `public` is present, else `<private>`.
    /// - `.redacted` renders `<private>`. `.none` renders empty string.
    static func renderArgument(_ component: WiltedMacLogArchiveEntry.Component) -> String {
        let placeholder = component.placeholder
        let annotations: Set<String>
        if let open = placeholder.firstIndex(of: "{"),
           let close = placeholder[open...].firstIndex(of: "}"), open < close {
            let inner = placeholder[placeholder.index(after: open)..<close]
            annotations = Set(inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        } else {
            annotations = []
        }

        if annotations.contains("private") || annotations.contains("sensitive") { return "<private>" }

        switch component.argument {
        case .none: return ""
        case .redacted: return "<private>"
        case .string(let s): return annotations.contains("public") ? escape(s) : "<private>"
        case .signed(let v): return annotations.contains("bool") ? (v != 0 ? "true" : "false") : String(v)
        case .unsigned(let v): return annotations.contains("bool") ? (v != 0 ? "true" : "false") : String(v)
        case .double(let v): return annotations.contains("bool") ? (v != 0 ? "true" : "false") : String(describing: v)
        case .data: return annotations.contains("public") ? "<data>" : "<private>"
        }
    }

    /// Renders an entry to a single line `<timestamp> <level> <subsystem> <category>: <message>`.
    /// Returns nil if the entry level is not archived.
    static func render(_ entry: WiltedMacLogArchiveEntry) -> String? {
        guard entry.level.isArchived else { return nil }

        let timestamp = entry.date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let levelWord = entry.level == .fault ? "fault" : "error"
        let escapedSubsystem = escape(entry.subsystem)
        let escapedCategory = escape(entry.category)

        var message = ""
        for component in entry.components {
            message += escape(component.literal)
            message += renderArgument(component)
        }

        let line = "\(timestamp) \(levelWord) \(escapedSubsystem) \(escapedCategory): \(message)"
        if line.utf8.count <= maximumBytes { return line }
        return truncateToUTF8Bytes(line, maximumBytes: maximumBytes, suffix: " [truncated]")
    }
}

/// Manages writing log lines to a capped file with rotating backups.
struct WiltedMacRotatingLogFile: Sendable {
    /// Writes one record to the open live file. Tests replace it to simulate a short write.
    typealias RecordWriter = @Sendable (FileHandle, Data) throws -> Void

    let url: URL
    let maximumBytes: Int
    let backupCount: Int
    private let writeRecord: RecordWriter

    init(
        url: URL,
        maximumBytes: Int = 1_048_576,
        backupCount: Int = 3,
        writeRecord: @escaping RecordWriter = { try $0.write(contentsOf: $1) }
    ) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.backupCount = backupCount
        self.writeRecord = writeRecord
    }

    /// Derives the backup sibling URL: `<basename>-<index>.<extension>`.
    func backupURL(_ index: Int) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let filename = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
        return directory.appendingPathComponent(filename)
    }

    private func rotate(fileManager: FileManager) throws {
        guard backupCount > 0 else {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        let oldest = backupURL(backupCount)
        if fileManager.fileExists(atPath: oldest.path) { try fileManager.removeItem(at: oldest) }
        if backupCount > 1 {
            for i in stride(from: backupCount - 1, through: 1, by: -1) {
                let src = backupURL(i), dst = backupURL(i + 1)
                if fileManager.fileExists(atPath: src.path) {
                    if fileManager.fileExists(atPath: dst.path) { try fileManager.removeItem(at: dst) }
                    try fileManager.moveItem(at: src, to: dst)
                }
            }
        }
        let first = backupURL(1)
        if fileManager.fileExists(atPath: first.path) { try fileManager.removeItem(at: first) }
        if fileManager.fileExists(atPath: url.path) { try fileManager.moveItem(at: url, to: first) }
    }

    /// Keeps only the newest whole lines of a live file already over the cap (written
    /// under a larger cap or by something else), so no backup exceeds the cap.
    private func trimToCap() throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let cap = UInt64(maximumBytes)
        guard size > cap else { return }
        // One byte before the kept span shows whether it starts on a line boundary.
        try handle.seek(toOffset: size - cap - 1)
        let tail = try handle.readToEnd() ?? Data()
        let kept = tail.firstIndex(of: 0x0A).map { tail[tail.index(after: $0)...] } ?? Data()
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: kept)
    }

    private func ensureLiveFile(fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: url.path) {
            let created = fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            if !created { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Appends lines to the log file, creating directories and rotating as needed.
    func append(_ lines: [String]) throws {
        guard maximumBytes > 0 else { return }
        let directoryURL = url.deletingLastPathComponent(), fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try ensureLiveFile(fileManager: fileManager)

        var handle: FileHandle?
        defer { try? handle?.close() }

        for line in lines {
            var recordLine = line
            if (recordLine.utf8.count + 1) > maximumBytes {
                recordLine = WiltedMacLogLine.truncateToUTF8Bytes(line, maximumBytes: max(0, maximumBytes - 1))
            }
            let recordData = Data((recordLine + "\n").utf8), recordBytes = recordData.count

            if fileManager.fileExists(atPath: url.path) {
                let currentSize: Int
                if let h = handle {
                    currentSize = Int(try h.seekToEnd())
                } else {
                    let attrs = try fileManager.attributesOfItem(atPath: url.path)
                    currentSize = Int(attrs[.size] as? UInt64 ?? 0)
                }
                if currentSize + recordBytes > maximumBytes {
                    if let h = handle { try h.close(); handle = nil }
                    if currentSize > maximumBytes { try trimToCap() }
                    try rotate(fileManager: fileManager)
                }
            }

            let liveHandle: FileHandle
            if let handle {
                liveHandle = handle
            } else {
                try ensureLiveFile(fileManager: fileManager)
                liveHandle = try FileHandle(forWritingTo: url)
                handle = liveHandle
            }
            let offset = try liveHandle.seekToEnd()
            do {
                try writeRecord(liveHandle, recordData)
            } catch {
                // A short write (disk full) would leave half a line in front of the retry.
                try? liveHandle.truncate(atOffset: offset)
                throw error
            }
        }
    }
}

/// Actor that coordinates reading from OSLogStore and archiving entries to rotating disk files.
actor WiltedMacLogArchive {
    typealias Source = @Sendable () throws -> [WiltedMacLogArchiveEntry]

    static let subsystemPrefix = "com.zerodelta.wilted"
    private static let logger = Logger(subsystem: "com.zerodelta.wilted.mac", category: "LogArchive")

    /// How far behind the newest archived entry a late-arriving entry is still written.
    /// Older unseen entries are skipped; they remain in the unified log.
    static let lateness: TimeInterval = 60

    /// One archived line. The rendered text, not the entry, is the identity, because
    /// a NaN argument would make the entry unequal to itself.
    private struct WrittenLine: Hashable {
        var date: Date
        var line: String
    }

    private let file: WiltedMacRotatingLogFile
    private let source: Source
    private var written: [WrittenLine: Int] = [:]
    private var newestWritten: Date?
    private var isFailing = false
    private var periodicTask: Task<Void, Never>?

    init(file: WiltedMacRotatingLogFile, source: @escaping Source) {
        self.file = file
        self.source = source
    }

    /// Reads warning-and-above entries for Wilted subsystems from the current process's unified log store.
    static func currentProcessSource() -> Source {
        return { @Sendable in
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(timeIntervalSinceLatestBoot: 0)
            let predicate = NSPredicate(format: "subsystem BEGINSWITH %@ AND messageType >= %d", subsystemPrefix, 16)
            let entries = try store.getEntries(at: position, matching: predicate)
            var result: [WiltedMacLogArchiveEntry] = []
            for entry in entries {
                if let logEntry = entry as? OSLogEntryLog { result.append(WiltedMacLogArchiveEntry(logEntry)) }
            }
            return result
        }
    }

    private func handleFailure(_ error: Error) {
        if !isFailing {
            isFailing = true
            let nsError = error as NSError
            Self.logger.error("Log archive pass failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
        }
    }

    /// Executes an archive pass and returns the number of lines written.
    ///
    /// Each pass sees every entry since launch, so a line is written only while this
    /// pass has seen it more often than earlier passes wrote it, within `lateness` of
    /// the newest written entry. Lines are written one at a time and counted only after
    /// they land, so a failed write is retried next pass without duplicating the rest.
    @discardableResult
    func archivePass() async -> Int {
        let source = self.source
        let rawEntries: [WiltedMacLogArchiveEntry]
        do {
            rawEntries = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try source()) } catch { continuation.resume(throwing: error) }
                }
            }
        } catch {
            handleFailure(error)
            return 0
        }

        let filtered = rawEntries.filter { $0.level.isArchived && $0.subsystem.hasPrefix(Self.subsystemPrefix) }
        let sorted = filtered.enumerated().sorted { a, b in
            a.element.date != b.element.date ? a.element.date < b.element.date : a.offset < b.offset
        }.map(\.element)
        let horizon = newestWritten?.addingTimeInterval(-Self.lateness)

        var seen: [WrittenLine: Int] = [:]
        var count = 0
        defer { pruneWritten() }
        for entry in sorted {
            if let horizon, entry.date < horizon { continue }
            guard let line = WiltedMacLogLine.render(entry) else { continue }
            let key = WrittenLine(date: entry.date, line: line)
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            guard occurrence >= written[key, default: 0] else { continue }
            do {
                try file.append([line])
            } catch {
                handleFailure(error)
                return count
            }
            written[key, default: 0] += 1
            newestWritten = max(newestWritten ?? entry.date, entry.date)
            count += 1
        }
        isFailing = false
        return count
    }

    /// Forgets lines older than the lateness horizon; later passes skip them anyway.
    private func pruneWritten() {
        guard let newestWritten else { return }
        let horizon = newestWritten.addingTimeInterval(-Self.lateness)
        written = written.filter { $0.key.date >= horizon }
    }

    /// Idempotently starts a periodic task that runs archive passes at the given interval.
    func start(every interval: Duration = .seconds(30)) {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { break }
                guard let self else { break }
                await self.archivePass()
            }
        }
    }

    @MainActor
    static var launch: WiltedMacLogArchive?

    /// Starts the singleton process archive writing to `<stateDirectory>/logs/wilted.log`.
    @MainActor
    static func startForLaunch(stateDirectory: URL) {
        guard launch == nil else { return }
        let logFileURL = stateDirectory.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("wilted.log")
        let file = WiltedMacRotatingLogFile(url: logFileURL)
        let archive = WiltedMacLogArchive(file: file, source: currentProcessSource())
        launch = archive
        Task { await archive.start() }
    }
}
