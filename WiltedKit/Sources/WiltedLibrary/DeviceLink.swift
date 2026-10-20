import Foundation
import WiltedDomain

// MARK: - The device handshake

/// One follower device's announcement: its id and model family, never the person's device name
/// (W-INV-031).
public struct LibraryDeviceAnnouncement: Codable, Sendable, Equatable {
    public let deviceID: String
    /// "iPhone", "iPad" or "Watch".
    public let kind: String
    public let announcedAt: Date

    public init(deviceID: String, kind: String, announcedAt: Date) {
        self.deviceID = deviceID
        self.kind = kind
        self.announcedAt = announcedAt
    }
}

/// Every follower that has synced the library, in one record with a fixed name, so the Mac reads it
/// with each round's batch and starts polling a new device at once instead of after a zone scan.
///
/// It is the one record every follower writes. A write merges the writer's own entry into the
/// server copy and a conflict is retried on the newer copy, so two devices announcing at once lose
/// nothing.
public struct LibraryDeviceDirectory: Codable, Sendable, Equatable {
    /// Oldest announcements beyond this are dropped, so the record stays small.
    public static let maximumDevices = 32

    public let devices: [LibraryDeviceAnnouncement]

    public init(devices: [LibraryDeviceAnnouncement] = []) {
        self.devices = devices.sorted { $0.deviceID < $1.deviceID }
    }

    /// This directory with `announcement` replacing any entry for the same device, keeping the
    /// newest `maximumDevices`.
    public func merging(_ announcement: LibraryDeviceAnnouncement) -> LibraryDeviceDirectory {
        let others = devices.filter { $0.deviceID != announcement.deviceID }
        let kept = (others + [announcement]).sorted { $0.announcedAt > $1.announcedAt }.prefix(Self.maximumDevices)
        return LibraryDeviceDirectory(devices: Array(kept))
    }
}

/// The Mac's answer to one media request, as the requesting device sees it.
public struct LibraryMediaRequestStatus: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable {
        /// The Mac read the request.
        case received
        /// The Mac is uploading the audio.
        case sending
        /// The Mac published its answer: a `ready` offer, or `notReady`.
        case answered
        /// The Mac could not answer; `detail` says why in plain words.
        case failed

        /// A stage a newer Mac wrote reads as `received`, so an older device keeps waiting.
        public init(from decoder: Decoder) throws {
            self = Stage(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .received
        }
    }

    public let intentID: String
    public let entryID: ItemID
    public let stage: Stage
    public let detail: String?
    public let updatedAt: Date

    public init(intentID: String, entryID: ItemID, stage: Stage, detail: String? = nil, updatedAt: Date) {
        self.intentID = intentID
        self.entryID = entryID
        self.stage = stage
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

/// The Mac's side of the handshake with one device, read by that device by name every round.
///
/// The Mac writes it as soon as it learns the device (from the directory or a scan), so the device
/// knows its requests will be read, then updates it as it answers that device's media requests.
/// Only the library writer writes it.
public struct LibraryDeviceLink: Codable, Sendable, Equatable {
    /// Requests older than this, or beyond `maximumRequests`, are dropped from the record.
    public static let requestLifetime: TimeInterval = 2 * 24 * 60 * 60
    public static let maximumRequests = 50

    public let deviceID: String
    /// When the Mac first linked this device.
    public let linkedAt: Date
    public let requests: [LibraryMediaRequestStatus]

    public init(deviceID: String, linkedAt: Date, requests: [LibraryMediaRequestStatus] = []) {
        self.deviceID = deviceID
        self.linkedAt = linkedAt
        self.requests = requests
    }

    /// The status of the request `intentID`, if the Mac has read it.
    public func status(intentID: String) -> LibraryMediaRequestStatus? {
        requests.first { $0.intentID == intentID }
    }

    /// This link with `status` replacing any status for the same intent, keeping the earlier
    /// `linkedAt` of `server` and dropping requests past their lifetime as of `now`.
    public func updating(_ status: LibraryMediaRequestStatus?, server: LibraryDeviceLink?, now: Date) -> LibraryDeviceLink {
        var byIntent: [String: LibraryMediaRequestStatus] = [:]
        for request in (server?.requests ?? []) + requests + [status].compactMap({ $0 }) {
            if let held = byIntent[request.intentID], held.updatedAt > request.updatedAt, request != status { continue }
            byIntent[request.intentID] = request
        }
        let kept = byIntent.values.filter { now.timeIntervalSince($0.updatedAt) <= Self.requestLifetime }
            .sorted { ($0.updatedAt, $0.intentID) > ($1.updatedAt, $1.intentID) }
            .prefix(Self.maximumRequests)
        return LibraryDeviceLink(deviceID: deviceID, linkedAt: min(linkedAt, server?.linkedAt ?? linkedAt),
                                 requests: kept.sorted { ($0.updatedAt, $0.intentID) < ($1.updatedAt, $1.intentID) })
    }
}
