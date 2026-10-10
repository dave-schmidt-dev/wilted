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
    public static let maximumTextCharacters = 600

    public let id: String
    public let kind: BulletinKind
    public let text: String
    public let severity: BulletinSeverity
    public let issuedAt: Date
    public let expiresAt: Date
    /// The id of an earlier bulletin this one replaces.
    public let supersedes: String?

    public init(id: String, kind: BulletinKind, text: String, severity: BulletinSeverity = .unknown,
                issuedAt: Date, expiresAt: Date, supersedes: String? = nil) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryTransportError.transport("bulletin identity is empty")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= Self.maximumTextCharacters else {
            throw LibraryTransportError.transport("bulletin text must be 1 to \(Self.maximumTextCharacters) characters")
        }
        guard issuedAt.timeIntervalSinceReferenceDate.isFinite, expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryTransportError.transport("bulletin dates are not finite")
        }
        self.id = id
        self.kind = kind
        self.text = text
        self.severity = severity
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.supersedes = supersedes
    }

    private enum CodingKeys: String, CodingKey { case id, kind, text, severity, issuedAt, expiresAt, supersedes }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            kind: values.decode(BulletinKind.self, forKey: .kind),
            text: values.decode(String.self, forKey: .text),
            severity: values.decode(BulletinSeverity.self, forKey: .severity),
            issuedAt: values.decode(Date.self, forKey: .issuedAt),
            expiresAt: values.decode(Date.self, forKey: .expiresAt),
            supersedes: values.decodeIfPresent(String.self, forKey: .supersedes)
        )
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
