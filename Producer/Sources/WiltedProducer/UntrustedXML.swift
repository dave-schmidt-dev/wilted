import Foundation

/// One linear, bounded classifier for XML that comes from outside the app
/// (followed feeds, articles, dropped EPUBs).
///
/// `XMLParser` expands internal entities by itself and on Darwin honours a
/// document's declared encoding, so a hostile document can smuggle a
/// declaration past a byte search (a UTF-7 shifted declaration did) or carry a
/// declaration that contradicts its own byte-order mark. This classifier runs
/// over the whole payload before a parser exists: it decodes the payload once,
/// refuses malformed, unsupported, or contradictory encodings, then walks the
/// decoded bytes once with a small lexical state machine that tracks only what
/// can hide a declaration:
///
/// - comments end at the first `-->` and processing instructions at the first
///   `?>`, regardless of quotes;
/// - quotes hide `>` and `[` only inside tags and DOCTYPE literals;
/// - `<!ENTITY` counts only in a markup-declaration position, and `[` only
///   outside a DOCTYPE literal, so quoted attribute text and quoted system
///   identifiers are not mistaken for a declaration or a subset.
///
/// The original bytes are never rewritten: callers hand them to `XMLParser`
/// unchanged through `makeParser(_:)`, which also sets both no-resolution
/// controls. What the classifier accepts, the parser still has to parse:
/// malformed XML remains the parser's refusal, not this one's.
enum UntrustedXML {
    /// What a consumer does with a document type declaration.
    enum DoctypePolicy: Sendable {
        /// Article feeds and EPUB XML: a bare `<!DOCTYPE name>` or one that
        /// carries only a public/system identifier is accepted; an internal
        /// subset and every entity declaration are refused.
        case allowBare
        /// Podcast feeds: any document type declaration is refused.
        case refuseAll
    }

    /// Why a payload was refused. Encoding refusals are separate cases so a
    /// consumer can map them to its own vocabulary instead of matching a
    /// string; `isDeclarationRefusal` tells the two groups apart.
    enum Refusal: Error, Equatable, Sendable {
        /// An actual `<!ENTITY ...>` markup declaration outside a comment,
        /// CDATA section, processing instruction, or quoted literal.
        case entityDeclaration
        /// A `[` opening a DTD internal subset outside a quoted DOCTYPE literal.
        case internalSubset
        /// A `<!DOCTYPE ...>` markup declaration, refused under `.refuseAll`.
        case doctype
        /// A declared encoding Wilted does not read (UTF-7, ISO-8859-2, ...).
        case unsupportedEncoding(String)
        /// A declaration that contradicts the byte-order mark or byte signature.
        case encodingDisagreement(String)
        /// Bytes that are not a valid document in the encoding they claim or
        /// imply: truncated sequences, an empty BOM-only payload, undefined
        /// windows-1252 bytes.
        case malformedEncoding(String)
    }

    /// The parser every consumer uses. Both no-resolution controls are set
    /// (`shouldResolveExternalEntities = false` and
    /// `externalEntityResolvingPolicy = .never`). Delegate behavior remains
    /// consumer-specific: a bare external DOCTYPE may still cause a resolver
    /// callback returning nil. Canary tests verify returned text, not OS I/O.
    static func makeParser(_ data: Data) -> XMLParser {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        return parser
    }

    /// Classifies the whole payload in one linear pass. Returns the reason to
    /// refuse, or nil when the payload may be handed to `XMLParser`.
    static func refusal(in data: Data, doctype: DoctypePolicy) -> Refusal? {
        let bytes = [UInt8](data)
        switch detection(of: bytes) {
        case .failure(let refusal):
            return refusal
        case .success(.asciiCompat):
            return asciiCompatibleRefusal(in: data, bytes: bytes, doctype: doctype)
        case .success(.signature(let encoding)):
            guard let text = encoding.decode(data) else { return .malformedEncoding(encoding.name) }
            let decoded = [UInt8](text.utf8)
            for declared in declaredEncodings(decoded) {
                if let refusal = disagreement(declared, with: encoding) { return refusal }
            }
            return lexicalRefusal(decoded, doctype: doctype)
        }
    }


}

extension UntrustedXML.Refusal {
    /// True when the refusal is about an entity declaration or DTD subset
    /// (`doctype` included), which feed and article consumers report as an
    /// external entity. Encoding refusals are malformed payloads instead.
    var isDeclarationRefusal: Bool {
        switch self {
        case .entityDeclaration, .internalSubset, .doctype: true
        case .unsupportedEncoding, .encodingDisagreement, .malformedEncoding: false
        }
    }
}

