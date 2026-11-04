import CoreFoundation
import Darwin
import Foundation
import WiltedDomain

@_silgen_name("flock")
private func adProfilePOSIXFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

private let adProfileStoreVersion = 1
private let adProfileStoreMaximumBytes = 1_048_576
private let adProfileStoreMaximumFeeds = 256
private let adProfileMaximumObservations = 20
private let adProfileLockAttempts = 50
private let adProfileLockPauseMicroseconds: useconds_t = 5_000

private struct AdProfileStoreDocument: Codable, Equatable {
    var schemaVersion: Int
    var feeds: [AdProfileFeedRecord]
}

private struct AdProfileFeedRecord: Codable, Equatable {
    var feedID: String
    var subscriptionEpoch: Double
    var profile: PodcastAdProfileEnvelope?
    var importedProfile: PodcastAdProfileEnvelope?
    var observations: [PodcastAdProfileObservation]

    enum CodingKeys: String, CodingKey { case feedID, subscriptionEpoch, profile, importedProfile, observations }

    init(feedID: String, subscriptionEpoch: Double, profile: PodcastAdProfileEnvelope? = nil,
         importedProfile: PodcastAdProfileEnvelope? = nil, observations: [PodcastAdProfileObservation] = []) {
        self.feedID = feedID
        self.subscriptionEpoch = subscriptionEpoch
        self.profile = profile
        self.importedProfile = importedProfile
        self.observations = observations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        feedID = try values.decode(String.self, forKey: .feedID)
        subscriptionEpoch = try values.decode(Double.self, forKey: .subscriptionEpoch)
        profile = try values.decodeIfPresent(PodcastAdProfileEnvelope.self, forKey: .profile)
        importedProfile = try values.decodeIfPresent(PodcastAdProfileEnvelope.self, forKey: .importedProfile)
        observations = try values.decode([PodcastAdProfileObservation].self, forKey: .observations)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(feedID, forKey: .feedID)
        try values.encode(subscriptionEpoch, forKey: .subscriptionEpoch)
        // Explicit nulls are part of the shared Python importer format.
        try values.encode(profile, forKey: .profile)
        try values.encode(importedProfile, forKey: .importedProfile)
        try values.encode(observations, forKey: .observations)
    }
}

extension LocalLibraryStore {
    /// Reconciles bounded profiles with the durable active subscription set.
    /// Call on library snapshots and after an explicit subscription change.
    public func reconcileAdPlacementProfiles() throws {
        let podcastIDs = Set(try podcastFeeds().map(\.itemID))
        let active = try subscriptions().filter { podcastIDs.contains($0.feedID) }
        try reconcileAdPlacementProfiles(for: active)
    }

    func reconcileAdPlacementProfiles(for active: [PodcastSubscription]) throws {
        var epochs: [String: Double] = [:]
        for subscription in active {
            let feedID = subscription.feedID.rawValue
            let epoch = subscription.subscribedAt.date.timeIntervalSince1970
            guard epoch.isFinite else { continue }
            epochs[feedID] = epoch
        }
        if reconciledAdProfileSubscriptionEpochs == epochs { return }
        try mutateAdProfileStore { document in
            var records: [String: AdProfileFeedRecord] = [:]
            for (feedID, epoch) in epochs.sorted(by: { $0.key < $1.key }) {
                guard epoch.isFinite else { continue }
                if let existing = document.feeds.first(where: { $0.feedID == feedID }), existing.subscriptionEpoch == epoch {
                    records[feedID] = existing
                } else {
                    records[feedID] = AdProfileFeedRecord(feedID: feedID, subscriptionEpoch: epoch)
                }
            }
            document.feeds = records.values.sorted { $0.feedID < $1.feedID }
            guard document.feeds.count <= adProfileStoreMaximumFeeds else { throw PodcastAdProfileError.feedLimitReached }
        }
        reconciledAdProfileSubscriptionEpochs = epochs
    }

