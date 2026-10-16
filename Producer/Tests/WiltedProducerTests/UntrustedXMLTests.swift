import Foundation
import Testing
@testable import WiltedProducer

@Suite("Untrusted XML classifier")
struct UntrustedXMLTests {
    // MARK: - Lexical structure

    /// Comments end at the first `-->` no matter what is inside them, so a
    /// quoted terminator-looking token does not extend a comment; and a
    /// declaration-looking token inside a comment is text.
    @Test func commentsEndAtTheFirstTerminatorRegardlessOfQuotes() {
        let quoted = #"<!-- " --><!DOCTYPE r [ ]><r/>"#
        #expect(UntrustedXML.refusal(in: Data(quoted.utf8), doctype: .allowBare) == .internalSubset)

        let decoy = "<!-- <!DOCTYPE r [<!ENTITY a \"b\">]> --><r/>"
        #expect(UntrustedXML.refusal(in: Data(decoy.utf8), doctype: .refuseAll) == nil)
    }

    /// Processing instructions end at the first `?>`, so a terminator inside a
    /// quoted region ends the PI and the markup after it is real content; a PI
    /// whose data only looks like a declaration is data.
    @Test func processingInstructionsEndAtTheFirstTerminatorRegardlessOfQuotes() {
        let forged = #"<?pi "?><!ENTITY local 'CANARY'><root/>"#
        #expect(UntrustedXML.refusal(in: Data(forged.utf8), doctype: .refuseAll) == .entityDeclaration)

        let decoy = #"<?pi "<!DOCTYPE r [<!ENTITY a 'b'>]>"?><r/>"#
        #expect(UntrustedXML.refusal(in: Data(decoy.utf8), doctype: .refuseAll) == nil)
    }

    /// CDATA ends at the first `]]>`, so declaration-looking text before that
    /// is text, and markup after the real terminator is not.
    @Test func cdataContentIsTextUntilItsTerminator() {
        let decoy = #"<rss><description><![CDATA[<!ENTITY a "b">]]></description></rss>"#
        #expect(UntrustedXML.refusal(in: Data(decoy.utf8), doctype: .refuseAll) == nil)

        let escaped = #"<rss><![CDATA[junk]]><!ENTITY a "b"></rss>"#
        #expect(UntrustedXML.refusal(in: Data(escaped.utf8), doctype: .refuseAll) == .entityDeclaration)
    }

    /// Quotes hide `>` and `[` only inside tags and DOCTYPE literals: a quoted
    /// attribute or system literal cannot introduce a subset, and a quote
    /// cannot hide a subset bracket that stands outside the literal.
    @Test func quotedTokensHideStructureOnlyInsideTagsAndDoctypes() {
        let attribute = #"<rss version="a>b[c"><channel><title>T</title></channel></rss>"#
        #expect(UntrustedXML.refusal(in: Data(attribute.utf8), doctype: .refuseAll) == nil)

        let systemLiteral = #"<!DOCTYPE rss SYSTEM "x [<!ENTITY e 'v'>]"><rss/>"#
        #expect(UntrustedXML.refusal(in: Data(systemLiteral.utf8), doctype: .allowBare) == nil)

        let hiddenSubset = #"<!DOCTYPE rss SYSTEM "a>b" [ ]><rss/>"#
        #expect(UntrustedXML.refusal(in: Data(hiddenSubset.utf8), doctype: .allowBare) == .internalSubset)
    }

    /// Each consumer keeps its documented DOCTYPE policy: podcasts refuse any
    /// document type declaration, articles and EPUB XML accept a bare one.
    @Test func doctypePolicyIsPerConsumer() {
        let bare = Data("<!DOCTYPE rss><rss/>".utf8)
        #expect(UntrustedXML.refusal(in: bare, doctype: .refuseAll) == .doctype)
        #expect(UntrustedXML.refusal(in: bare, doctype: .allowBare) == nil)
        #expect((UntrustedXML.refusal(in: bare, doctype: .allowBare) != nil) == false)

        let subset = Data("<!DOCTYPE rss [ ]><rss/>".utf8)
        #expect(UntrustedXML.refusal(in: subset, doctype: .allowBare) == .internalSubset)
        #expect((UntrustedXML.refusal(in: subset, doctype: .allowBare) != nil))
    }

