import Foundation

public enum PreparationStage: String, Codable, Sendable {
    case preparing, fetching, extracting, synthesizing, assembling, saving, completed, failed, cancelled
}

public enum PreparationOutcome: String, Codable, Sendable { case succeeded, failed, cancelled }

/// Bounded structured evidence attached to one durable preparation-log event.
/// Older journals omit this field and continue to decode normally.
public struct PreparationEvidence: Codable, Equatable, Sendable {
    public let kind: String
    public let fields: [String: String]

    public init(kind: String, fields: [String: String]) throws {
        guard !kind.isEmpty, kind.count <= 64, fields.count <= 16,
              fields.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 64 && $0.value.count <= 256 }) else {
            throw DomainError.invalidValue(field: "preparation evidence", reason: "must be bounded")
        }
        self.kind = kind
        self.fields = fields
    }

    private enum CodingKeys: CodingKey { case kind, fields }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: container.decode(String.self, forKey: .kind),
                      fields: container.decode([String: String].self, forKey: .fields))
    }
}

public enum ProducerErrorCode: String, Codable, Sendable {
    case invalidRequest, unsupported, extractionFailed, speechUnavailable, protocolMismatch
    case outputInvalid, timedOut, cancelled, failed
}

public struct ProducerError: Error, Codable, Equatable, Sendable {
    public let code: ProducerErrorCode
    public let message: String
    public let retryable: Bool
    public let stage: String?
    public let underlyingCode: String?

    public init(code: ProducerErrorCode, message: String, retryable: Bool, stage: String? = nil, underlyingCode: String? = nil) throws {
        guard !message.isEmpty, message.count <= 1_024 else {
            throw DomainError.invalidValue(field: "producer error message", reason: "must contain 1...1024 characters")
        }
        self.code = code
        self.message = message
        self.retryable = retryable
        self.stage = stage
        self.underlyingCode = underlyingCode
    }

    private enum CodingKeys: CodingKey { case code, message, retryable, stage, underlyingCode }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            code: container.decode(ProducerErrorCode.self, forKey: .code),
            message: container.decode(String.self, forKey: .message),
            retryable: container.decode(Bool.self, forKey: .retryable),
            stage: container.decodeIfPresent(String.self, forKey: .stage),
            underlyingCode: container.decodeIfPresent(String.self, forKey: .underlyingCode)
        )
    }
}

public struct PreparationTerminalResult: Codable, Equatable, Sendable {
    public let outcome: PreparationOutcome
    public let revisionID: RevisionID?
    public let error: ProducerError?

    public init(outcome: PreparationOutcome, revisionID: RevisionID? = nil, error: ProducerError? = nil) throws {
        let valid = switch outcome {
        case .succeeded: revisionID != nil && error == nil
        case .failed: revisionID == nil && error != nil
        case .cancelled: revisionID == nil && error == nil
        }
        guard valid else { throw DomainError.invalidValue(field: "terminalResult", reason: "payload does not match outcome") }
        self.outcome = outcome
        self.revisionID = revisionID
        self.error = error
    }

    private enum CodingKeys: CodingKey { case outcome, revisionID, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            outcome: container.decode(PreparationOutcome.self, forKey: .outcome),
            revisionID: container.decodeIfPresent(RevisionID.self, forKey: .revisionID),
            error: container.decodeIfPresent(ProducerError.self, forKey: .error)
        )
    }
}

public struct PreparationStatus: Codable, Equatable, Sendable {
    /// The normalized bridge between an episode's original clock and the
    /// prepared file's clock. It belongs to the terminal status because it is
    /// evidence of what a completed preparation actually removed.
    public struct PreparationTimeline: Codable, Equatable, Sendable {
        public static let maximumRemovedIntervals = 512
        public static let maximumKeptIntervals = 512
        public static let maximumLabelLength = 256

