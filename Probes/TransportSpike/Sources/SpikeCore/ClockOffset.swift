import Foundation

/// One comparison of the publisher's clock against the server's record modification date.
public struct ClockOffsetSample: Codable, Sendable, Equatable {
    public let publisherTimestamp: Date
    public let serverModificationDate: Date

    public init(publisherTimestamp: Date, serverModificationDate: Date) {
        self.publisherTimestamp = publisherTimestamp
        self.serverModificationDate = serverModificationDate
    }

    /// Server time minus publisher time, in seconds. Includes upload latency, so it is an upper
    /// bound on true clock skew: positive means the server stamped the record later.
    public var offsetSeconds: Double {
        serverModificationDate.timeIntervalSince(publisherTimestamp)
    }
}

/// Aggregate of several `ClockOffsetSample`s.
public struct ClockOffset: Codable, Sendable, Equatable {
    public let sampleCount: Int
    public let minSeconds: Double
    public let medianSeconds: Double
    public let maxSeconds: Double

    /// Summarizes samples, or returns nil when there are none.
    public init?(samples: [ClockOffsetSample]) {
        let offsets = samples.map(\.offsetSeconds).sorted()
        guard let first = offsets.first, let last = offsets.last else { return nil }
        let middle = offsets.count / 2
        let median = offsets.count % 2 == 1 ? offsets[middle] : (offsets[middle - 1] + offsets[middle]) / 2
        self.sampleCount = offsets.count
        self.minSeconds = first
        self.medianSeconds = median
        self.maxSeconds = last
    }

    /// Converts a raw publish-to-receive latency into one corrected for publisher clock skew.
    /// Assumes the receiver's clock tracks the server's, so a publisher running behind the server
    /// (positive median offset) inflates the raw latency by that amount.
    public func correctedLatency(rawSeconds: Double) -> Double {
        rawSeconds - medianSeconds
    }
}
