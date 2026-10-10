import Foundation
import PDFKit

/// One chapter of a book as plain text. Paragraphs are separated by a blank line.
public struct BookChapter: Sendable, Equatable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

public struct ExtractedBook: Sendable, Equatable {
    /// `"epub"` or `"pdf"`.
    public let format: String
    public let title: String?
    public let author: String?
    public let chapters: [BookChapter]
}

public enum BookExtractionError: Error, Equatable, LocalizedError, Sendable {
    /// Not an EPUB or PDF.
    case unsupported(String)
    /// The book is understood but must not be read: unsafe archive, encrypted or locked content.
    case refused(String)
    case unreadable(String)
    case textTooLarge(limitBytes: Int)
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .unsupported(reason): reason
        case let .refused(reason): "This book was refused: \(reason)"
        case let .unreadable(reason): "This book cannot be read: \(reason)"
        case let .textTooLarge(limit): "The book has more than \(limit / 1_000_000) MB of text."
        case .timedOut: "Unpacking the book took too long."
        case .cancelled: "Reading the book was cancelled."
        }
    }
}

/// Limits on an untrusted book. The defaults are the product limits; tests lower them.
public struct BookExtractionLimits: Sendable, Equatable {
    public var maxEntries = 5_000
    public var maxExpandedBytes: Int64 = 500_000_000
    public var maxTextBytes = 20_000_000
    /// Largest container, package, navigation or encryption XML file.
    public var maxXMLBytes = 8_000_000
    public var unpackTimeout: TimeInterval = 60

    public init() {}
}

/// Reads an EPUB or PDF into chapters of plain text.
///
/// An EPUB is untrusted input. Its listing is checked with `zipinfo` before anything is
/// unpacked; it is unpacked by `ditto` into a scratch folder that is removed on every exit
/// path; the unpacked tree is walked for symlinks and over-size trees; and every path read
/// from the container, package or navigation files must resolve inside that folder.
public struct BookTextExtractor: Sendable {
    /// `synthesis.chapter_split_words` in the b63 baseline.
    public static let defaultSplitWords = 5_000

    public let splitWords: Int
    public let limits: BookExtractionLimits
    private let scratchParent: URL?

    /// - Parameter scratchParent: where the unpack folder is made; the app scratch root when nil.
    public init(
        splitWords: Int = BookTextExtractor.defaultSplitWords,
        limits: BookExtractionLimits = BookExtractionLimits(),
        scratchParent: URL? = nil
    ) {
        self.splitWords = max(splitWords, 1)
        self.limits = limits
        self.scratchParent = scratchParent
    }

    /// - Parameter progress: `(fraction 0...1, detail)`, called on the calling thread.
    public func extract(
        from url: URL,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: (Double, String) -> Void = { _, _ in }
    ) throws -> ExtractedBook {
        let head = try FileHandle(forReadingFrom: url)
        defer { try? head.close() }
        let magic = try head.read(upToCount: 5) ?? Data()
        let book: ExtractedBook
        if magic.starts(with: Data("%PDF".utf8)) {
            book = try extractPDF(url, isCancelled: isCancelled, progress: progress)
        } else if magic.starts(with: Data([0x50, 0x4B, 0x03, 0x04])) {
            book = try extractEPUB(url, isCancelled: isCancelled, progress: progress)
        } else {
            throw BookExtractionError.unsupported("\(url.lastPathComponent) is not an EPUB or PDF.")
        }
        guard !book.chapters.isEmpty else { throw BookExtractionError.unreadable("The book has no text.") }
        return ExtractedBook(
            format: book.format, title: book.title, author: book.author,
            chapters: book.chapters.flatMap { Self.split($0, maxWords: splitWords) })
    }

    // MARK: PDF