// MARK: - Encoding detection and agreement

private extension UntrustedXML {
    /// How the opening bytes say the payload is encoded, when they say
    /// anything at all. `.asciiCompat` means no byte-order mark and no byte
    /// signature: the declaration (or the default) chooses the encoding.
    enum Detection {
        case signature(Encoding)
        case asciiCompat
    }

    /// A supported decoding. Canonical names are the ones the classifier
    /// reports and the boundary it documents.
    enum Encoding {
        case utf8(bom: Int)
        case utf16(bigEndian: Bool, bom: Int)
        case utf32(bigEndian: Bool, bom: Int)
        case isoLatin1
        case windows1252

        var name: String {
            switch self {
            case .utf8: "UTF-8"
            case let .utf16(bigEndian, _): bigEndian ? "UTF-16BE" : "UTF-16LE"
            case let .utf32(bigEndian, _): bigEndian ? "UTF-32BE" : "UTF-32LE"
            case .isoLatin1: "ISO-8859-1"
            case .windows1252: "WINDOWS-1252"
            }
        }

        /// Strict: nil on any byte sequence that is not valid in this encoding.
        /// ISO-8859-1 accepts every byte; windows-1252 rejects its undefined
        /// positions; the Unicode decoders reject truncation and unpaired
        /// surrogates. `bom` bytes are stripped before decoding; a byte
        /// signature with no BOM is content and is not stripped.
        func decode(_ data: Data) -> String? {
            switch self {
            case let .utf8(bom):
                return String(data: Data(data.dropFirst(bom)), encoding: .utf8)
            case let .utf16(bigEndian, bom):
                return String(data: Data(data.dropFirst(bom)), encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian)
            case let .utf32(bigEndian, bom):
                return String(data: Data(data.dropFirst(bom)), encoding: bigEndian ? .utf32BigEndian : .utf32LittleEndian)
            case .isoLatin1:
                return String(data: data, encoding: .isoLatin1)
            case .windows1252:
                return String(data: data, encoding: .windowsCP1252)
            }
        }
    }

    /// Reads the byte-order mark or XML byte signature. The order matters:
    /// UTF-32LE's BOM starts with UTF-16LE's, and the UTF-32LE signature starts
    /// with the UTF-16LE one.
    static func detection(of bytes: [UInt8]) -> Result<Detection, Refusal> {
        let count = bytes.count
        func has(_ signature: [UInt8]) -> Bool {
            count >= signature.count && Array(bytes.prefix(signature.count)) == signature
        }
        if has([0x00, 0x00, 0xFE, 0xFF]) { return utf32(bigEndian: true, bom: 4, count: count) }
        if has([0xFF, 0xFE, 0x00, 0x00]) { return utf32(bigEndian: false, bom: 4, count: count) }
        if has([0xEF, 0xBB, 0xBF]) {
            return count == 3 ? .failure(.malformedEncoding("UTF-8")) : .success(.signature(.utf8(bom: 3)))
        }
        if has([0xFE, 0xFF]) { return utf16(bigEndian: true, bom: 2, count: count) }
        if has([0xFF, 0xFE]) { return utf16(bigEndian: false, bom: 2, count: count) }
        if has([0x00, 0x00, 0x00, 0x3C]) { return utf32(bigEndian: true, bom: 0, count: count) }
        if has([0x3C, 0x00, 0x00, 0x00]) { return utf32(bigEndian: false, bom: 0, count: count) }
        if has([0x00, 0x3C, 0x00, 0x3F]) { return utf16(bigEndian: true, bom: 0, count: count) }
        if has([0x3C, 0x00, 0x3F, 0x00]) { return utf16(bigEndian: false, bom: 0, count: count) }
        return .success(.asciiCompat)
    }

    static func utf16(bigEndian: Bool, bom: Int, count: Int) -> Result<Detection, Refusal> {
        let name = bigEndian ? "UTF-16BE" : "UTF-16LE"
        guard count - bom >= 2, (count - bom) % 2 == 0 else { return .failure(.malformedEncoding(name)) }
        return .success(.signature(.utf16(bigEndian: bigEndian, bom: bom)))
    }

