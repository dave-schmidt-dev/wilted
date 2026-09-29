import Foundation

/// The JSON document a spike run writes for later analysis.
public struct SpikeReport: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var device: String
    public var measurements: [Measurement]
    public var handoffs: [HandoffObservation]
    public var clockOffset: ClockOffset?
    public var notes: [String]

    public init(
        generatedAt: Date = Date(),
        device: String,
        measurements: [Measurement] = [],
        handoffs: [HandoffObservation] = [],
        clockOffset: ClockOffset? = nil,
        notes: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.device = device
        self.measurements = measurements
        self.handoffs = handoffs
        self.clockOffset = clockOffset
        self.notes = notes
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> SpikeReport {
        try makeDecoder().decode(SpikeReport.self, from: data)
    }

    /// Writes the report atomically, creating parent directories as needed.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoded().write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> SpikeReport {
        try decode(Data(contentsOf: url))
    }
}