    private func extractPDF(
        _ url: URL, isCancelled: @Sendable () -> Bool, progress: (Double, String) -> Void
    ) throws -> ExtractedBook {
        guard let document = PDFDocument(url: url) else { throw BookExtractionError.unreadable("The PDF cannot be opened.") }
        guard !document.isLocked else { throw BookExtractionError.refused("The PDF is locked with a password.") }
        var budget = TextBudget(limit: limits.maxTextBytes)
        var pages: [String] = []
        for index in 0..<document.pageCount {
            if isCancelled() { throw BookExtractionError.cancelled }
            pages.append(Self.pdfPageText(document.page(at: index)?.string ?? ""))
            try budget.add(pages[index])
            progress(0.9 * Double(index + 1) / Double(document.pageCount), "Reading page \(index + 1) of \(document.pageCount)")
        }
        var starts: [(title: String, page: Int)] = []
        for child in (0..<(document.outlineRoot?.numberOfChildren ?? 0)).compactMap({ document.outlineRoot?.child(at: $0) }) {
            guard let page = child.destination?.page else { continue }
            let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { starts.append((title, document.index(for: page))) }
        }
        starts = starts.enumerated().sorted { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }.map(\.element)
        starts = starts.enumerated().filter { $0.offset == 0 || $0.element.page != starts[$0.offset - 1].page }.map(\.element)

        var chapters: [BookChapter] = []
        func add(_ title: String, _ range: Range<Int>) {
            let text = pages[range].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !text.isEmpty { chapters.append(BookChapter(title: title, text: text)) }
        }
        if starts.isEmpty {
            var first = 0
            var words = 0
            for (index, page) in pages.enumerated() {
                let count = Self.wordCount(page)
                if index > first, words + count > splitWords {
                    add("Pages \(first + 1) to \(index)", first..<index)
                    first = index
                    words = 0
                }
                words += count
            }
            if first < pages.count { add("Pages \(first + 1) to \(pages.count)", first..<pages.count) }
        } else {
            if starts[0].page > 0 { add("Beginning", 0..<starts[0].page) }
            for (index, start) in starts.enumerated() {
                add(start.title, start.page..<(index + 1 < starts.count ? starts[index + 1].page : pages.count))
            }
        }
        let attributes = document.documentAttributes
        return ExtractedBook(
            format: "pdf", title: Self.clean(attributes?[PDFDocumentAttribute.titleAttribute] as? String),
            author: Self.clean(attributes?[PDFDocumentAttribute.authorAttribute] as? String), chapters: chapters)
    }

