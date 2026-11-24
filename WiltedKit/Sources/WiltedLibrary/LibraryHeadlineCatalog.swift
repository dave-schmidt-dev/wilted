import Foundation

/// A story card retained by the library owner after its live headline expires.
public struct LibraryHeadlineStory: Codable, Equatable, Sendable, Identifiable {
    public static let maximumIDLength = 1_024
    public static let maximumTitleLength = 1_024
    public static let maximumPublisherIDLength = 512
    public static let maximumPublisherNameLength = 512

    public let id: String
    public let title: String
    public let publisherID: String
    public let publisherName: String
    /// The original link from the publisher's item. It is preserved for Read story.
    public let link: URL?
    public let publishedAt: Date?
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    /// Non-nil while this story is saved beyond Recent.
    public let savedAt: Date?
    /// Revision of this story's saved state, independent of catalog refreshes.
    public let savedRevision: Int64

    public var isSaved: Bool { savedAt != nil }
    /// Stable age and ordering anchor shared by Mac and iOS Recent views.
    public var recentAnchorAt: Date { publishedAt ?? firstSeenAt }

    public func isRecent(at date: Date) -> Bool {
        recentAnchorAt >= date.addingTimeInterval(-LibraryHeadlineProjection.recentRetention)
    }

    public init(
        id: String,
        title: String,
        publisherID: String,
        publisherName: String,
        link: URL?,
        publishedAt: Date?,
        firstSeenAt: Date,
        lastSeenAt: Date,
        savedAt: Date? = nil,
        savedRevision: Int64 = 0
    ) throws {
        guard Self.isValid(id, maximumLength: Self.maximumIDLength) else {
            throw LibraryTransportError.transport("headline story id is invalid")
        }
        guard Self.isValid(title, maximumLength: Self.maximumTitleLength) else {
            throw LibraryTransportError.transport("headline title is invalid")
        }
        guard Self.isValid(publisherID, maximumLength: Self.maximumPublisherIDLength) else {
            throw LibraryTransportError.transport("headline publisher id is invalid")
        }
        guard Self.isValid(publisherName, maximumLength: Self.maximumPublisherNameLength) else {
            throw LibraryTransportError.transport("headline publisher name is invalid")
        }
        if let link {
            guard ["http", "https"].contains(link.scheme?.lowercased() ?? ""), link.host?.isEmpty == false,
                  link.user == nil, link.password == nil,
                  link.absoluteString.utf8.count <= 4_096 else {
                throw LibraryTransportError.transport("headline link must be a credential-free HTTP or HTTPS URL")
            }
        }
        let dates = [publishedAt, Optional(firstSeenAt), Optional(lastSeenAt), savedAt].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryTransportError.transport("headline dates must be finite")
        }
        guard savedRevision >= 0 else {
            throw LibraryTransportError.transport("headline saved revision must be non-negative")
        }
        self.id = id
        self.title = title
        self.publisherID = publisherID
        self.publisherName = publisherName
        self.link = link
        self.publishedAt = publishedAt
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.savedAt = savedAt
        self.savedRevision = savedRevision
    }

    private static func isValid(_ value: String, maximumLength: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= maximumLength
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, publisherID, publisherName, link, publishedAt, firstSeenAt, lastSeenAt, savedAt, savedRevision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            title: values.decode(String.self, forKey: .title),
            publisherID: values.decode(String.self, forKey: .publisherID),
            publisherName: values.decode(String.self, forKey: .publisherName),
            link: values.decodeIfPresent(URL.self, forKey: .link),
            publishedAt: values.decodeIfPresent(Date.self, forKey: .publishedAt),
            firstSeenAt: values.decode(Date.self, forKey: .firstSeenAt),
            lastSeenAt: values.decode(Date.self, forKey: .lastSeenAt),
            savedAt: values.decodeIfPresent(Date.self, forKey: .savedAt),
            savedRevision: values.decodeIfPresent(Int64.self, forKey: .savedRevision) ?? 0
        )
    }
}

