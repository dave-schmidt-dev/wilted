import Foundation
import WiltedDomain

/// Information about the labelling attempt recorded on a preparation result or journal entry.
public struct LabelledAttemptOutcomeInfo: Equatable, Sendable {
    public let provider: String
    public let modelID: String
    public let level: String

    public static let unknownValue = "unknown"

    public init(provider: String, modelID: String, level: String) {
        self.provider = provider.isEmpty ? Self.unknownValue : provider
        self.modelID = modelID.isEmpty ? Self.unknownValue : modelID
        self.level = level.isEmpty ? Self.unknownValue : level
    }

    /// Decodes labelled attempt outcome info from journal evidence fields, decoding older records as "unknown".
    public static func decode(from fields: [String: String]) -> LabelledAttemptOutcomeInfo {
        LabelledAttemptOutcomeInfo(
            provider: fields["provider"] ?? unknownValue,
            modelID: fields["modelID"] ?? fields["labellerModelID"] ?? unknownValue,
            level: fields["level"] ?? fields["labellerLevel"] ?? unknownValue
        )
    }

    /// Decodes labelled attempt outcome info from a worker cut request or audit dictionary, decoding older records as "unknown".
    public static func decode(from dictionary: [String: Any]) -> LabelledAttemptOutcomeInfo {
        LabelledAttemptOutcomeInfo(
            provider: (dictionary["provider"] as? String) ?? (dictionary["labellerProvider"] as? String) ?? unknownValue,
            modelID: (dictionary["modelID"] as? String) ?? (dictionary["labellerModelID"] as? String) ?? (dictionary["model"] as? String) ?? unknownValue,
            level: (dictionary["level"] as? String) ?? (dictionary["labellerLevel"] as? String) ?? (dictionary["reasoningLevel"] as? String) ?? unknownValue
        )
    }
}
