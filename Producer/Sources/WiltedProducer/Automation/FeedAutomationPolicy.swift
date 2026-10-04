import Foundation

/// A feed-level choice that either inherits the global setting or overrides it.
public enum FeedAutomationOverride: String, Codable, CaseIterable, Hashable, Sendable {
    case useGlobal
    case on
    case off

    func resolve(globalValue: Bool) -> Bool {
        switch self {
        case .useGlobal: globalValue
        case .on: true
        case .off: false
        }
    }
}

/// A feed-level kept-limit choice that either inherits the global limit or
/// supplies its own positive count.
public enum FeedKeptLimitOverride: Hashable, Sendable {
    case useGlobal
    case explicit(Int)
}

extension FeedKeptLimitOverride: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case count
    }

    private enum Kind: String, Codable {
        case useGlobal
        case explicit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .useGlobal:
            self = .useGlobal
        case .explicit:
            let count = try container.decode(Int.self, forKey: .count)
            guard count > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .count,
                    in: container,
                    debugDescription: "A kept-limit override must be positive."
                )
            }
            self = .explicit(count)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .useGlobal:
            try container.encode(Kind.useGlobal, forKey: .kind)
        case let .explicit(count):
            guard count > 0 else {
                throw EncodingError.invalidValue(
                    count,
                    .init(codingPath: encoder.codingPath,
                          debugDescription: "A kept-limit override must be positive.")
                )
            }
            try container.encode(Kind.explicit, forKey: .kind)
            try container.encode(count, forKey: .count)
        }
    }
}

/// Global automation values used when a feed does not override a setting.
public struct FeedAutomationGlobalDefaults: Codable, Equatable, Hashable, Sendable {
    public let autoKeep: Bool
    public let autoDownload: Bool
    public let autoPrepare: Bool
    public let keptLimit: Int?

    /// The product defaults: keep and download off, prepare on, and no limit.
    public static let standard = FeedAutomationGlobalDefaults()

    public init(autoKeep: Bool = false, autoDownload: Bool = false, autoPrepare: Bool = true,
                keptLimit: Int? = nil) {
        self.autoKeep = autoKeep
        self.autoDownload = autoDownload
        self.autoPrepare = autoPrepare
        self.keptLimit = keptLimit.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Feed-specific automation settings before inheritance is resolved.
public struct FeedAutomationPolicy: Codable, Equatable, Hashable, Sendable {
    public let autoKeep: FeedAutomationOverride
    public let autoDownload: FeedAutomationOverride
    public let autoPrepare: FeedAutomationOverride
    public let keptLimit: FeedKeptLimitOverride

    public init(autoKeep: FeedAutomationOverride = .useGlobal,
                autoDownload: FeedAutomationOverride = .useGlobal,
                autoPrepare: FeedAutomationOverride = .useGlobal,
                keptLimit: FeedKeptLimitOverride = .useGlobal) {
        self.autoKeep = autoKeep
        self.autoDownload = autoDownload
        self.autoPrepare = autoPrepare
        self.keptLimit = keptLimit
    }

    /// Resolves this feed's overrides against the supplied global defaults.
    public func resolved(using defaults: FeedAutomationGlobalDefaults = .standard) -> EffectiveFeedAutomationPolicy {
        EffectiveFeedAutomationPolicy(
            autoKeep: autoKeep.resolve(globalValue: defaults.autoKeep),
            autoDownload: autoDownload.resolve(globalValue: defaults.autoDownload),
            autoPrepare: autoPrepare.resolve(globalValue: defaults.autoPrepare),
            keptLimit: keptLimit.resolve(globalValue: defaults.keptLimit)
        )
    }
}

extension FeedKeptLimitOverride {
    func resolve(globalValue: Int?) -> Int? {
        switch self {
        case .useGlobal:
            globalValue
        case let .explicit(count):
            count > 0 ? count : nil
        }
    }
}

/// The plain values used by automation after global and feed settings combine.
public struct EffectiveFeedAutomationPolicy: Codable, Equatable, Hashable, Sendable {
    public let autoKeep: Bool
    public let autoDownload: Bool
    public let autoPrepare: Bool
    public let keptLimit: Int?

    public init(autoKeep: Bool, autoDownload: Bool, autoPrepare: Bool, keptLimit: Int?) {
        self.autoKeep = autoKeep
        self.autoDownload = autoDownload
        self.autoPrepare = autoPrepare
        self.keptLimit = keptLimit.flatMap { $0 > 0 ? $0 : nil }
    }
}