/// Mac-owned mute state for one publisher. Revisions change only when this publisher's state changes.
public struct LibraryHeadlinePublisher: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isMuted: Bool
    public let revision: Int64

    public init(id: String, name: String, isMuted: Bool, revision: Int64) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.count <= 512 else {
            throw LibraryTransportError.transport("headline publisher id is invalid")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 512 else {
            throw LibraryTransportError.transport("headline publisher name is invalid")
        }
        guard revision >= 0 else { throw LibraryTransportError.transport("publisher revision must be non-negative") }
        self.id = id
        self.name = name
        self.isMuted = isMuted
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case id, name, isMuted, revision }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            isMuted: values.decode(Bool.self, forKey: .isMuted),
            revision: values.decode(Int64.self, forKey: .revision))
    }
}

/// Compact compare-and-set state retained after an unsaved story leaves Recent.
public struct LibraryHeadlineStoryIdentity: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let publisherID: String
    public let link: URL?
    public let savedRevision: Int64

    public init(id: String, publisherID: String, link: URL?, savedRevision: Int64) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.count <= 1_024,
              !publisherID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, publisherID.count <= 512,
              savedRevision >= 0 else {
            throw LibraryTransportError.transport("expired headline identity is invalid")
        }
        if let link {
            guard ["http", "https"].contains(link.scheme?.lowercased() ?? ""), link.host?.isEmpty == false,
                  link.user == nil, link.password == nil, link.absoluteString.utf8.count <= 4_096 else {
                throw LibraryTransportError.transport("expired headline link is invalid")
            }
        }
        self.id = id
        self.publisherID = publisherID
        self.link = link
        self.savedRevision = savedRevision
    }

    private enum CodingKeys: String, CodingKey { case id, publisherID, link, savedRevision }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            publisherID: values.decode(String.self, forKey: .publisherID),
            link: values.decodeIfPresent(URL.self, forKey: .link),
            savedRevision: values.decode(Int64.self, forKey: .savedRevision))
    }
}

/// The complete Mac-authored story state projected to followers and cached for offline display.
public struct LibraryHeadlineProjection: Codable, Equatable, Sendable {
    public static let recentRetention: TimeInterval = 7 * 24 * 60 * 60

    public let generationID: String
    public let revision: Int64
    public let updatedAt: Date
    public let recent: [LibraryHeadlineStory]
    public let saved: [LibraryHeadlineStory]
    public let publishers: [LibraryHeadlinePublisher]
    public let expiredIdentities: [LibraryHeadlineStoryIdentity]

    public init(
        generationID: String = UUID().uuidString,
        revision: Int64,
        updatedAt: Date,
        recent: [LibraryHeadlineStory],
        saved: [LibraryHeadlineStory],
        publishers: [LibraryHeadlinePublisher],
        expiredIdentities: [LibraryHeadlineStoryIdentity] = []
    ) throws {
        guard Self.validGenerationID(generationID),
              revision >= 0, updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryTransportError.transport("headline projection revision or date is invalid")
        }
        guard Set(recent.map(\.id)).count == recent.count,
              Set(saved.map(\.id)).count == saved.count,
              Set(publishers.map(\.id)).count == publishers.count,
              Set(expiredIdentities.map(\.id)).count == expiredIdentities.count,
              Set(expiredIdentities.map(\.id)).isDisjoint(with: Set(recent.map(\.id))),
              Set(expiredIdentities.map(\.id)).isDisjoint(with: Set(saved.map(\.id))) else {
            throw LibraryTransportError.transport("headline projection contains duplicate identities")
        }
        guard saved.allSatisfy(\.isSaved) else {
            throw LibraryTransportError.transport("saved headline projection contains an unsaved story")
        }
        self.generationID = generationID
        self.revision = revision
        self.updatedAt = updatedAt
        self.recent = recent
        self.saved = saved
        self.publishers = publishers
        self.expiredIdentities = expiredIdentities
    }

    private enum CodingKeys: String, CodingKey {
        case generationID, revision, updatedAt, recent, saved, publishers, expiredIdentities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            generationID: values.decode(String.self, forKey: .generationID),
            revision: values.decode(Int64.self, forKey: .revision),
            updatedAt: values.decode(Date.self, forKey: .updatedAt),
            recent: values.decode([LibraryHeadlineStory].self, forKey: .recent),
            saved: values.decode([LibraryHeadlineStory].self, forKey: .saved),
            publishers: values.decode([LibraryHeadlinePublisher].self, forKey: .publishers),
            expiredIdentities: values.decodeIfPresent([LibraryHeadlineStoryIdentity].self, forKey: .expiredIdentities) ?? [])
    }

    private static func validGenerationID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