    /// Lines of one paragraph are joined; a blank line ends the paragraph.
    private static func pdfPageText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").reduce(into: [[String]]([[]])) { groups, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { if !groups[groups.count - 1].isEmpty { groups.append([]) } } else { groups[groups.count - 1].append(trimmed) }
            }.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: EPUB

    private func extractEPUB(
        _ url: URL, isCancelled: @Sendable () -> Bool, progress: (Double, String) -> Void
    ) throws -> ExtractedBook {
        progress(0, "Checking the book")
        let work = (scratchParent ?? ScratchParent.url())
            .appendingPathComponent("book-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        try preflight(url, work: work, isCancelled: isCancelled)
        progress(0.1, "Unpacking the book")
        let root = work.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = try Self.run(
            "/usr/bin/ditto", ["-x", "-k", url.path, root.path], work: work, timeout: limits.unpackTimeout,
            isCancelled: isCancelled)
        guard result.status == 0 else { throw BookExtractionError.unreadable("The archive cannot be unpacked: \(result.message)") }
        let tree = try EPUBTree(root: root, maxXMLBytes: limits.maxXMLBytes)
        try tree.verifyUnpacked(limits: limits)
        progress(0.25, "Reading the book")

        let container = try tree.xml("META-INF/container.xml")
        guard let rootfile = container.find("rootfile")?.attributes["full-path"] else {
            throw BookExtractionError.unreadable("container.xml names no package file.")
        }
        let opfPath = try tree.resolve(rootfile, baseDir: "")
        let opf = try tree.xml(opfPath)
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        struct Item { let id: String; let path: String; let type: String; let properties: [String] }
        var items: [String: Item] = [:]
        for node in opf.find("manifest")?.children ?? [] where node.name == "item" {
            guard let id = node.attributes["id"], let href = node.attributes["href"] else { continue }
            items[id] = Item(
                id: id, path: try tree.resolve(href, baseDir: opfDir), type: node.attributes["media-type"] ?? "",
                properties: (node.attributes["properties"] ?? "").split(separator: " ").map(String.init))
        }
        let spine = (opf.find("spine")?.children ?? []).filter { $0.name == "itemref" }.compactMap { ref -> Item? in
            guard let item = ref.attributes["idref"].flatMap({ items[$0] }) else { return nil }
            return item
        }.filter { ["application/xhtml+xml", "text/html"].contains($0.type) && !$0.properties.contains("nav") }
        guard !spine.isEmpty else { throw BookExtractionError.unreadable("The book has no readable pages.") }

        try tree.refuseEncryptedContent(spine: Set(spine.map(\.path)))
        let titles = try chapterTitles(tree, opf: opf, items: items.values.map { ($0.id, $0.path, $0.properties) })

        var budget = TextBudget(limit: limits.maxTextBytes)
        var chapters: [BookChapter] = []
        for (index, item) in spine.enumerated() {
            if isCancelled() { throw BookExtractionError.cancelled }
            let text = HTMLText.plainText(try tree.string(item.path, maxBytes: limits.maxTextBytes))
            try budget.add(text)
            progress(0.25 + 0.7 * Double(index + 1) / Double(spine.count), "Reading chapter \(index + 1) of \(spine.count)")
            if !text.isEmpty { chapters.append(BookChapter(title: titles[item.path] ?? "Chapter \(chapters.count + 1)", text: text)) }
        }
        let metadata = opf.find("metadata")
        return ExtractedBook(
            format: "epub", title: Self.clean(metadata?.find("title")?.allText),
            author: Self.clean(metadata?.find("creator")?.allText), chapters: chapters)
    }

    /// Titles from the EPUB 3 navigation document, else the EPUB 2 NCX, keyed by chapter path.
    private func chapterTitles(
        _ tree: EPUBTree, opf: XMLNode, items: [(id: String, path: String, properties: [String])]
    ) throws -> [String: String] {
        var titles: [String: String] = [:]
        func record(_ href: String?, _ label: String, baseDir: String) {
            guard let href, let path = try? tree.resolve(href, baseDir: baseDir), titles[path] == nil,
                  let title = Self.clean(label) else { return }
            titles[path] = title
        }
        if let nav = items.first(where: { $0.properties.contains("nav") }) {
            let doc = try tree.xml(nav.path)
            let dir = (nav.path as NSString).deletingLastPathComponent
            let toc = doc.descendants("nav").first { $0.attributes["type"] == "toc" } ?? doc.find("nav")
            for link in toc?.descendants("a") ?? [] { record(link.attributes["href"], link.allText, baseDir: dir) }
        }
        if titles.isEmpty, let ncxID = opf.find("spine")?.attributes["toc"], let ncx = items.first(where: { $0.id == ncxID }) {
            let doc = try tree.xml(ncx.path)
            let dir = (ncx.path as NSString).deletingLastPathComponent
            for point in doc.descendants("navPoint") {
                record(point.children.first { $0.name == "content" }?.attributes["src"],
                       point.children.first { $0.name == "navLabel" }?.allText ?? "", baseDir: dir)
            }
        }
        return titles
    }

    /// Checks the archive listing against every limit. Nothing is unpacked yet.
    private func preflight(_ archive: URL, work: URL, isCancelled: @Sendable () -> Bool) throws {
        // `-t` prints one totals line, so an oversized archive is refused without its listing.
        let totals = try Self.run(
            "/usr/bin/zipinfo", ["-t", archive.path], work: work, timeout: limits.unpackTimeout,
            isCancelled: isCancelled, keepStdout: true)
        guard totals.status == 0 else { throw BookExtractionError.unreadable("The archive listing failed: \(totals.message)") }
        if let count = Self.totalEntryCount(totals.stdout), count > limits.maxEntries {
            throw BookExtractionError.refused("The archive has more than \(limits.maxEntries) entries.")
        }
        let result = try Self.run(
            "/usr/bin/zipinfo", ["-l", archive.path], work: work, timeout: limits.unpackTimeout,
            isCancelled: isCancelled, keepStdout: true)
        guard result.status == 0 else { throw BookExtractionError.unreadable("The archive listing failed: \(result.message)") }
        let line = try NSRegularExpression(
            pattern: #"^([-dlcbpsD?])\S{6,9}\s+\S+\s+\S+\s+(\d+)\s+\S+\s+(\d+)\s+\S+\s+\S+\s+\S+\s+(.+)$"#)
        var entries = 0
        var expanded: Int64 = 0
        for text in result.stdout.split(separator: "\n") {
            let row = String(text)
            guard let match = line.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)),
                  let kind = Range(match.range(at: 1), in: row), let size = Range(match.range(at: 2), in: row),
                  let name = Range(match.range(at: 4), in: row) else { continue }
            entries += 1
            let path = String(row[name])
            if row[kind] == "l" { throw BookExtractionError.refused("The archive contains a symbolic link (\(path)).") }
            if path.hasPrefix("/") || path.contains("\\") || path.split(separator: "/").contains("..") {
                throw BookExtractionError.refused("The archive contains an unsafe path (\(path)).")
            }
            expanded += Int64(row[size]) ?? 0
            if entries > limits.maxEntries { throw BookExtractionError.refused("The archive has more than \(limits.maxEntries) entries.") }
            if expanded > limits.maxExpandedBytes {
                throw BookExtractionError.refused("The archive expands to more than \(limits.maxExpandedBytes / 1_000_000) MB.")
            }
        }
        guard entries > 0 else { throw BookExtractionError.unreadable("The archive is empty.") }
    }

    /// Reads the file count from the `zipinfo -t` line ("N files, ...").
    static func totalEntryCount(_ output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let words = line.split(separator: " ")
            if words.count >= 2, words[1].hasPrefix("file"), let count = Int(words[0]) { return count }
        }
        return nil
    }

    // MARK: Subprocess

    struct ProcessResult { let status: Int32; let stdout: String; let message: String }

    /// Runs a tool with an argument array and a deadline. Output goes to files, so a large
    /// listing never fills a pipe. The process is killed on timeout or cancellation.
    static func run(
        _ executable: String, _ arguments: [String], work: URL, timeout: TimeInterval,
        isCancelled: @Sendable () -> Bool, keepStdout: Bool = false
    ) throws -> ProcessResult {
        let outURL = work.appendingPathComponent("\(UUID().uuidString).out")
        let errURL = work.appendingPathComponent("\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { throw BookExtractionError.unreadable("\(executable) did not start.") }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if isCancelled() || Date() > deadline {
                process.terminate()
                process.waitUntilExit()
                throw isCancelled() ? BookExtractionError.cancelled : BookExtractionError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let message = String(decoding: ((try? Data(contentsOf: errURL)) ?? Data()).prefix(300), as: UTF8.self)
        let stdout = keepStdout ? String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self) : ""
        return ProcessResult(status: process.terminationStatus, stdout: stdout, message: message)
    }

    // MARK: Text helpers

    static func clean(_ text: String?) -> String? {
        let trimmed = (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    struct TextBudget {
        let limit: Int
        private var used = 0
        init(limit: Int) { self.limit = limit }
        mutating func add(_ text: String) throws {
            used += text.utf8.count
            if used > limit { throw BookExtractionError.textTooLarge(limitBytes: limit) }
        }
    }

    /// Splits a chapter larger than `maxWords` at paragraph ends. A paragraph that alone
    /// exceeds the size is cut at sentence ends, and a sentence that alone exceeds it at words.
    static func split(_ chapter: BookChapter, maxWords: Int) -> [BookChapter] {
        guard wordCount(chapter.text) > maxWords else { return [chapter] }
        var pieces: [String] = []
        var current: [String] = []
        var words = 0
        func flush() {
            if !current.isEmpty { pieces.append(current.joined(separator: "\n\n")) }
            current = []
            words = 0
        }
        for paragraph in chapter.text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            for unit in units(of: paragraph, maxWords: maxWords) {
                let count = wordCount(unit.text)
                if words > 0, words + count > maxWords { flush() }
                // Units cut from one paragraph stay joined by a space, not a paragraph break.
                if unit.continued, !current.isEmpty { current[current.count - 1] += " " + unit.text } else { current.append(unit.text) }
                words += count
            }
        }
        flush()
        return pieces.enumerated().map {
            BookChapter(title: $0.offset == 0 ? chapter.title : "\(chapter.title) (part \($0.offset + 1))", text: $0.element)
        }
    }

    private static func units(of paragraph: String, maxWords: Int) -> [(text: String, continued: Bool)] {
        guard wordCount(paragraph) > maxWords else { return [(paragraph, false)] }
        var sentences: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { sentences.append(sentence) }
        }
        let parts = sentences.flatMap { sentence -> [String] in
            let words = sentence.split(whereSeparator: \.isWhitespace)
            guard words.count > maxWords else { return [sentence] }
            return stride(from: 0, to: words.count, by: maxWords).map { words[$0..<min($0 + maxWords, words.count)].joined(separator: " ") }
        }
        return parts.enumerated().map { ($0.element, $0.offset > 0) }
    }
}
