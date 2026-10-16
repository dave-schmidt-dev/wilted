import Foundation
import Testing
@testable import WiltedProducer

@Suite("XML consumer policy")
struct XMLConsumerPolicyTests {
    private static let sourceURL = URL(string: "https://podcasts.example.test/feed.xml")!
    private static let articleURL = URL(string: "https://blog.example.test/feed.xml")!
    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Podcast feeds

    /// The exact UTF-7 shifted declaration that bypassed both old scanners:
    /// Darwin reached the internal-declaration callback. This fixture did not
    /// demonstrate entity expansion. It is now refused before parsing.
    @Test func podcastRefusesAShiftedUTF7DeclarationBeforeParsing() async {
        let shifted = #"<?xml version="1.0" encoding="UTF-7"?>+ADw-!DOCTYPE root [+ADw-!ENTITY local 'INTERNAL_CANARY'>]><root>before&local;after</root>"#
        await expectPodcast(.malformedXML, Data(shifted.utf8))
    }

    @Test func podcastRefusesEveryDocumentTypeIncludingABareOne() async {
        let document = #"<!DOCTYPE rss><rss><channel><title>Show</title></channel></rss>"#
        await expectPodcast(.externalEntity, Data(document.utf8))
    }

    @Test func podcastRefusesAQuoteHiddenSubset() async {
        let document = #"<!DOCTYPE rss SYSTEM "a>b" [ ]><rss><channel><title>Show</title></channel></rss>"#
        await expectPodcast(.externalEntity, Data(document.utf8))
    }

    @Test func podcastRefusesAnInternalEntityDeclarationWithItsCanary() async {
        let document = #"<!DOCTYPE rss [<!ENTITY local "INTERNAL_CANARY">]><rss><channel><title>Show &local;</title></channel></rss>"#
        await expectPodcast(.externalEntity, Data(document.utf8))
    }

    @Test func podcastRefusesAnEncodingThatContradictsItsBytes() async {
        var document = Data([0xFF, 0xFE])
        document.append(#"<?xml version="1.0" encoding="UTF-8"?><rss><channel><title>Show</title></channel></rss>"#
            .data(using: .utf16LittleEndian)!)
        await expectPodcast(.malformedXML, document)
    }

    @Test func podcastReturnsTextAroundDecoyMarkup() async throws {
        let document = """
        <?xml version="1.0"?>
        <!-- <!DOCTYPE rss [<!ENTITY a "b">]> -->
        <rss><channel>
          <title>Decoys</title>
          <description><![CDATA[<!ENTITY a "b">]]></description>
          <item><title>Episode &amp; more</title><enclosure url="https://cdn.example.test/one.mp3" type="audio/mpeg" /></item>
        </channel></rss>
        """
        let loaded = try await client(Data(document.utf8)).load(Self.sourceURL)
        #expect(loaded.feed.title == "Decoys")
        #expect(loaded.episodes.map(\.title) == ["Episode & more"])
    }

    /// The podcast delegate preserves its existing refusal when Darwin asks
    /// it to resolve an unknown reference, even with both controls disabled.
    @Test func podcastUndeclaredReferenceKeepsResolverRefusal() async {
        let document = #"<rss><channel><title>Show &local; here</title></channel></rss>"#
        await expectPodcast(.externalEntity, Data(document.utf8))
    }