/// Counts needed to remove a superseded immutable generation after the new index lands.
public struct LibraryHeadlineProjectionGeneration: Codable, Equatable, Sendable {
    public let id: String
    public let recentPageCount: Int
    public let savedPageCount: Int
    public let publisherPageCount: Int
    public let expiredPageCount: Int

    public init(
        id: String, recentPageCount: Int, savedPageCount: Int, publisherPageCount: Int, expiredPageCount: Int = 0
    ) throws {
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              (0...LibraryHeadlineProjectionIndex.maximumPagesPerSection).contains(recentPageCount),
              (0...LibraryHeadlineProjectionIndex.maximumPagesPerSection).contains(savedPageCount),
              (0...LibraryHeadlineProjectionIndex.maximumPagesPerSection).contains(publisherPageCount),
              (0...LibraryHeadlineProjectionIndex.maximumPagesPerSection).contains(expiredPageCount) else {
            throw LibraryTransportError.transport("headline projection generation is invalid")
        }
        self.id = id
        self.recentPageCount = recentPageCount
        self.savedPageCount = savedPageCount
        self.publisherPageCount = publisherPageCount
        self.expiredPageCount = expiredPageCount
    }

    private enum CodingKeys: String, CodingKey { case id, recentPageCount, savedPageCount, publisherPageCount, expiredPageCount }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            recentPageCount: values.decode(Int.self, forKey: .recentPageCount),
            savedPageCount: values.decode(Int.self, forKey: .savedPageCount),
            publisherPageCount: values.decode(Int.self, forKey: .publisherPageCount),
            expiredPageCount: values.decodeIfPresent(Int.self, forKey: .expiredPageCount) ?? 0)
    }
}

/// A stable-generation index. Pages are written first, then this record is replaced.
public struct LibraryHeadlineProjectionIndex: Codable, Equatable, Sendable {
    public static let maximumPagesPerSection = 512

    public let generationID: String
    public let revision: Int64
    public let updatedAt: Date
    public let recentPageCount: Int
    public let savedPageCount: Int
    public let publisherPageCount: Int
    public let expiredPageCount: Int
    public let retiredGenerations: [LibraryHeadlineProjectionGeneration]
    /// Pages written for a candidate index that is not yet visible to readers.
    public let stagedGenerations: [LibraryHeadlineProjectionGeneration]

    public init(
        generationID: String,
        revision: Int64,
        updatedAt: Date,
        recentPageCount: Int,
        savedPageCount: Int,
        publisherPageCount: Int,
        expiredPageCount: Int = 0,
        retiredGenerations: [LibraryHeadlineProjectionGeneration] = [],
        stagedGenerations: [LibraryHeadlineProjectionGeneration] = []
    ) throws {
        guard !generationID.isEmpty, generationID.count <= 64,
              generationID.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              revision >= 0, updatedAt.timeIntervalSinceReferenceDate.isFinite,
              (0...Self.maximumPagesPerSection).contains(recentPageCount),
              (0...Self.maximumPagesPerSection).contains(savedPageCount),
              (0...Self.maximumPagesPerSection).contains(publisherPageCount),
              (0...Self.maximumPagesPerSection).contains(expiredPageCount),
              retiredGenerations.count <= 8,
              Set(retiredGenerations.map(\.id)).count == retiredGenerations.count,
              !retiredGenerations.contains(where: { $0.id == generationID }),
              stagedGenerations.count <= 1,
              Set(stagedGenerations.map(\.id)).count == stagedGenerations.count,
              !stagedGenerations.contains(where: { staged in
                  staged.id == generationID || retiredGenerations.contains(where: { $0.id == staged.id })
              }) else {
            throw LibraryTransportError.transport("headline projection index is invalid")
        }
        self.generationID = generationID
        self.revision = revision
        self.updatedAt = updatedAt
        self.recentPageCount = recentPageCount
        self.savedPageCount = savedPageCount
        self.publisherPageCount = publisherPageCount
        self.expiredPageCount = expiredPageCount
        self.retiredGenerations = retiredGenerations
        self.stagedGenerations = stagedGenerations
    }

