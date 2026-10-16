import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import WiltedProducer

/// Builds archives and PDFs in-test, so no binary fixtures are checked in.
enum BookTestArchive {
    struct Entry {
        var path: String
        var data: Data
        var symlink = false
        /// What the headers claim the file expands to, when it should differ from the data.
        var claimedSize: UInt32?
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        (0..<8).reduce(UInt32(value)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32.max) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// A stored (uncompressed) zip with unix attributes, so a symlink entry is a real one.
    static func zip(_ entries: [Entry], to url: URL) throws {
        var body = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let size = entry.claimedSize ?? UInt32(entry.data.count)
            let crc = crc32(entry.data)
            let offset = UInt32(body.count)
            body += le(UInt32(0x0403_4B50)) + le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(33))
            body += le(crc) + le(UInt32(entry.data.count)) + le(size) + le(UInt16(name.count)) + le(UInt16(0)) + name + entry.data
            let mode: UInt32 = entry.symlink ? 0xA1FF : 0x81A4
            central += le(UInt32(0x0201_4B50)) + le(UInt16(0x0314)) + le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0))
            central += le(UInt16(0)) + le(UInt16(33)) + le(crc) + le(UInt32(entry.data.count)) + le(size)
            central += le(UInt16(name.count)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0))
            central += le(mode << 16) + le(offset) + name
        }
        var archive = body + central
        archive += le(UInt32(0x0605_4B50)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(entries.count)) + le(UInt16(entries.count))
        archive += le(UInt32(central.count)) + le(UInt32(body.count)) + le(UInt16(0))
        try archive.write(to: url)
    }

    static func text(_ path: String, _ content: String) -> Entry { Entry(path: path, data: Data(content.utf8)) }

    /// A minimal EPUB 3. The manifest lists chapters in reverse so only the spine gives the order.
    static func epubEntries(
        chapters: [(title: String, body: String)], hrefs: [String]? = nil, encryption: String? = nil
    ) -> [Entry] {
        let names = hrefs ?? chapters.indices.map { "ch\($0 + 1).xhtml" }
        let manifest = chapters.indices.reversed().map {
            "<item id=\"c\($0 + 1)\" href=\"\(names[$0])\" media-type=\"application/xhtml+xml\"/>"
        }.joined()
        let spine = chapters.indices.map { "<itemref idref=\"c\($0 + 1)\"/>" }.joined()
        let links = chapters.indices.map { "<li><a href=\"\(names[$0])\">\(chapters[$0].title)</a></li>" }.joined()
        var entries = [
            text("mimetype", "application/epub+zip"),
            text("META-INF/container.xml", """
            <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """),
            text("OEBPS/content.opf", """
            <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">\
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Test Book</dc:title><dc:creator>Ada Author</dc:creator></metadata>\
            <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\
            <item id="font" href="font.otf" media-type="font/otf"/>\(manifest)</manifest><spine>\(spine)</spine></package>
            """),
            text("OEBPS/nav.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>\
            <nav epub:type="toc"><ol>\(links)</ol></nav></body></html>
            """),
            text("OEBPS/font.otf", "not really a font"),
        ]
        for (index, chapter) in chapters.enumerated() where !names[index].contains("..") {
            entries.append(text("OEBPS/\(names[index])", """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>ignored</title></head><body>\(chapter.body)</body></html>
            """))
        }
        if let encryption { entries.append(text("META-INF/encryption.xml", encryption)) }
        return entries
    }

    static func encryption(uri: String, algorithm: String) -> String {
        """
        <?xml version="1.0"?><encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" \
        xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData><enc:EncryptionMethod Algorithm="\(algorithm)"/>\
        <enc:CipherData><enc:CipherReference URI="\(uri)"/></enc:CipherData></enc:EncryptedData></encryption>
        """
    }

    /// A PDF with one drawn line per entry of each page, optionally password-protected and outlined.
    static func pdf(pages: [[String]], password: String? = nil, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [kCGPDFContextTitle: "PDF Test Book"]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
            info[kCGPDFContextEncryptionKeyLength] = 128
        }
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for lines in pages {
            context.beginPDFPage(nil)
            for (index, line) in lines.enumerated() {
                let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                context.textPosition = CGPoint(x: 72, y: 720 - 18 * Double(index))
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A hand-written unencrypted PDF with a top-level outline, since CoreGraphics cannot
    /// resolve outline destinations here. `outline` pairs a title with a zero-based page.
    static func outlinedPDF(pages: [[String]], outline: [(String, Int)], to url: URL) throws {
        let pageBase = 5
        let itemBase = pageBase + 2 * pages.count
        var objects: [Int: String] = [
            1: "<< /Type /Catalog /Pages 2 0 R /Outlines 3 0 R >>",
            2: "<< /Type /Pages /Kids [\(pages.indices.map { "\(pageBase + 2 * $0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>",
            3: "<< /Type /Outlines /First \(itemBase) 0 R /Last \(itemBase + outline.count - 1) 0 R /Count \(outline.count) >>",
            4: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        for (index, lines) in pages.enumerated() {
            let body = lines.enumerated().map { "0 \($0.offset == 0 ? 0 : -18) Td (\($0.element)) Tj" }.joined(separator: " ")
            let stream = "BT /F1 12 Tf 72 720 Td \(body) ET"
            objects[pageBase + 2 * index] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(pageBase + 2 * index + 1) 0 R "
                + "/Resources << /Font << /F1 4 0 R >> >> >>"
            objects[pageBase + 2 * index + 1] = "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        }
        for (index, item) in outline.enumerated() {
            let links = (index > 0 ? " /Prev \(itemBase + index - 1) 0 R" : "") + (index + 1 < outline.count ? " /Next \(itemBase + index + 1) 0 R" : "")
            objects[itemBase + index] = "<< /Title (\(item.0)) /Parent 3 0 R /Dest [\(pageBase + 2 * item.1) 0 R /XYZ 0 792 0]\(links) >>"
        }
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for number in 1...(itemBase + outline.count - 1) {
            offsets.append(pdf.utf8.count)
            pdf += "\(number) 0 obj\n\(objects[number]!)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        pdf += offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        pdf += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: url)
    }
}

@Suite("Book text extractor")
struct BookTextExtractorTests {
    struct Fixture {
        let root: URL
        let scratch: URL
        var extractor: BookTextExtractor

        func archive(_ entries: [BookTestArchive.Entry], name: String = "book.epub") throws -> URL {
            let url = root.appendingPathComponent(name)
            try BookTestArchive.zip(entries, to: url)
            return url
        }

        var scratchEntries: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted() }
    }

    private func fixture(limits: BookExtractionLimits = BookExtractionLimits(), splitWords: Int = 5_000) throws -> Fixture {
        let root = try AudiobookTestAudio.ownedDirectory("book-extract")
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return Fixture(root: root, scratch: scratch, extractor: BookTextExtractor(
            splitWords: splitWords, limits: limits, scratchParent: scratch))
    }

    private func cleanup(_ fixture: Fixture) { try? FileManager.default.removeItem(at: fixture.root) }

    private static let chapters = [
        (title: "Beginnings", body: "<h1>Beginnings</h1><p>It was a dark &amp; stormy night&nbsp;&#8212; truly.</p><p>Second paragraph.</p>"),
        (title: "Middles", body: "<h1>Middles</h1><p>The middle part.</p><script>var ignored = 1;</script>"),
        (title: "Endings", body: "<h1>Endings</h1><p>The end.</p>"),
    ]

    @Test func anEPUBYieldsItsChaptersInSpineOrderWithNavTitles() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let book = try fixture.extractor.extract(from: fixture.archive(BookTestArchive.epubEntries(chapters: Self.chapters)))
        #expect(book.format == "epub")
        #expect(book.title == "The Test Book")
        #expect(book.author == "Ada Author")
        #expect(book.chapters.map(\.title) == ["Beginnings", "Middles", "Endings"])
        #expect(book.chapters[0].text == "Beginnings\n\nIt was a dark & stormy night \u{2014} truly.\n\nSecond paragraph.")
        #expect(book.chapters[1].text == "Middles\n\nThe middle part.")
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func anEPUBWithAnEncryptedSpineDocumentIsRefusedWithAReason() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let encryption = BookTestArchive.encryption(uri: "OEBPS/ch2.xhtml", algorithm: "http://www.w3.org/2001/04/xmlenc#aes128-cbc")
        let url = try fixture.archive(BookTestArchive.epubEntries(chapters: Self.chapters, encryption: encryption))
        do {
            _ = try fixture.extractor.extract(from: url)
            Issue.record("the encrypted book was accepted")
        } catch let BookExtractionError.refused(reason) {
            #expect(reason.contains("encrypted"))
        }
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func anEPUBWithOnlyFontObfuscationIsAccepted() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let encryption = BookTestArchive.encryption(uri: "OEBPS/font.otf", algorithm: "http://www.idpf.org/2008/embedding")
        let book = try fixture.extractor.extract(
            from: fixture.archive(BookTestArchive.epubEntries(chapters: Self.chapters, encryption: encryption)))
        #expect(book.chapters.count == 3)
    }

    @Test func aLockedPDFIsRefusedWithAReason() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let url = fixture.root.appendingPathComponent("locked.pdf")
        try BookTestArchive.pdf(pages: [["Secret page"]], password: "hunter2", to: url)
        do {
            _ = try fixture.extractor.extract(from: url)
            Issue.record("the locked PDF was accepted")
        } catch let BookExtractionError.refused(reason) {
            #expect(reason.contains("locked"))
        }
    }

    @Test func aPDFUsesItsOutlineForChaptersElseGroupsOfPages() throws {
        let fixture = try fixture(splitWords: 12)
        defer { cleanup(fixture) }
        let lines = (1...4).map { ["Page \($0) has exactly six words."] }
        let outlined = fixture.root.appendingPathComponent("outlined.pdf")
        try BookTestArchive.outlinedPDF(pages: lines, outline: [("Alpha", 0), ("Beta", 2)], to: outlined)
        let withOutline = try fixture.extractor.extract(from: outlined)
        #expect(withOutline.format == "pdf")
        #expect(withOutline.chapters.map(\.title) == ["Alpha", "Beta"])
        #expect(withOutline.chapters[0].text.contains("Page 2"))
        #expect(withOutline.chapters[1].text.contains("Page 4"))

        let plain = fixture.root.appendingPathComponent("plain.pdf")
        try BookTestArchive.pdf(pages: lines, to: plain)
        let grouped = try fixture.extractor.extract(from: plain)
        #expect(grouped.chapters.map(\.title) == ["Pages 1 to 2", "Pages 3 to 4"])
    }

    @Test func archivesWithUnsafeEntriesAreRefusedBeforeUnpacking() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let good = BookTestArchive.epubEntries(chapters: Self.chapters)
        let cases: [(String, BookTestArchive.Entry)] = [
            ("dotdot", BookTestArchive.text("../escape.txt", "x")),
            ("absolute", BookTestArchive.text("/etc/escape.txt", "x")),
            ("symlink", BookTestArchive.Entry(path: "OEBPS/link.xhtml", data: Data("/etc/passwd".utf8), symlink: true)),
            ("expanded", BookTestArchive.Entry(path: "OEBPS/big.bin", data: Data("x".utf8), claimedSize: 600_000_000)),
        ]
        for (name, entry) in cases {
            let url = try fixture.archive(good + [entry], name: "\(name).epub")
            do {
                _ = try fixture.extractor.extract(from: url)
                Issue.record("\(name) was accepted")
            } catch let BookExtractionError.refused(reason) {
                #expect(!reason.isEmpty, "\(name)")
            } catch {
                Issue.record("\(name) failed with \(error) instead of a refusal")
            }
            #expect(fixture.scratchEntries.isEmpty, "\(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
    }

    @Test func anArchiveWithTooManyEntriesIsRefused() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let crowd = (0..<5_001).map { BookTestArchive.text("pad/\($0).txt", "") }
        let url = try fixture.archive(BookTestArchive.epubEntries(chapters: Self.chapters) + crowd)
        #expect(throws: BookExtractionError.self) { try fixture.extractor.extract(from: url) }
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func anEntityDeclaringXMLFileIsRefusedBeforeParsing() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        var entries = BookTestArchive.epubEntries(chapters: Self.chapters)
        entries[1] = BookTestArchive.text("META-INF/container.xml", """
        <?xml version="1.0"?><!DOCTYPE container [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;&a;&a;">]>\
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="&b;"/></rootfiles></container>
        """)
        let url = try fixture.archive(entries)
        do {
            _ = try fixture.extractor.extract(from: url)
            Issue.record("the entity-declaring book was accepted")
        } catch let BookExtractionError.refused(reason) {
            #expect(reason.contains("entities"))
        }
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func aDoctypeWithOnlyAnInternalSubsetBracketIsRefusedButABareDoctypeIsNot() throws {
        #expect((UntrustedXML.refusal(in: Data("<!DOCTYPE x [ ]><x/>".utf8), doctype: .allowBare) != nil))
        #expect(!(UntrustedXML.refusal(in: Data("<!DOCTYPE html PUBLIC \"-//W3C//DTD\" \"x.dtd\"><html/>".utf8), doctype: .allowBare) != nil))
        #expect(!(UntrustedXML.refusal(in: Data("<rss/>".utf8), doctype: .allowBare) != nil))
    }

    @Test func anOversizedXMLFileIsRefusedWithAReason() throws {
        var limits = BookExtractionLimits()
        limits.maxXMLBytes = 100
        let fixture = try fixture(limits: limits)
        defer { cleanup(fixture) }
        let url = try fixture.archive(BookTestArchive.epubEntries(chapters: Self.chapters))
        do {
            _ = try fixture.extractor.extract(from: url)
            Issue.record("the book with oversized XML was accepted")
        } catch let BookExtractionError.refused(reason) {
            #expect(reason.contains("larger than"))
        }
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func anOversizedArchiveIsRefusedFromTheTotalsLineAlone() throws {
        var limits = BookExtractionLimits()
        limits.maxEntries = 3
        let fixture = try fixture(limits: limits)
        defer { cleanup(fixture) }
        let url = try fixture.archive(BookTestArchive.epubEntries(chapters: Self.chapters))
        do {
            _ = try fixture.extractor.extract(from: url)
            Issue.record("the oversized archive was accepted")
        } catch let BookExtractionError.refused(reason) {
            #expect(reason.contains("more than 3 entries"))
        }
        #expect(BookTextExtractor.totalEntryCount("12 files, 340 bytes uncompressed, 200 bytes compressed:  41.2%\n") == 12)
        #expect(BookTextExtractor.totalEntryCount("1 file, 2 bytes uncompressed, 2 bytes compressed:  0.0%") == 1)
        #expect(BookTextExtractor.totalEntryCount("nonsense") == nil)
    }

    @Test func theScratchFolderIsGoneAfterAParseFailure() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        var entries = BookTestArchive.epubEntries(chapters: Self.chapters)
        entries[1] = BookTestArchive.text("META-INF/container.xml", "<container><rootfiles>")
        let url = try fixture.archive(entries)
        do {
            _ = try fixture.extractor.extract(from: url)
            Issue.record("the broken book was accepted")
        } catch let BookExtractionError.unreadable(reason) {
            #expect(reason.contains("container.xml"))
        }
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func anOPFReferenceOutsideTheRootIsRefused() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let url = try fixture.archive(BookTestArchive.epubEntries(
            chapters: Self.chapters, hrefs: ["ch1.xhtml", "../../outside.xhtml", "ch3.xhtml"]))
        do {
            _ = try fixture.extractor.extract(from: url)
            Issue.record("the escaping reference was accepted")
        } catch let BookExtractionError.refused(reason) {
            #expect(reason.contains("outside"))
        }
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func aTextFileIsNotABook() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let url = fixture.root.appendingPathComponent("notes.txt")
        try Data("plain text".utf8).write(to: url)
        #expect(throws: BookExtractionError.self) { try fixture.extractor.extract(from: url) }
    }

    @Test func aChapterOverTheSplitSizeIsCutAtParagraphEnds() {
        let paragraphs = (1...6).map { "Paragraph \($0) has five words." }
        let pieces = BookTextExtractor.split(BookChapter(title: "Long", text: paragraphs.joined(separator: "\n\n")), maxWords: 12)
        #expect(pieces.map(\.title) == ["Long", "Long (part 2)", "Long (part 3)"])
        #expect(pieces.allSatisfy { BookTextExtractor.wordCount($0.text) <= 12 })
        #expect(pieces.map(\.text).joined(separator: "\n\n") == paragraphs.joined(separator: "\n\n"))
    }

    @Test func aParagraphOverTheSplitSizeIsCutAtSentenceEnds() {
        let sentences = (1...6).map { "Sentence \($0) is short." }
        let pieces = BookTextExtractor.split(BookChapter(title: "Run", text: sentences.joined(separator: " ")), maxWords: 8)
        #expect(pieces.count == 3)
        #expect(pieces.allSatisfy { BookTextExtractor.wordCount($0.text) <= 8 })
        #expect(pieces.map(\.text).joined(separator: " ") == sentences.joined(separator: " "))
    }
}