    /// Captures the immutable profile snapshot for one feed and attempt.
    public func adPlacementProfileSnapshot(for feedID: ItemID) throws -> PodcastAdProfileSnapshot? {
        guard try podcastFeed(for: feedID) != nil, let subscription = try subscription(for: feedID) else { return nil }
        let epoch = subscription.subscribedAt.date.timeIntervalSince1970
        guard epoch.isFinite else { return nil }
        var result: PodcastAdProfileEnvelope?
        try mutateAdProfileStore { document in
            var record = Self.profileRecord(feedID.rawValue, epoch: epoch, in: document)
            Self.validateRecord(&record)
            result = Self.effectiveProfile(record, feedID: feedID.rawValue)
            Self.put(record, in: &document)
        }
        return PodcastAdProfileSnapshot(subscriptionEpoch: epoch, envelope: result)
    }

    /// Adds independent pre-recovery observations only to the subscription generation that ran them.
    /// A duplicate source hash or episode replay never increases the profile sample count.
    @discardableResult
    public func recordAdPlacementObservation(
        _ observation: PodcastAdProfileObservation, expectedSubscriptionEpoch: Double
    ) throws -> Bool {
        guard expectedSubscriptionEpoch.isFinite,
              let active = try subscription(for: try ItemID(rawValue: observation.feedID)),
              active.subscribedAt.date.timeIntervalSince1970 == expectedSubscriptionEpoch else { return false }
        guard observation.isValid(feedID: observation.feedID, episodeID: observation.episodeID,
                                  sourceHash: observation.sourceHash) else { return false }
        let episodeID = observation.episodeID
        var changed = false
        try mutateAdProfileStore { document in
            var record = Self.profileRecord(observation.feedID, epoch: expectedSubscriptionEpoch, in: document)
            Self.validateRecord(&record)
            if record.observations.contains(where: { $0.sourceHash == observation.sourceHash }) { return }
            // A changed source for one episode replaces its older source observation.
            record.observations.removeAll { $0.episodeID == episodeID }
            record.observations.append(observation)
            if record.observations.count > adProfileMaximumObservations {
                record.observations.removeFirst(record.observations.count - adProfileMaximumObservations)
            }
            record.profile = Self.learnedProfile(record)
            Self.put(record, in: &document)
            changed = true
        }
        return changed
    }

    /// Installs a validated curated hint for an active exact feed ID.
    /// The import keeps the original payload bytes and existing independent observations.
    public func upsertImportedAdPlacementProfile(
        _ envelope: PodcastAdProfileEnvelope, feedID: ItemID
    ) throws {
        guard try podcastFeed(for: feedID) != nil,
              let subscription = try subscription(for: feedID) else { throw PodcastAdProfileError.inactiveSubscription }
        guard envelope.validatedPayload(expectedFeedID: feedID.rawValue) != nil else {
            throw PodcastAdProfileError.invalidEnvelope
        }
        let epoch = subscription.subscribedAt.date.timeIntervalSince1970
        try mutateAdProfileStore { document in
            var record = Self.profileRecord(feedID.rawValue, epoch: epoch, in: document)
            Self.validateRecord(&record)
            record.importedProfile = envelope
            Self.put(record, in: &document)
        }
    }

    /// Deletes private evidence after the database has durably removed its subscription.
    func removeAdPlacementProfile(feedID: ItemID) throws {
        defer { reconciledAdProfileSubscriptionEpochs = nil }
        try mutateAdProfileStore { document in
            document.feeds.removeAll { $0.feedID == feedID.rawValue }
        }
    }

    private static func profileRecord(_ feedID: String, epoch: Double,
                                      in document: AdProfileStoreDocument) -> AdProfileFeedRecord {
        guard let record = document.feeds.first(where: { $0.feedID == feedID }),
              record.subscriptionEpoch == epoch else {
            return AdProfileFeedRecord(feedID: feedID, subscriptionEpoch: epoch)
        }
        return record
    }

    private static func put(_ record: AdProfileFeedRecord, in document: inout AdProfileStoreDocument) {
        document.feeds.removeAll { $0.feedID == record.feedID }
        document.feeds.append(record)
        document.feeds.sort { $0.feedID < $1.feedID }
    }