    private enum CodingKeys: String, CodingKey {
        case generationID, revision, updatedAt, recentPageCount, savedPageCount, publisherPageCount, expiredPageCount,
             retiredGenerations, stagedGenerations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            generationID: values.decode(String.self, forKey: .generationID),
            revision: values.decode(Int64.self, forKey: .revision),
            updatedAt: values.decode(Date.self, forKey: .updatedAt),
            recentPageCount: values.decode(Int.self, forKey: .recentPageCount),
            savedPageCount: values.decode(Int.self, forKey: .savedPageCount),
            publisherPageCount: values.decode(Int.self, forKey: .publisherPageCount),
            expiredPageCount: values.decodeIfPresent(Int.self, forKey: .expiredPageCount) ?? 0,
            retiredGenerations: values.decodeIfPresent([LibraryHeadlineProjectionGeneration].self, forKey: .retiredGenerations) ?? [],
            stagedGenerations: values.decodeIfPresent([LibraryHeadlineProjectionGeneration].self, forKey: .stagedGenerations) ?? [])
    }
}

/// One bounded CloudKit page belonging to an immutable projection generation.
public struct LibraryHeadlineProjectionPage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case recent, saved, publishers, expired }

    public static let maximumStories = 24
    public static let maximumPublishers = 128
    public static let maximumExpiredIdentities = 48

    public let generationID: String
    public let kind: Kind
    public let pageIndex: Int
    public let stories: [LibraryHeadlineStory]
    public let publishers: [LibraryHeadlinePublisher]
    public let storyIdentities: [LibraryHeadlineStoryIdentity]

    public init(
        generationID: String,
        kind: Kind,
        pageIndex: Int,
        stories: [LibraryHeadlineStory] = [],
        publishers: [LibraryHeadlinePublisher] = [],
        storyIdentities: [LibraryHeadlineStoryIdentity] = []
    ) throws {
        guard !generationID.isEmpty, generationID.count <= 64,
              generationID.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              (0..<LibraryHeadlineProjectionIndex.maximumPagesPerSection).contains(pageIndex),
              stories.count <= Self.maximumStories, publishers.count <= Self.maximumPublishers,
              storyIdentities.count <= Self.maximumExpiredIdentities else {
            throw LibraryTransportError.transport("headline projection page exceeds its bounds")
        }
        switch kind {
        case .recent, .saved:
            guard publishers.isEmpty else { throw LibraryTransportError.transport("story page contains publishers") }
            if kind == .saved, !stories.allSatisfy(\.isSaved) {
                throw LibraryTransportError.transport("saved page contains an unsaved story")
            }
        case .publishers:
            guard stories.isEmpty, storyIdentities.isEmpty else {
                throw LibraryTransportError.transport("publisher page contains story data")
            }
        case .expired:
            guard stories.isEmpty, publishers.isEmpty,
                  Set(storyIdentities.map(\.id)).count == storyIdentities.count else {
                throw LibraryTransportError.transport("expired identity page contains invalid data")
            }
        }
        self.generationID = generationID
        self.kind = kind
        self.pageIndex = pageIndex
        self.stories = stories
        self.publishers = publishers
        self.storyIdentities = storyIdentities
    }

    private enum CodingKeys: String, CodingKey { case generationID, kind, pageIndex, stories, publishers, storyIdentities }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            generationID: values.decode(String.self, forKey: .generationID),
            kind: values.decode(Kind.self, forKey: .kind),
            pageIndex: values.decode(Int.self, forKey: .pageIndex),
            stories: values.decodeIfPresent([LibraryHeadlineStory].self, forKey: .stories) ?? [],
            publishers: values.decodeIfPresent([LibraryHeadlinePublisher].self, forKey: .publishers) ?? [],
            storyIdentities: values.decodeIfPresent([LibraryHeadlineStoryIdentity].self, forKey: .storyIdentities) ?? [])
    }
}
