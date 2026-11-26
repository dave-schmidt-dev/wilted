import Foundation

public enum BulletinKind: String, Codable, Sendable {
    case alert
    case headline
}

/// NWS severity vocabulary. Ordered so `.extreme` sorts highest.
public enum BulletinSeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case unknown, minor, moderate, severe, extreme

    private var rank: Int {
        switch self {
        case .unknown: 0
        case .minor: 1
        case .moderate: 2
        case .severe: 3
        case .extreme: 4
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// One spoken interruption: a weather alert or a news headline. Expiry is judged on the
/// receiving device's clock, so a stale bulletin is never spoken late.
public struct Bulletin: Codable, Equatable, Sendable, Identifiable {
    public static let maximumTextCharacters = 16_384
    public static let maximumTextUTF8Bytes = 16_384
    public static let maximumOriginalTextCharacters = 1_060_000
    public static let maximumOriginalTextUTF8Bytes = 1_060_000

    public let id: String
    public let kind: BulletinKind
    public let text: String
    public let severity: BulletinSeverity
    public let issuedAt: Date
    public let expiresAt: Date
    /// The id of an earlier bulletin this one replaces.
    public let supersedes: String?
    /// Stable identity of a headline item, without the `headline:` bulletin prefix.
    public let storyID: String?
    /// Stable identity of the article feed that published the story.
    public let publisherID: String?
    /// Display name of the article feed that published the story.
    public let publisherName: String?
    /// Headline without the publisher text prepended to `text`.
    public let headline: String?
    /// Original article or official alert address, when a safe HTTP(S) link is available.
    public let link: URL?
    /// The article's publication date, when the feed supplied one.
    public let publishedAt: Date?
    /// The source alert wording retained for the listener to open offline.
    public let originalText: String?

    public init(id: String, kind: BulletinKind, text: String, severity: BulletinSeverity = .unknown,
                issuedAt: Date, expiresAt: Date, supersedes: String? = nil,
                storyID: String? = nil, publisherID: String? = nil, publisherName: String? = nil,
                headline: String? = nil, link: URL? = nil, publishedAt: Date? = nil,
                originalText: String? = nil) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryTransportError.transport("bulletin identity is empty")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maximumTextCharacters, text.utf8.count <= Self.maximumTextUTF8Bytes else {
            throw LibraryTransportError.transport(
                "bulletin text must be 1 to \(Self.maximumTextCharacters) characters and \(Self.maximumTextUTF8Bytes) UTF-8 bytes")
        }
        guard issuedAt.timeIntervalSinceReferenceDate.isFinite, expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryTransportError.transport("bulletin dates are not finite")
        }
        guard publishedAt?.timeIntervalSinceReferenceDate.isFinite != false else {
            throw LibraryTransportError.transport("bulletin publication date is not finite")
        }
        if let originalText,
           originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || originalText.count > Self.maximumOriginalTextCharacters
            || originalText.utf8.count > Self.maximumOriginalTextUTF8Bytes {
            throw LibraryTransportError.transport("original bulletin text must be 1 to \(Self.maximumOriginalTextCharacters) characters")
        }
        if let link {
            guard let scheme = link.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  link.host?.isEmpty == false, link.user == nil, link.password == nil else {
                throw LibraryTransportError.transport("headline link must be a safe HTTP(S) address")
            }
        }
        if let headline, headline.count > Self.maximumTextCharacters {
            throw LibraryTransportError.transport("headline title is too long")
        }
        if let publisherName, publisherName.count > 200 {
            throw LibraryTransportError.transport("headline publisher name is too long")
        }
        if let storyID, storyID.isEmpty {
            throw LibraryTransportError.transport("headline identity is empty")
        }
        if let publisherID, publisherID.isEmpty {
            throw LibraryTransportError.transport("headline publisher identity is empty")
        }
        self.id = id
        self.kind = kind
        self.text = text
        self.severity = severity
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.supersedes = supersedes
        self.storyID = storyID
        self.publisherID = publisherID
        self.publisherName = publisherName
        self.headline = headline
        self.link = link
        self.publishedAt = publishedAt
        self.originalText = originalText
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, severity, issuedAt, expiresAt, supersedes
        case storyID, publisherID, publisherName, headline, link, publishedAt, originalText
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            kind: values.decode(BulletinKind.self, forKey: .kind),
            text: values.decode(String.self, forKey: .text),
            severity: values.decode(BulletinSeverity.self, forKey: .severity),
            issuedAt: values.decode(Date.self, forKey: .issuedAt),
            expiresAt: values.decode(Date.self, forKey: .expiresAt),
            supersedes: values.decodeIfPresent(String.self, forKey: .supersedes),
            storyID: values.decodeIfPresent(String.self, forKey: .storyID),
            publisherID: values.decodeIfPresent(String.self, forKey: .publisherID),
            publisherName: values.decodeIfPresent(String.self, forKey: .publisherName),
            headline: values.decodeIfPresent(String.self, forKey: .headline),
            link: values.decodeIfPresent(URL.self, forKey: .link),
            publishedAt: values.decodeIfPresent(Date.self, forKey: .publishedAt),
            originalText: values.decodeIfPresent(String.self, forKey: .originalText)
        )
    }

    public var headlineStoryID: String? {
        guard kind == .headline else { return nil }
        return storyID ?? (id.hasPrefix("headline:") ? String(id.dropFirst("headline:".count)) : nil)
    }

    public func isExpired(at now: Date) -> Bool { expiresAt <= now }
}

/// The Mac-written bulletin channel: the switches that turn every device's interruptions on,
/// and the current headlines. Alerts are not carried here; each playing device runs its own
/// alert monitor while `alertsEnabled` is true.
public struct LibraryBulletins: Codable, Equatable, Sendable {
    public static let maximumHeadlines = 20

    public let alertsEnabled: Bool
    public let headlinesEnabled: Bool
    public let headlines: [Bulletin]
    public let updatedAt: Date?

    public init(alertsEnabled: Bool, headlinesEnabled: Bool, headlines: [Bulletin] = [], updatedAt: Date? = nil) throws {
        guard headlines.count <= Self.maximumHeadlines else {
            throw LibraryTransportError.transport("at most \(Self.maximumHeadlines) headlines may be published")
        }
        self.alertsEnabled = alertsEnabled
        self.headlinesEnabled = headlinesEnabled
        self.headlines = headlines
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case alertsEnabled, headlinesEnabled, headlines, updatedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            alertsEnabled: values.decode(Bool.self, forKey: .alertsEnabled),
            headlinesEnabled: values.decode(Bool.self, forKey: .headlinesEnabled),
            headlines: values.decodeIfPresent([Bulletin].self, forKey: .headlines) ?? [],
            updatedAt: values.decodeIfPresent(Date.self, forKey: .updatedAt)
        )
    }
}