    @Test func podcastRefusesAnOwnedExternalDoctypeBeforeParsing() async throws {
        let root = try AudiobookTestAudio.ownedDirectory("podcast-canary")
        defer { try? FileManager.default.removeItem(at: root) }
        let dtd = root.appendingPathComponent("canary.dtd")
        try Data(#"<!ENTITY local "INTERNAL_CANARY">"#.utf8).write(to: dtd)
        let document = #"<!DOCTYPE rss SYSTEM "\#(dtd.absoluteString)"><rss><channel><title>Show</title><item><title>&local;</title><enclosure url="https://cdn.example.test/one.mp3" type="audio/mpeg" /></item></channel></rss>"#
        await expectPodcast(.externalEntity, Data(document.utf8))
    }

    /// The one resolver the podcast parser has returns nil and is never asked
    /// for an allowed reference; nothing here adds a new abort policy.
    @Test func podcastResolverReturnsNil() {
        let delegate = PodcastRSSParser(feedURL: Self.sourceURL, createdAt: Self.fixedNow)
        let parser = UntrustedXML.makeParser(Data("<rss/>".utf8))
        #expect(delegate.parser(parser, resolveExternalEntityName: "local", systemID: nil) == nil)
    }

    @Test func podcastInternalDeclarationCallbackRefusesDirectly() {
        let delegate = PodcastRSSParser(feedURL: Self.sourceURL, createdAt: Self.fixedNow)
        let parser = UntrustedXML.makeParser(Data("<rss/>".utf8))
        delegate.parser(parser, foundInternalEntityDeclarationWithName: "local", value: "CANARY")
        #expect(throws: PodcastFeedClientError.externalEntity) {
            try delegate.parse(Data("<rss><channel><title>Show</title></channel></rss>".utf8))
        }
    }

    // MARK: - Article feeds