        public struct RemovedInterval: Codable, Equatable, Sendable {
            public let originalStartSeconds: Double
            public let originalEndSeconds: Double
            public let label: String
            public let confidence: Double

            public init(originalStartSeconds: Double, originalEndSeconds: Double, label: String, confidence: Double) throws {
                guard PreparationTimeline.validRange(start: originalStartSeconds, end: originalEndSeconds),
                      confidence.isFinite, (0...1).contains(confidence) else {
                    throw DomainError.invalidValue(field: "preparation timeline removed interval", reason: "must use finite, ordered values")
                }
                let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedLabel.isEmpty, normalizedLabel.count <= PreparationTimeline.maximumLabelLength else {
                    throw DomainError.invalidValue(field: "preparation timeline label", reason: "must contain 1...256 characters")
                }
                self.originalStartSeconds = originalStartSeconds
                self.originalEndSeconds = originalEndSeconds
                self.label = normalizedLabel
                self.confidence = confidence
            }

            private enum CodingKeys: CodingKey { case originalStartSeconds, originalEndSeconds, label, confidence }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    originalStartSeconds: container.decode(Double.self, forKey: .originalStartSeconds),
                    originalEndSeconds: container.decode(Double.self, forKey: .originalEndSeconds),
                    label: container.decode(String.self, forKey: .label),
                    confidence: container.decode(Double.self, forKey: .confidence)
                )
            }
        }

        public struct KeptInterval: Codable, Equatable, Sendable {
            public let originalStartSeconds: Double
            public let originalEndSeconds: Double
            public let outputStartSeconds: Double

            public init(originalStartSeconds: Double, originalEndSeconds: Double, outputStartSeconds: Double) throws {
                guard PreparationTimeline.validRange(start: originalStartSeconds, end: originalEndSeconds),
                      outputStartSeconds.isFinite, outputStartSeconds >= 0 else {
                    throw DomainError.invalidValue(field: "preparation timeline kept interval", reason: "must use finite, ordered values")
                }
                self.originalStartSeconds = originalStartSeconds
                self.originalEndSeconds = originalEndSeconds
                self.outputStartSeconds = outputStartSeconds
            }

            private enum CodingKeys: CodingKey { case originalStartSeconds, originalEndSeconds, outputStartSeconds }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    originalStartSeconds: container.decode(Double.self, forKey: .originalStartSeconds),
                    originalEndSeconds: container.decode(Double.self, forKey: .originalEndSeconds),
                    outputStartSeconds: container.decode(Double.self, forKey: .outputStartSeconds)
                )
            }
        }

        public let removed: [RemovedInterval]
        public let kept: [KeptInterval]

        public init(removed: [RemovedInterval], kept: [KeptInterval]) throws {
            guard removed.count <= Self.maximumRemovedIntervals, kept.count <= Self.maximumKeptIntervals else {
                throw DomainError.invalidValue(field: "preparation timeline", reason: "contains too many intervals")
            }
            guard Self.areOrderedAndNonoverlapping(removed.map { ($0.originalStartSeconds, $0.originalEndSeconds) }),
                  Self.areOrderedAndNonoverlapping(kept.map { ($0.originalStartSeconds, $0.originalEndSeconds) }) else {
                throw DomainError.invalidValue(field: "preparation timeline", reason: "intervals must be ordered and nonoverlapping")
            }
            let allIntervals = removed.map { ($0.originalStartSeconds, $0.originalEndSeconds) }
                + kept.map { ($0.originalStartSeconds, $0.originalEndSeconds) }
            guard Self.areNonoverlappingWhenSorted(allIntervals) else {
                throw DomainError.invalidValue(field: "preparation timeline", reason: "removed and kept intervals must not overlap")
            }
            var expectedOutputStart = 0.0
            for interval in kept {
                guard abs(interval.outputStartSeconds - expectedOutputStart) <= 0.000_001 else {
                    throw DomainError.invalidValue(field: "preparation timeline output", reason: "must be contiguous from zero")
                }
                expectedOutputStart += interval.originalEndSeconds - interval.originalStartSeconds
            }
            self.removed = removed
            self.kept = kept
        }

        private enum CodingKeys: CodingKey { case removed, kept }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                removed: container.decode([RemovedInterval].self, forKey: .removed),
                kept: container.decode([KeptInterval].self, forKey: .kept)
            )
        }

        private static func validRange(start: Double, end: Double) -> Bool {
            start.isFinite && end.isFinite && start >= 0 && end >= 0 && end > start
        }

        private static func areOrderedAndNonoverlapping(_ intervals: [(Double, Double)]) -> Bool {
            zip(intervals, intervals.dropFirst()).allSatisfy { $0.1.0 >= $0.0.1 }
        }

        private static func areNonoverlappingWhenSorted(_ intervals: [(Double, Double)]) -> Bool {
            let sorted = intervals.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            return zip(sorted, sorted.dropFirst()).allSatisfy { $0.1.0 >= $0.0.1 }
        }
    }

    public let stage: PreparationStage
    public let detail: String
    public let fraction: Double?
    public let cancellable: Bool
    public let terminal: Bool
    public let terminalResult: PreparationTerminalResult?
    public let emittedAt: Timestamp
    public let evidence: PreparationEvidence?
    /// Absent on journals created before preparation timelines existed.
    public let timeline: PreparationTimeline?

    public init(
        stage: PreparationStage,
        detail: String,
        fraction: Double? = nil,
        cancellable: Bool,
        terminalResult: PreparationTerminalResult? = nil,
        emittedAt: Timestamp,
        evidence: PreparationEvidence? = nil,
        timeline: PreparationTimeline? = nil
    ) throws {
        guard !detail.isEmpty, detail.count <= 1_024 else {
            throw DomainError.invalidValue(field: "preparation detail", reason: "must contain 1...1024 characters")
        }
        if let fraction, !fraction.isFinite || !(0...1).contains(fraction) {
            throw DomainError.invalidValue(field: "fraction", reason: "must be within zero and one")
        }
        let terminalStages: Set<PreparationStage> = [.completed, .failed, .cancelled]
        guard (terminalResult != nil) == terminalStages.contains(stage) else {
            throw DomainError.invalidValue(field: "terminalResult", reason: "must match terminal stage")
        }
        guard timeline == nil || terminalResult?.outcome == .succeeded else {
            throw DomainError.invalidValue(field: "preparation timeline", reason: "belongs only to a successful terminal status")
        }
        self.stage = stage
        self.detail = detail
        self.fraction = fraction
        self.cancellable = cancellable
        terminal = terminalResult != nil
        self.terminalResult = terminalResult
        self.emittedAt = emittedAt
        self.evidence = evidence
        self.timeline = timeline
    }

    private enum CodingKeys: CodingKey { case stage, detail, fraction, cancellable, terminal, terminalResult, emittedAt, evidence, timeline }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedTerminal = try container.decode(Bool.self, forKey: .terminal)
        let result = try container.decodeIfPresent(PreparationTerminalResult.self, forKey: .terminalResult)
        guard encodedTerminal == (result != nil) else {
            throw DomainError.invalidValue(field: "terminal", reason: "must agree with terminalResult")
        }
        try self.init(
            stage: container.decode(PreparationStage.self, forKey: .stage),
            detail: container.decode(String.self, forKey: .detail),
            fraction: container.decodeIfPresent(Double.self, forKey: .fraction),
            cancellable: container.decode(Bool.self, forKey: .cancellable),
            terminalResult: result,
            emittedAt: container.decode(Timestamp.self, forKey: .emittedAt),
            evidence: try container.decodeIfPresent(PreparationEvidence.self, forKey: .evidence),
            timeline: try container.decodeIfPresent(PreparationTimeline.self, forKey: .timeline)
        )
    }
}