    private static func validateRecord(_ record: inout AdProfileFeedRecord) {
        guard record.feedID.utf8.count <= 128, (try? ItemID(rawValue: record.feedID)) != nil else {
            record = AdProfileFeedRecord(feedID: "invalid-profile-feed", subscriptionEpoch: record.subscriptionEpoch)
            return
        }
        if let profile = record.profile, profile.validatedPayload(expectedFeedID: record.feedID) == nil { record.profile = nil }
        if let imported = record.importedProfile, imported.validatedPayload(expectedFeedID: record.feedID) == nil {
            record.importedProfile = nil
        }
        record.observations = record.observations.filter {
            $0.isValid(feedID: record.feedID, episodeID: $0.episodeID, sourceHash: $0.sourceHash)
        }
        var seenSources = Set<String>()
        var seenEpisodes = Set<String>()
        record.observations = Array(record.observations.filter {
            seenSources.insert($0.sourceHash).inserted && seenEpisodes.insert($0.episodeID).inserted
        }.suffix(adProfileMaximumObservations))
    }

    private static func effectiveProfile(_ record: AdProfileFeedRecord, feedID: String) -> PodcastAdProfileEnvelope? {
        let importedEnvelope = record.importedProfile
        let imported = importedEnvelope?.validatedPayload(expectedFeedID: feedID)
        let learnedEnvelope = record.profile
        let learned = learnedEnvelope?.validatedPayload(expectedFeedID: feedID)
        guard let learned else { return importedEnvelope }
        guard let imported else { return learnedEnvelope }
        var seen = Set<PodcastAdProfileSlot>()
        let slots = Array((imported.slots + learned.slots).filter { seen.insert($0).inserted }
            .prefix(PodcastAdProfileValidation.maximumSlots))
        guard slots != imported.slots else { return importedEnvelope }
        let (revision, overflow) = imported.revision.addingReportingOverflow(learned.revision)
        guard !overflow else { return importedEnvelope }
        let sampleCount = min(20, max(imported.sampleCount, learned.sampleCount, record.observations.count, 1))
        return try? PodcastAdProfileEnvelope.make(feedID: feedID, revision: revision,
                                                  sampleCount: sampleCount, slots: slots)
    }

    private static func learnedProfile(_ record: AdProfileFeedRecord) -> PodcastAdProfileEnvelope? {
        var seen = Set<PodcastAdProfileSlot>()
        let slots = Array(record.observations.flatMap(\.slots).filter { seen.insert($0).inserted }
            .prefix(PodcastAdProfileValidation.maximumSlots))
        guard !slots.isEmpty else { return nil }
        let old = record.profile?.validatedPayload(expectedFeedID: record.feedID)
        let (revision, overflow) = (old?.revision ?? 0).addingReportingOverflow(1)
        guard !overflow else { return record.profile }
        let sampleCount = min(20, max(record.observations.count, 1))
        return try? PodcastAdProfileEnvelope.make(feedID: record.feedID,
            revision: revision, sampleCount: sampleCount, slots: slots)
    }

    private static func validStoreObject(_ object: [String: Any]) -> Bool {
        guard Set(object.keys) == Set(["schemaVersion", "feeds"]),
              PodcastAdProfileValidation.jsonInteger(object["schemaVersion"]) == adProfileStoreVersion,
              let feeds = object["feeds"] as? [[String: Any]], feeds.count <= adProfileStoreMaximumFeeds else { return false }
        let required = Set(["feedID", "subscriptionEpoch", "profile", "importedProfile", "observations"])
        return feeds.allSatisfy { record in
            guard Set(record.keys) == required, let feedID = record["feedID"] as? String,
                  (1...256).contains(feedID.unicodeScalars.count),
                  let epoch = record["subscriptionEpoch"] as? NSNumber,
                  CFGetTypeID(epoch) != CFBooleanGetTypeID(), epoch.doubleValue.isFinite,
                  record["profile"] is NSNull || validEnvelopeObject(record["profile"]),
                  record["importedProfile"] is NSNull || validEnvelopeObject(record["importedProfile"]),
                  let observations = record["observations"] as? [[String: Any]],
                  observations.count <= adProfileMaximumObservations,
                  observations.allSatisfy(validObservationObject) else { return false }
            return true
        }
    }