    @Test func articleFeedRefusesAShiftedUTF7DeclarationBeforeParsing() {
        let shifted = #"<?xml version="1.0" encoding="UTF-7"?>+ADw-!DOCTYPE root [+ADw-!ENTITY local 'INTERNAL_CANARY'>]><root>before&local;after</root>"#
        #expect(throws: ArticleFeedParseError.malformedXML) {
            try ArticleFeedParser.parse(Data(shifted.utf8), feedURL: Self.articleURL)
        }
    }

    /// The old byte scan broke at the first `>` and missed this bracket, which
    /// sits after a quoted system literal; the typed classifier refuses it.
    @Test func articleFeedRefusesAQuoteHiddenSubsetBeforeParsing() {
        let document = #"<?xml version="1.0"?><!DOCTYPE rss SYSTEM "a>b" [ ]><rss version="2.0"><channel><title>Decoys</title></channel></rss>"#
        #expect(throws: ArticleFeedParseError.externalEntity) {
            try ArticleFeedParser.parse(Data(document.utf8), feedURL: Self.articleURL)
        }
    }

    @Test func articleFeedRefusesAnEncodingThatContradictsItsBytes() {
        var document = Data([0xFF, 0xFE])
        document.append(#"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Decoys</title></channel></rss>"#
            .data(using: .utf16LittleEndian)!)
        #expect(throws: ArticleFeedParseError.malformedXML) {
            try ArticleFeedParser.parse(document, feedURL: Self.articleURL)
        }
    }

    @Test func articleFeedReturnsTextAroundDecoyMarkup() throws {
        let document = """
        <?xml version="1.0"?>
        <?decoy "<!DOCTYPE rss [<!ENTITY a 'b'>]>"?>
        <!-- <!DOCTYPE rss [<!ENTITY a "b">]> -->
        <rss version="2.0"><channel>
          <title>Decoys</title>
          <description><![CDATA[<!ENTITY a "b">]]></description>
          <item title="a>b[c"><title>Post &amp; more</title><link>https://blog.example.test/p/1</link></item>
        </channel></rss>
        """
        let parsed = try ArticleFeedParser.parse(Data(document.utf8), feedURL: Self.articleURL)
        #expect(parsed.title == "Decoys")
        #expect(parsed.items.map(\.title) == ["Post & more"])
    }

    @Test func articleFeedKeepsAllowedReferences() throws {
        let document = #"<rss version="2.0"><channel><title>Show</title><item><title>A &amp; B &#233;</title><link>https://blog.example.test/p/1</link></item></channel></rss>"#
        let parsed = try ArticleFeedParser.parse(Data(document.utf8), feedURL: Self.articleURL)
        #expect(parsed.title == "Show")
        #expect(parsed.items.map(\.title) == ["A & B é"])
    }

    @Test func articleFeedUndeclaredReferenceStaysMalformed() {
        let document = #"<rss version="2.0"><channel><title>Show</title><item><title>A &local; B</title><link>https://blog.example.test/p/1</link></item></channel></rss>"#
        #expect(throws: ArticleFeedParseError.malformedXML) {
            try ArticleFeedParser.parse(Data(document.utf8), feedURL: Self.articleURL)
        }
    }

    @Test func articleFeedReadsProvenLegacyEncodings() throws {
        var latin = Data(#"<?xml version="1.0" encoding="ISO-8859-1"?><rss version="2.0"><channel><title>Caf"#.utf8)
        latin.append(contentsOf: [0xE9])
        latin.append(contentsOf: Data(#"</title><item><title>Post</title><link>https://blog.example.test/p/1</link></item></channel></rss>"#.utf8))
        let accented = try ArticleFeedParser.parse(latin, feedURL: Self.articleURL)
        #expect(accented.title == "Café")

        var cp1252 = Data(#"<?xml version="1.0" encoding="windows-1252"?><rss version="2.0"><channel><title>"#.utf8)
        cp1252.append(contentsOf: [0x93, 0x48, 0x69, 0x94])
        cp1252.append(contentsOf: Data(#"</title><item><title>Post</title><link>https://blog.example.test/p/1</link></item></channel></rss>"#.utf8))
        let smart = try ArticleFeedParser.parse(cp1252, feedURL: Self.articleURL)
        #expect(smart.title == "“Hi”")
    }

    @Test func articleFeedNeverExpandsAnOwnedExternalCanary() throws {
        let root = try AudiobookTestAudio.ownedDirectory("article-canary")
        defer { try? FileManager.default.removeItem(at: root) }
        let dtd = root.appendingPathComponent("canary.dtd")
        try Data(#"<!ENTITY local "INTERNAL_CANARY">"#.utf8).write(to: dtd)
        let document = #"<?xml version="1.0"?><!DOCTYPE rss SYSTEM "\#(dtd.absoluteString)"><rss version="2.0"><channel><title>Show</title><item><title>&local;</title><link>https://blog.example.test/p/1</link></item></channel></rss>"#
        let parsed = try ArticleFeedParser.parse(Data(document.utf8), feedURL: Self.articleURL)
        #expect(parsed.title == "Show")
        #expect(parsed.items.map(\.title) == ["https://blog.example.test/p/1"])
        #expect(!parsed.items.contains { $0.title.contains("INTERNAL_CANARY") })
    }

    // MARK: - Helpers

    private func client(_ data: Data) -> PodcastFeedClient {
        PodcastFeedClient(loader: XMLPolicyLoader(data: data, url: Self.sourceURL), now: { Self.fixedNow })
    }

    private func expectPodcast(_ expected: PodcastFeedClientError, _ data: Data) async {
        do {
            _ = try await client(data).load(Self.sourceURL)
            Issue.record("Expected \(expected)")
        } catch let error as PodcastFeedClientError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private struct XMLPolicyLoader: PodcastFeedLoading {
    let data: Data
    let url: URL

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: self.url, statusCode: 200, data: data)
    }
}

@Suite("EPUB XML policy")
struct XMLConsumerPolicyBookTests {
    private static let chapters = [(title: "Beginnings", body: "<p>Hello</p>")]

    @Test func epubRefusesAShiftedUTF7DeclarationBeforeParsing() throws {
        let fixture = try fixture(container: #"<?xml version="1.0" encoding="UTF-7"?>+ADw-!DOCTYPE container [+ADw-!ENTITY local 'INTERNAL_CANARY'>]><container/>"#)
        defer { fixture.remove() }
        do {
            _ = try fixture.extractor.extract(from: fixture.archive)
            Issue.record("the UTF-7 container was accepted")
        } catch let BookExtractionError.refused(reason) {
            #expect(reason.contains("UTF-7"))
        }
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func epubRefusesAQuoteHiddenSubsetBeforeParsing() throws {
        let container = #"<?xml version="1.0"?><!DOCTYPE container SYSTEM "a>b" [ ]><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        let fixture = try fixture(container: container)
        defer { fixture.remove() }
        do {
            _ = try fixture.extractor.extract(from: fixture.archive)
            Issue.record("the quote-hidden subset was accepted")
        } catch let BookExtractionError.refused(reason) {
            #expect(reason.contains("entities"))
        }
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func epubRefusesAnEntityDeclarationBeforeParsing() throws {
        let container = #"<!ENTITY local "INTERNAL_CANARY"><?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        let fixture = try fixture(container: container)
        defer { fixture.remove() }
        do {
            _ = try fixture.extractor.extract(from: fixture.archive)
            Issue.record("the entity declaration was accepted")
        } catch let BookExtractionError.refused(reason) {
            #expect(reason.contains("entities"))
        }
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func epubRefusesATruncatedEncodingBeforeParsing() throws {
        let fixture = try fixture(containerData: Data([0xFF, 0xFE, 0x3C]))
        defer { fixture.remove() }
        do {
            _ = try fixture.extractor.extract(from: fixture.archive)
            Issue.record("the truncated container was accepted")
        } catch let BookExtractionError.unreadable(reason) {
            #expect(reason.contains("container.xml"))
        }
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func epubReadsAProvenLegacyEncoding() throws {
        var container = Data(#"<?xml version="1.0" encoding="ISO-8859-1"?><!-- Caf"#.utf8)
        container.append(contentsOf: [0xE9])
        container.append(contentsOf: Data(#" --><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#.utf8))
        let fixture = try fixture(containerData: container)
        defer { fixture.remove() }
        let book = try fixture.extractor.extract(from: fixture.archive)
        #expect(book.title == "The Test Book")
        #expect(book.chapters.count == 1)
        #expect(fixture.scratchEntries.isEmpty)
    }

    @Test func epubNeverExpandsAnOwnedExternalCanary() throws {
        let canaryRoot = try AudiobookTestAudio.ownedDirectory("epub-canary")
        defer { try? FileManager.default.removeItem(at: canaryRoot) }
        let dtd = canaryRoot.appendingPathComponent("canary.dtd")
        try Data(#"<!ENTITY local "INTERNAL_CANARY">"#.utf8).write(to: dtd)
        let container = #"<?xml version="1.0"?><!DOCTYPE container SYSTEM "\#(dtd.absoluteString)"><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="&local;" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        let fixture = try fixture(container: container)
        defer { fixture.remove() }
        do {
            let book = try fixture.extractor.extract(from: fixture.archive)
            Issue.record("the owned DTD was expanded into \(book.title)")
        } catch let BookExtractionError.refused(reason) {
            #expect(reason == "The book refers to an unsafe path ().")
            #expect(!reason.contains("INTERNAL_CANARY"))
        }
        #expect(fixture.scratchEntries.isEmpty)
    }

    // MARK: - Fixtures

    private struct EPUBFixture {
        let root: URL
        let scratch: URL
        let extractor: BookTextExtractor
        let archive: URL

        func remove() { try? FileManager.default.removeItem(at: root) }
        var scratchEntries: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted()
        }
    }

    private func fixture(container: String) throws -> EPUBFixture {
        try fixture(containerData: Data(container.utf8))
    }

    private func fixture(containerData: Data) throws -> EPUBFixture {
        let root = try AudiobookTestAudio.ownedDirectory("epub-xml-policy")
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var entries = BookTestArchive.epubEntries(chapters: Self.chapters)
        entries[1] = BookTestArchive.Entry(path: "META-INF/container.xml", data: containerData)
        let archive = root.appendingPathComponent("book.epub")
        try BookTestArchive.zip(entries, to: archive)
        return EPUBFixture(root: root, scratch: scratch, extractor: BookTextExtractor(scratchParent: scratch), archive: archive)
    }
}
