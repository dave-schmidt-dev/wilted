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
    public let stage: PreparationStage
    public let detail: String
    public let fraction: Double?
    public let cancellable: Bool
    public let terminal: Bool
    public let terminalResult: PreparationTerminalResult?
    public let emittedAt: Timestamp
    public let evidence: PreparationEvidence?

    public init(
        stage: PreparationStage,
        detail: String,
        fraction: Double? = nil,
        cancellable: Bool,
        terminalResult: PreparationTerminalResult? = nil,
        emittedAt: Timestamp,
        evidence: PreparationEvidence? = nil
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
        self.stage = stage
        self.detail = detail
        self.fraction = fraction
        self.cancellable = cancellable
        terminal = terminalResult != nil
        self.terminalResult = terminalResult
        self.emittedAt = emittedAt
        self.evidence = evidence
    }

    private enum CodingKeys: CodingKey { case stage, detail, fraction, cancellable, terminal, terminalResult, emittedAt, evidence }

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
            evidence: try container.decodeIfPresent(PreparationEvidence.self, forKey: .evidence)
        )
    }
}