    private static func validObservationObject(_ observation: [String: Any]) -> Bool {
        guard Set(observation.keys) == Set(["schemaVersion", "feedID", "episodeID", "sourceHash", "slots"]),
              PodcastAdProfileValidation.jsonInteger(observation["schemaVersion"]) == 1,
              let feedID = observation["feedID"] as? String, (1...256).contains(feedID.unicodeScalars.count),
              let episodeID = observation["episodeID"] as? String, (1...256).contains(episodeID.unicodeScalars.count),
              let sourceHash = observation["sourceHash"] as? String,
              sourceHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let slots = observation["slots"] as? [[String: Any]],
              slots.count <= PodcastAdProfileValidation.maximumSlots else { return false }
        return slots.allSatisfy(PodcastAdProfileValidation.validSlotObject)
    }

    private static func validEnvelopeObject(_ value: Any?) -> Bool {
        guard let envelope = value as? [String: Any], Set(envelope.keys) == Set(["payload", "digest"]),
              envelope["payload"] is String, let digest = envelope["digest"] as? String,
              digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { return false }
        return true
    }

    private func mutateAdProfileStore(_ update: (inout AdProfileStoreDocument) throws -> Void) throws {
        let fileURL = url.deletingLastPathComponent().appendingPathComponent("ad-placement-profiles.json")
        let lockURL = fileURL.appendingPathExtension("lock")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw PodcastAdProfileError.storeUnavailable }
        _ = Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR))
        defer { Darwin.close(descriptor) }
        var acquired = false
        for _ in 0..<adProfileLockAttempts {
            if adProfilePOSIXFlock(descriptor, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            if errno != EWOULDBLOCK && errno != EAGAIN && errno != EINTR { break }
            Darwin.usleep(adProfileLockPauseMicroseconds)
        }
        guard acquired else { throw PodcastAdProfileError.storeUnavailable }
        defer { _ = adProfilePOSIXFlock(descriptor, LOCK_UN) }

        var document: AdProfileStoreDocument
        if fileManager.fileExists(atPath: fileURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= adProfileStoreMaximumBytes else {
                throw PodcastAdProfileError.storeTooLarge
            }
            let readDescriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW)
            guard readDescriptor >= 0 else { throw PodcastAdProfileError.storeUnavailable }
            defer { Darwin.close(readDescriptor) }
            var statBuffer = stat()
            guard Darwin.fstat(readDescriptor, &statBuffer) == 0,
                  (statBuffer.st_mode & S_IFMT) == S_IFREG,
                  statBuffer.st_size >= 0, statBuffer.st_size <= adProfileStoreMaximumBytes else { throw PodcastAdProfileError.storeTooLarge }
            var data = Data(count: Int(statBuffer.st_size))
            let readCount = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.read(readDescriptor, base.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return -1 }
                    offset += count
                }
                return offset
            }
            guard readCount == data.count,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.validStoreObject(object),
                  let decoded = try? JSONDecoder().decode(AdProfileStoreDocument.self, from: data),
                  decoded.schemaVersion == adProfileStoreVersion,
                  decoded.feeds.count <= adProfileStoreMaximumFeeds,
                  Set(decoded.feeds.map(\.feedID)).count == decoded.feeds.count else {
                throw PodcastAdProfileError.storeUnavailable
            }
            document = decoded
            data.resetBytes(in: 0..<data.count)
        } else {
            document = AdProfileStoreDocument(schemaVersion: adProfileStoreVersion, feeds: [])
        }
        let original = document
        try update(&document)
        if document == original { return }
        guard document.feeds.count <= adProfileStoreMaximumFeeds else { throw PodcastAdProfileError.feedLimitReached }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= adProfileStoreMaximumBytes else { throw PodcastAdProfileError.storeTooLarge }
        try Self.atomicPrivateWrite(data, to: fileURL)
    }

    private static func atomicPrivateWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".ad-placement-profiles-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw PodcastAdProfileError.storeUnavailable }
        var keep = false
        defer {
            Darwin.close(descriptor)
            if !keep { try? FileManager.default.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw PodcastAdProfileError.storeUnavailable }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.rename(temporary.path, url.path) == 0 else { throw PodcastAdProfileError.storeUnavailable }
        keep = true
        _ = Darwin.chmod(url.path, mode_t(S_IRUSR | S_IWUSR))
        let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        if directory >= 0 { _ = Darwin.fsync(directory); Darwin.close(directory) }
    }
}
