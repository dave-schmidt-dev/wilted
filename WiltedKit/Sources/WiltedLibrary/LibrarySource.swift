import Foundation
import WiltedDomain

/// A place library entries come from, such as a podcast feed.
public struct LibrarySource: Codable, Sendable, Equatable, Identifiable {
    public let id: ItemID
    public let kind: LibraryKind
    public let title: String
    /// Kind-specific locator, for example the canonical feed URL.
    public let locator: String?
    public let artworkRef: String?

    public init(id: ItemID, kind: LibraryKind, title: String, locator: String? = nil, artworkRef: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.locator = locator
        self.artworkRef = artworkRef
    }
}
