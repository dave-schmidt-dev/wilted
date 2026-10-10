import Foundation

// MARK: - Unpacked EPUB

/// An unpacked EPUB folder. Every path that leaves this type has been resolved inside the root.
struct EPUBTree {
    let root: URL
    private let resolvedRoot: String

    init(root: URL) throws {
        self.root = root
        self.resolvedRoot = root.resolvingSymlinksInPath().path
    }

    /// Walks the unpacked tree with `lstat` semantics: no symlinks, nothing outside the root,
    /// and the real sizes (not the archive's claims) within the limits.
    func verifyUnpacked(limits: BookExtractionLimits) throws {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw BookExtractionError.unreadable("The unpacked book cannot be read.")
        }
        var entries = 0
        var bytes: Int64 = 0
        for case let url as URL in walker {
            entries += 1
            let attributes = try manager.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink: throw BookExtractionError.refused("The book contains a symbolic link.")
            case .typeDirectory: break
            case .typeRegular: bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            default: throw BookExtractionError.refused("The book contains a special file.")
            }
            guard url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot + "/") else {
                throw BookExtractionError.refused("The book unpacked outside its folder.")
            }
            if entries > limits.maxEntries || bytes > limits.maxExpandedBytes {
                throw BookExtractionError.refused("The unpacked book is over the size limits.")
            }
        }
    }

    /// Resolves a reference from `baseDir` (a root-relative folder) to a normalized root-relative path.
    func resolve(_ reference: String, baseDir: String) throws -> String {
        var href = reference
        if let cut = href.firstIndex(where: { $0 == "#" || $0 == "?" }) { href = String(href[..<cut]) }
        href = href.removingPercentEncoding ?? href
        let unsafe = href.isEmpty || href.hasPrefix("/") || href.contains("\\") || href.contains("\0")
            || href.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil
        guard !unsafe else { throw BookExtractionError.refused("The book refers to an unsafe path (\(reference)).") }
        var parts = baseDir.split(separator: "/").map(String.init)
        for part in href.split(separator: "/", omittingEmptySubsequences: true) where part != "." {
            if part == ".." {
                guard !parts.isEmpty else { throw BookExtractionError.refused("The book refers outside its folder (\(reference)).") }
                parts.removeLast()
            } else {
                parts.append(String(part))
            }
        }
        guard !parts.isEmpty else { throw BookExtractionError.refused("The book refers to an empty path.") }
        return parts.joined(separator: "/")
    }

    func url(_ relative: String) throws -> URL {
        let target = root.appendingPathComponent(relative)
        guard let type = try? FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType else {
            throw BookExtractionError.unreadable("\(relative) is missing from the book.")
        }
        guard type == .typeRegular, target.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot + "/") else {
            throw BookExtractionError.refused("\(relative) is not a plain file inside the book.")
        }
        return target
    }

    func exists(_ relative: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path)) != nil
    }

    func string(_ relative: String, maxBytes: Int) throws -> String {
        let target = try url(relative)
        let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw BookExtractionError.textTooLarge(limitBytes: maxBytes) }
        return String(decoding: try Data(contentsOf: target), as: UTF8.self)
    }

    func xml(_ relative: String) throws -> XMLNode {
        try XMLNode.parse(Data(contentsOf: url(relative)), name: relative)
    }

    /// Refuses the book only when `encryption.xml` lists a spine document. Font obfuscation
    /// and encrypted images or fonts leave the text readable and are accepted.
    func refuseEncryptedContent(spine: Set<String>) throws {
        guard exists("META-INF/encryption.xml") else { return }
        for reference in try xml("META-INF/encryption.xml").descendants("CipherReference") {
            if let uri = reference.attributes["URI"], let path = try? resolve(uri, baseDir: ""), spine.contains(path) {
                throw BookExtractionError.refused("The book's text is encrypted (\(path)).")
            }
        }
    }
}

// MARK: - XML

/// A parsed XML element. Namespace prefixes are dropped from element and attribute names.
final class XMLNode {
    let name: String
    var attributes: [String: String]
    var children: [XMLNode] = []
    fileprivate var ownText = ""

    fileprivate init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func find(_ name: String) -> XMLNode? { descendants(name).first }

    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }

    var allText: String { ownText + children.map(\.allText).joined(separator: " ") }

    /// External entities and DTD loading are off; the node count is bounded.
    static func parse(_ data: Data, name: String) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw BookExtractionError.unreadable("\(name) is not valid XML.")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        private var stack: [XMLNode] = []
        private var count = 0

        private static func local(_ qualified: String) -> String {
            qualified.split(separator: ":").last.map(String.init) ?? qualified
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            count += 1
            if count > 200_000 || stack.count > 200 { parser.abortParsing(); return }
            let node = XMLNode(name: Self.local(element), attributes: Dictionary(
                attributes.map { (Self.local($0.key), $0.value) }, uniquingKeysWith: { first, _ in first }))
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.ownText += string }
    }
}

// MARK: - XHTML to text

/// A small tolerant converter for chapter documents. It is not an XML parser, so a stray
/// `&nbsp;` or an unclosed tag never fails a book, and there are no entities to expand.
enum HTMLText {
    private static let skipped: Set<String> = ["head", "script", "style", "svg", "math"]
    private static let blocks: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "blockquote", "section", "article", "pre", "table",
        "ul", "ol", "hr", "header", "footer", "figure", "figcaption", "dd", "dt", "aside", "nav", "body",
    ]
    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "copy": "\u{A9}", "eacute": "\u{E9}",
    ]

    static func plainText(_ html: String) -> String {
        var paragraphs: [String] = []
        var buffer = ""
        func flush() {
            if let text = BookTextExtractor.clean(buffer) { paragraphs.append(text) }
            buffer = ""
        }
        var index = html.startIndex
        while index < html.endIndex {
            guard html[index] == "<" else {
                let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                buffer += decode(String(html[index..<next]))
                index = next
                continue
            }
            if html[index...].hasPrefix("<!--") {
                index = html.range(of: "-->", range: index..<html.endIndex)?.upperBound ?? html.endIndex
                continue
            }
            let (tag, after) = readTag(html, from: index)
            index = after
            let closing = tag.hasPrefix("/")
            let name = String(tag.drop { $0 == "/" }.prefix { !$0.isWhitespace && $0 != "/" }).lowercased()
            if skipped.contains(name), !closing, !tag.hasSuffix("/") {
                index = html.range(of: "</\(name)", options: .caseInsensitive, range: index..<html.endIndex)?.lowerBound ?? html.endIndex
                if index < html.endIndex { index = html[index...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex }
            } else if blocks.contains(name) {
                flush()
            } else if name == "br" {
                buffer += " "
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    /// The text between `<` and `>`, honoring quoted attribute values, and the index after `>`.
    private static func readTag(_ html: String, from start: String.Index) -> (String, String.Index) {
        var index = html.index(after: start)
        var quote: Character?
        var tag = ""
        while index < html.endIndex {
            let character = html[index]
            index = html.index(after: index)
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                break
            }
            tag.append(character)
        }
        return (tag.trimmingCharacters(in: .whitespacesAndNewlines), index)
    }

    private static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let end = text[index...].prefix(12).firstIndex(of: ";") {
                let body = String(text[text.index(after: index)..<end])
                if let replacement = replacement(for: body) {
                    result += replacement
                    index = text.index(after: end)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func replacement(for body: String) -> String? {
        guard body.hasPrefix("#") else { return entities[body] }
        let digits = body.dropFirst()
        let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
}