    static func utf32(bigEndian: Bool, bom: Int, count: Int) -> Result<Detection, Refusal> {
        let name = bigEndian ? "UTF-32BE" : "UTF-32LE"
        guard count - bom >= 4, (count - bom) % 4 == 0 else { return .failure(.malformedEncoding(name)) }
        return .success(.signature(.utf32(bigEndian: bigEndian, bom: bom)))
    }

    /// The supported spelling of a declared encoding, or nil for anything
    /// outside the documented compatibility boundary. IANA names are matched
    /// case-insensitively but not aliased: `UTF-8`, `UTF-16`, `UTF-16BE`,
    /// `UTF-16LE`, `UTF-32`, `UTF-32BE`, `UTF-32LE`, `ISO-8859-1`, and
    /// `windows-1252` only.
    static func supportedName(_ declared: String) -> String? {
        switch declared.uppercased() {
        case "UTF-8": "UTF-8"
        case "UTF-16": "UTF-16"
        case "UTF-16BE": "UTF-16BE"
        case "UTF-16LE": "UTF-16LE"
        case "UTF-32": "UTF-32"
        case "UTF-32BE": "UTF-32BE"
        case "UTF-32LE": "UTF-32LE"
        case "ISO-8859-1": "ISO-8859-1"
        case "WINDOWS-1252": "WINDOWS-1252"
        default: nil
        }
    }

    /// Checks one declaration value against evidence that a BOM or signature
    /// already fixed. A contradicting declaration is refused, never obeyed.
    static func disagreement(_ declared: String, with encoding: Encoding) -> Refusal? {
        guard let name = supportedName(declared) else { return .unsupportedEncoding(declared) }
        switch encoding {
        case .utf8:
            return name == "UTF-8" ? nil : .encodingDisagreement(declared)
        case let .utf16(bigEndian, _):
            return name == "UTF-16" || name == (bigEndian ? "UTF-16BE" : "UTF-16LE") ? nil : .encodingDisagreement(declared)
        case let .utf32(bigEndian, _):
            return name == "UTF-32" || name == (bigEndian ? "UTF-32BE" : "UTF-32LE") ? nil : .encodingDisagreement(declared)
        case .isoLatin1, .windows1252:
            return .encodingDisagreement(declared)
        }
    }

    /// No BOM or signature: the declaration may pick a Unicode default or a
    /// proven legacy encoding. UTF-16 and UTF-32 need a BOM or byte signature,
    /// so declaring one here contradicts the bytes.
    static func asciiCompatibleRefusal(in data: Data, bytes: [UInt8], doctype: DoctypePolicy) -> Refusal? {
        // NUL is never XML text. Refuse unrecognized wide-byte signatures
        // before UTF-8 decoding can hide declaration tokens behind NULs.
        guard !bytes.contains(0) else { return .malformedEncoding("UTF-8") }
        var chosenName: String?
        var chosenOriginal: String?
        for declared in declaredEncodings(bytes) {
            guard let name = supportedName(declared) else { return .unsupportedEncoding(declared) }
            if let chosenName, chosenName != name { return .encodingDisagreement(declared) }
            chosenName = name
            chosenOriginal = chosenOriginal ?? declared
        }
        let encoding: Encoding
        if let chosenName {
            switch chosenName {
            case "UTF-8": encoding = .utf8(bom: 0)
            case "ISO-8859-1": encoding = .isoLatin1
            case "WINDOWS-1252": encoding = .windows1252
            default: return .encodingDisagreement(chosenOriginal ?? chosenName)
            }
        } else {
            encoding = .utf8(bom: 0)
        }
        guard let text = encoding.decode(data) else { return .malformedEncoding(encoding.name) }
        return lexicalRefusal([UInt8](text.utf8), doctype: doctype)
    }

