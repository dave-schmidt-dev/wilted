import Foundation

/// Guards for XML from outside the app (followed feeds, dropped EPUBs). `XMLParser` expands
/// internal entities by itself, so a hostile document can grow without bound. These checks
/// run over the whole payload before parsing; delegates also abort on entity-declaration
/// callbacks, which covers encodings the byte search cannot see.
enum UntrustedXML {
    private static let entity = Data("<!ENTITY".utf8)
    private static let doctype = Data("<!DOCTYPE".utf8)
    private static let subsetOpen = UInt8(ascii: "[")
    private static let tagClose = UInt8(ascii: ">")

    /// True when the data declares an entity or carries a DTD internal subset.
    /// A bare `<!DOCTYPE name>` or one with only a public/system identifier is accepted.
    static func declaresEntitiesOrSubset(_ data: Data) -> Bool {
        if data.range(of: entity) != nil { return true }
        var from = data.startIndex
        while let found = data.range(of: doctype, in: from..<data.endIndex) {
            for byte in data[found.upperBound...] {
                if byte == subsetOpen { return true }
                if byte == tagClose { break }
            }
            from = found.upperBound
        }
        return false
    }
}