    /// An ENTITY declaration counts only in a markup-declaration position; an
    /// internal subset is refused at its bracket, before any declaration in it.
    @Test func entityDeclarationsAreRefusedInMarkupPosition() {
        let declaration = Data(#"<!ENTITY a "b"><r/>"#.utf8)
        #expect(UntrustedXML.refusal(in: declaration, doctype: .refuseAll) == .entityDeclaration)
        #expect((UntrustedXML.refusal(in: declaration, doctype: .allowBare) != nil))

        let subset = Data(#"<!DOCTYPE r [<!ENTITY a "b">]><r/>"#.utf8)
        #expect(UntrustedXML.refusal(in: subset, doctype: .allowBare) == .internalSubset)
    }

    // MARK: - Encoding agreement

    @Test func supportedUnicodeEncodingsAgreeWithTheirBomOrSignature() {
        let declared16 = #"<?xml version="1.0" encoding="UTF-16"?><rss/>"#
        #expect(UntrustedXML.refusal(in: utf16(declared16, bigEndian: true, bom: true), doctype: .refuseAll) == nil)
        #expect(UntrustedXML.refusal(in: utf16(declared16, bigEndian: false, bom: true), doctype: .refuseAll) == nil)

        let declared16BE = #"<?xml version="1.0" encoding="UTF-16BE"?><rss/>"#
        #expect(UntrustedXML.refusal(in: utf16(declared16BE, bigEndian: true, bom: true), doctype: .refuseAll) == nil)
        #expect(UntrustedXML.refusal(in: utf16(declared16BE, bigEndian: true, bom: false), doctype: .refuseAll) == nil)

        let declared32 = #"<?xml version="1.0" encoding="UTF-32"?><rss/>"#
        #expect(UntrustedXML.refusal(in: utf32(declared32, bigEndian: true, bom: true), doctype: .refuseAll) == nil)
        #expect(UntrustedXML.refusal(in: utf32(declared32, bigEndian: false, bom: false), doctype: .refuseAll) == nil)

        let declared8 = #"<?xml version="1.0" encoding="UTF-8"?><rss/>"#
        #expect(UntrustedXML.refusal(in: Data(declared8.utf8), doctype: .refuseAll) == nil)
        var withBom = Data([0xEF, 0xBB, 0xBF])
        withBom.append(Data(declared8.utf8))
        #expect(UntrustedXML.refusal(in: withBom, doctype: .refuseAll) == nil)
    }

    /// Foundation accepted a UTF-16LE BOM with an XML UTF-8 declaration, so the
    /// classifier enforces agreement itself and refuses the contradiction.
    @Test func declarationsThatContradictTheBomOrSignatureAreRefused() {
        let declared8 = #"<?xml version="1.0" encoding="UTF-8"?><rss/>"#
        let bom16 = UntrustedXML.refusal(in: utf16(declared8, bigEndian: false, bom: true), doctype: .refuseAll)
        #expect(bom16 == .encodingDisagreement("UTF-8"))
        let signature16 = UntrustedXML.refusal(in: utf16(declared8, bigEndian: false, bom: false), doctype: .refuseAll)
        #expect(signature16 == .encodingDisagreement("UTF-8"))

        let declaredBE = #"<?xml version="1.0" encoding="UTF-16BE"?><rss/>"#
        let wrongEndianness = UntrustedXML.refusal(in: utf16(declaredBE, bigEndian: false, bom: true), doctype: .refuseAll)
        #expect(wrongEndianness == .encodingDisagreement("UTF-16BE"))

        let declaredLatin = #"<?xml version="1.0" encoding="ISO-8859-1"?><rss/>"#
        var bomLatin = Data([0xEF, 0xBB, 0xBF])
        bomLatin.append(Data(declaredLatin.utf8))
        #expect(UntrustedXML.refusal(in: bomLatin, doctype: .refuseAll) == .encodingDisagreement("ISO-8859-1"))

        let declared16 = #"<?xml version="1.0" encoding="UTF-16"?><rss/>"#
        #expect(UntrustedXML.refusal(in: Data(declared16.utf8), doctype: .refuseAll) == .encodingDisagreement("UTF-16"))
    }

    /// The exact UTF-7 shifted declaration that bypassed the old scanners: the
    /// declaration is ASCII and only the DOCTYPE and ENTITY are UTF-7 encoded.
    @Test func shiftedAndUnsupportedDeclarationsAreRefused() {
        let shifted = #"<?xml version="1.0" encoding="UTF-7"?>+ADw-!DOCTYPE root [+ADw-!ENTITY local 'INTERNAL_CANARY'>]><root>before&local;after</root>"#
        #expect(UntrustedXML.refusal(in: Data(shifted.utf8), doctype: .refuseAll) == .unsupportedEncoding("UTF-7"))

        let latin2 = #"<?xml version="1.0" encoding="ISO-8859-2"?><rss/>"#
        #expect(UntrustedXML.refusal(in: Data(latin2.utf8), doctype: .refuseAll) == .unsupportedEncoding("ISO-8859-2"))

        let ascii = #"<?xml version="1.0" encoding="US-ASCII"?><rss/>"#
        #expect(UntrustedXML.refusal(in: Data(ascii.utf8), doctype: .refuseAll) == .unsupportedEncoding("US-ASCII"))
    }

    @Test func provenLegacyEncodingsDecodeTheirBytes() {
        var latin = Data(#"<?xml version="1.0" encoding="ISO-8859-1"?><rss><title>Caf"#.utf8)
        latin.append(contentsOf: [0xE9])
        latin.append(contentsOf: Data("</title></rss>".utf8))
        #expect(UntrustedXML.refusal(in: latin, doctype: .refuseAll) == nil)

        var cp1252 = Data(#"<?xml version="1.0" encoding="windows-1252"?><rss><title>"#.utf8)
        cp1252.append(contentsOf: [0x93, 0x48, 0x69, 0x94])
        cp1252.append(contentsOf: Data("</title></rss>".utf8))
        #expect(UntrustedXML.refusal(in: cp1252, doctype: .refuseAll) == nil)
    }

    @Test func malformedAndTruncatedEncodingsAreRefused() {
        #expect(UntrustedXML.refusal(in: Data([0xEF, 0xBB, 0xBF]), doctype: .refuseAll) == .malformedEncoding("UTF-8"))
        var truncated8 = Data([0xEF, 0xBB, 0xBF])
        truncated8.append(contentsOf: [0xC3])
        #expect(UntrustedXML.refusal(in: truncated8, doctype: .refuseAll) == .malformedEncoding("UTF-8"))

        var odd16 = utf16("<rss/>", bigEndian: false, bom: true)
        odd16.append(contentsOf: [0x3C])
        #expect(UntrustedXML.refusal(in: odd16, doctype: .refuseAll) == .malformedEncoding("UTF-16LE"))

        #expect(UntrustedXML.refusal(in: Data([0x00, 0x00, 0x00, 0x3C, 0x00]), doctype: .refuseAll) == .malformedEncoding("UTF-32BE"))

        var stray = Data("<rss><title>caf".utf8)
        stray.append(contentsOf: [0xE9])
        stray.append(contentsOf: Data("</title></rss>".utf8))
        #expect(UntrustedXML.refusal(in: stray, doctype: .refuseAll) == .malformedEncoding("UTF-8"))
    }

    @Test func strictDecodingAndDeclarationEdgeCases() {
        let cp = Array(#"<?xml version="1.0" encoding="windows-1252"?><r>"#.utf8)
        for byte: UInt8 in [0x81, 0x8D, 0x8F, 0x90, 0x9D] {
            #expect(UntrustedXML.refusal(in: Data(cp + [byte] + Array("</r>".utf8)), doctype: .allowBare) == .malformedEncoding("WINDOWS-1252"))
        }
        #expect(UntrustedXML.refusal(in: Data([0xFF, 0xFE, 0x00, 0xD8]), doctype: .allowBare) == .malformedEncoding("UTF-16LE"))
        let wrong = #"<?xml version="1.0" encoding="UTF-8"?><r/>"#
        #expect(UntrustedXML.refusal(in: utf32(wrong, bigEndian: true, bom: true), doctype: .allowBare) == .encodingDisagreement("UTF-8"))
        let repeated = #"<?xml version="1.0" encoding="UTF-8" encoding="UTF-7"?><r/>"#
        #expect(UntrustedXML.refusal(in: Data(repeated.utf8), doctype: .allowBare) == .unsupportedEncoding("UTF-7"))
        #expect(UntrustedXML.refusal(in: Data(#"<?xml version="1.0" encoding="uTf-8"?><r/>"#.utf8), doctype: .allowBare) == nil)
        let malformed = Data(#"<?xml version="1.0" encoding="UTF-8"<r/>"#.utf8)
        #expect(UntrustedXML.refusal(in: malformed, doctype: .allowBare) == nil)
        #expect(!UntrustedXML.makeParser(malformed).parse())
        #expect((UntrustedXML.refusal(in: Data(#"<?xml version="1.0" encoding="UTF-7"?><r/>"#.utf8), doctype: .allowBare) != nil))
    }

    @Test func unrecognizedWideSignaturesCannotHideDeclarations() {
        for prefix: [UInt8] in [[0, 0, 0x3C, 0], [0, 0x3C, 0, 0], [0x3C, 0, 0x21, 0], [0, 0x3C, 0, 0x21]] {
            #expect(UntrustedXML.refusal(in: Data(prefix), doctype: .allowBare) == .malformedEncoding("UTF-8"))
        }
        let wide = "<!DOCTYPE r [<!ENTITY e 'CANARY'>]><r/>".data(using: .utf16LittleEndian)!
        #expect(UntrustedXML.refusal(in: wide, doctype: .allowBare) == .malformedEncoding("UTF-8"))
        #expect(UntrustedXML.refusal(in: Data("<r>\0</r>".utf8), doctype: .allowBare) == .malformedEncoding("UTF-8"))
    }

    @Test func hostileEncodingLabelsAreBoundedAndSanitized() {
        for name in [String(repeating: "x", count: 100_000), "bad\nencoding", "bad\u{1B}encoding"] {
            let bytes = Data("<?xml version=\"1.0\" encoding=\"\(name)\"?><r/>".utf8)
            #expect(UntrustedXML.refusal(in: bytes, doctype: .allowBare) == .unsupportedEncoding("invalid-encoding-name"))
        }
    }

    // MARK: - Parser configuration

    @Test func everyParserGetsBothNoResolutionControls() {
        let parser = UntrustedXML.makeParser(Data("<rss/>".utf8))
        #expect(parser.shouldResolveExternalEntities == false)
        #expect(parser.externalEntityResolvingPolicy == .never)
    }

    /// The compatibility question article and EPUB callers used before the
    /// typed classifier keeps its pinned answers, and the decoded scan now
    /// sees a declaration the old byte search could not.
    @Test func theBookCompatibilityQuestionKeepsItsPinnedAnswers() {
        #expect((UntrustedXML.refusal(in: Data("<!DOCTYPE x [ ]><x/>".utf8), doctype: .allowBare) != nil))
        #expect(!(UntrustedXML.refusal(in: Data("<!DOCTYPE html PUBLIC \"-//W3C//DTD\" \"x.dtd\"><html/>".utf8), doctype: .allowBare) != nil))
        #expect(!(UntrustedXML.refusal(in: Data("<rss/>".utf8), doctype: .allowBare) != nil))

        let utf16Entity = utf16(#"<!DOCTYPE r [<!ENTITY a "b">]><r/>"#, bigEndian: false, bom: true)
        #expect((UntrustedXML.refusal(in: utf16Entity, doctype: .allowBare) != nil))
    }

    // MARK: - Fixture helpers

    private func utf16(_ string: String, bigEndian: Bool, bom: Bool) -> Data {
        var data = Data()
        if bom { data.append(contentsOf: bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) }
        data.append(string.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian)!)
        return data
    }

    private func utf32(_ string: String, bigEndian: Bool, bom: Bool) -> Data {
        var data = Data()
        if bom { data.append(contentsOf: bigEndian ? [0x00, 0x00, 0xFE, 0xFF] : [0xFF, 0xFE, 0x00, 0x00]) }
        data.append(string.data(using: bigEndian ? .utf32BigEndian : .utf32LittleEndian)!)
        return data
    }
}