    /// The `encoding` values of a document's XML declaration, in order. The
    /// declaration is a processing instruction at the very start, so it ends
    /// at the first `?>` and nothing after it is read. An absent, unterminated,
    /// or malformed declaration yields no values and leaves the parser to
    /// refuse it; a declaration with several encoding values yields all of
    /// them so every one can be checked.
    static func declaredEncodings(_ bytes: [UInt8]) -> [String] {
        let prolog: [UInt8] = [0x3C, 0x3F, 0x78, 0x6D, 0x6C]  // "<?xml"
        guard bytes.count > 5, Array(bytes.prefix(5)) == prolog, isXMLSpace(bytes[5]) else { return [] }
        var end = bytes.count
        var cursor = 6
        while cursor + 1 < bytes.count {
            if bytes[cursor] == 0x3F, bytes[cursor + 1] == 0x3E { end = cursor; break }
            cursor += 1
        }
        let keyword: [UInt8] = Array("encoding".utf8)
        var values: [String] = []
        var scan = 6
        while scan < end {
            guard bytes[scan] == keyword[0], isXMLSpace(bytes[scan - 1]), matches(bytes, at: scan, keyword, end: end) else {
                scan += 1
                continue
            }
            var value = scan + keyword.count
            while value < end, isXMLSpace(bytes[value]) { value += 1 }
            guard value < end, bytes[value] == 0x3D else { scan += 1; continue }
            value += 1
            while value < end, isXMLSpace(bytes[value]) { value += 1 }
            guard value < end, bytes[value] == 0x22 || bytes[value] == 0x27 else { scan += 1; continue }
            let quote = bytes[value]
            value += 1
            let start = value
            while value < end, bytes[value] != quote { value += 1 }
            // XML EncName is ASCII and bounded before it can enter an error.
            let name = bytes[start..<value]
            let valid = !name.isEmpty && name.count <= 64 && name.enumerated().allSatisfy { offset, byte in
                let letter = (65...90).contains(byte) || (97...122).contains(byte)
                return letter || (offset > 0 && ((48...57).contains(byte) || [45, 46, 95].contains(byte)))
            }
            values.append(valid ? String(decoding: name, as: UTF8.self) : "invalid-encoding-name")
            scan = value + 1
        }
        return values
    }

    static func isXMLSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

// MARK: - Lexical scan

private extension UntrustedXML {
    /// What the scan is inside of. Quotes are tracked only in tags and DOCTYPE
    /// literals; comments, CDATA, and processing instructions end at their
    /// literal terminators and never care about quotes.
    enum LexicalState {
        case content
        case tag
        case tagQuote(UInt8)
        case comment
        case cdata
        case processingInstruction
        case doctype
        case doctypeQuote(UInt8)
    }

    /// One pass over the decoded bytes. `<!DOCTYPE` recognition is
    /// case-sensitive (XML keywords are), a `<!DOCTYPE` refused by policy
    /// returns before its body is read, and everything else that cannot be a
    /// declaration is skipped without backtracking.
    static func lexicalRefusal(_ bytes: [UInt8], doctype: DoctypePolicy) -> Refusal? {
        var state = LexicalState.content
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch state {
            case .content:
                if byte == UInt8(ascii: "<") {
                    if matches(bytes, at: index, "<!--") { state = .comment; index += 4; continue }
                    if matches(bytes, at: index, "<![CDATA[") { state = .cdata; index += 9; continue }
                    if matches(bytes, at: index, "<!DOCTYPE") {
                        guard doctype == .allowBare else { return .doctype }
                        state = .doctype; index += 9; continue
                    }
                    if matches(bytes, at: index, "<!ENTITY") { return .entityDeclaration }
                    if matches(bytes, at: index, "<?") { state = .processingInstruction; index += 2; continue }
                    state = .tag
                }
            case .tag:
                if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { state = .tagQuote(byte) }
                else if byte == UInt8(ascii: ">") { state = .content }
            case .tagQuote(let quote):
                if byte == quote { state = .tag }
            case .comment:
                if byte == UInt8(ascii: "-"), matches(bytes, at: index, "-->") { state = .content; index += 3; continue }
            case .cdata:
                if byte == UInt8(ascii: "]"), matches(bytes, at: index, "]]>") { state = .content; index += 3; continue }
            case .processingInstruction:
                if byte == UInt8(ascii: "?"), matches(bytes, at: index, "?>") { state = .content; index += 2; continue }
            case .doctype:
                if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { state = .doctypeQuote(byte) }
                else if byte == UInt8(ascii: "[") { return .internalSubset }
                else if byte == UInt8(ascii: ">") { state = .content }
            case .doctypeQuote(let quote):
                if byte == quote { state = .doctype }
            }
            index += 1
        }
        return nil
    }

    static func matches(_ bytes: [UInt8], at index: Int, _ token: StaticString) -> Bool {
        token.withUTF8Buffer { literal in
            guard index + literal.count <= bytes.count else { return false }
            for offset in literal.indices where bytes[index + offset] != literal[offset] { return false }
            return true
        }
    }

    static func matches(_ bytes: [UInt8], at index: Int, _ token: [UInt8], end: Int) -> Bool {
        guard index + token.count <= end else { return false }
        for offset in token.indices {
            if bytes[index + offset] != token[offset] { return false }
        }
        return true
    }
}
