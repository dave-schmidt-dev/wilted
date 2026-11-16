import CloudKit
import Foundation
import WiltedDomain
import WiltedLibrary

// MARK: - One round's reads as one batch

extension CloudKitLibraryTransport {
    /// Decodes a fetched record. An intent record whose action this build cannot decode (a newer
    /// phone sent it) becomes a decode-side placeholder carrying its id, device and time, so the
    /// Mac can answer `unsupportedAction`; every other failure still throws. Shared by poll,
    /// fetch and `listIntents`.
    func decodeTolerant(_ record: CKRecord) throws -> LibraryDecodedRecord {
        do { return try mapper.decode(record) } catch {
            guard record.recordType == LibraryRecordType.intent.rawValue,
                  record.recordID.zoneID == mapper.zoneID,
                  let data = record[LibraryRecordMapper.payloadField] as? Data,
                  let head = try? LibraryRecordMapper.decoder.decode(IntentHead.self, from: data),
                  let placeholder = try? LibraryIntent.unsupported(id: head.id, deviceID: head.deviceID, createdAt: head.createdAt),
                  (try? mapper.recordID(intent: placeholder)) == record.recordID else { throw error }
            return .intent(placeholder)
        }
    }

    private struct IntentHead: Decodable {
        let id: String
        let deviceID: String
        let createdAt: Date
    }

    /// Everything a sync round reads from the zone, by name, in as few requests as the names allow.
    ///
    /// The first request holds every name that is known up front: the intent and outcome indexes,
    /// the offer index, the device directory and this device's link, each device's now-playing
    /// record, and the progress records `LibraryProgressSchedule` picks to fill the request to 100
    /// names. A second request exists only when the first named something new (intents or
    /// outcomes not cached yet, the offers the index lists, progress for a pair never read or one
    /// a now-playing record in this read made hot, the intent index of a device the directory just
    /// introduced). A third exists only on the round a new device's index first names intents, so
    /// its waiting request is read in that same round. An idle round is therefore one request.
    /// Progress names are limited to observed pairs and explicit cold-start seeds, and the result
    /// lists every known pair: the ones read now plus cached copies of the rest.
    public func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
        try await CloudKitOperationContext.$caller.withValue(.poll) {
        peers.pruneStale(now: clock())
        let devices = peers.devices.union([deviceID]).sorted()
        var first: [CKRecord.ID] = []
        let asksOwnIntentIndex = options.contains(.intents) && !ownIntentIndexMissing
        if options.contains(.intents) {
            // A device that has never sent an intent has no index of its own; asking again for it each
            // round would be a request for nothing until the first `send` creates it.
            let askedDevices = devices.filter { $0 != deviceID || !ownIntentIndexMissing }
            first += askedDevices.compactMap { try? mapper.recordID(intentIndexFor: $0) }
        }
        if options.contains(.outcomes) { first += devices.compactMap { try? mapper.recordID(outcomeIndexFor: $0) } }
        if options.contains(.offers) { first.append(mapper.offerIndexRecordID) }
        if options.contains(.deviceDirectory) { first.append(mapper.deviceDirectoryRecordID) }
        if options.contains(.deviceLink), let id = try? mapper.recordID(deviceLinkFor: deviceID) { first.append(id) }
        var asked = Set<String>()
        func unasked(_ ids: [CKRecord.ID]) -> [CKRecord.ID] { ids.filter { asked.insert($0.recordName).inserted } }
        let readsRecords = options.contains(.deviceRecords)
        var progressAsked: [String: ProgressAsk] = [:]
        func askProgress(_ pairs: [LibraryPlaybackPair]) -> [CKRecord.ID] { progressIDs(pairs, ledger: &progressAsked) }
        if readsRecords {
            progressReads.round += 1
            first += devices.compactMap { try? mapper.recordID(nowPlayingFor: $0) }
        }
        first = unasked(first)
        if readsRecords {
            let known = knownProgressPairs(devices: devices)
            first += unasked(askProgress(LibraryProgressSchedule.pairs(
                known: known, ownDeviceID: deviceID, hotEntryIDs: progressReads.hotEntries,
                neverRead: known.filter { !hasRead($0) }, lastReadRound: progressReads.lastReadRound,
                slotCount: 100 - first.count)))
        }

        var observed: [String: (channel: PlaybackChannel, observed: ObservedPlayback)] = [:]
        var wantedIntents: [(name: String, deviceID: String, id: String)] = []
        var wantedOutcomes: [(name: String, deviceID: String, id: String)] = []
        var offerEntries: [ItemID]?
        var observedNewOfferGeneration: UInt64?
        let seenOfferGeneration = options.contains(.forceOffers) ? nil : lastObservedOfferGeneration
        var sawOwnIntentIndex = false
        var directory: LibraryDeviceDirectory?
        var link: LibraryDeviceLink?
        var introduced: [String] = []
        var fetched = Set<String>()

        func absorb(_ records: [CKRecord]) {
            for record in records {
                fetched.insert(record.recordID.recordName)
                switch try? decodeTolerant(record) {
                case let .intentIndex(index)?:
                    peers.note(device: index.deviceID)
                    if index.deviceID == deviceID { sawOwnIntentIndex = true }
                    for id in index.intentIDs {
                        guard let name = try? mapper.recordID(intentID: id, deviceID: index.deviceID).recordName else { continue }
                        wantedIntents.append((name, index.deviceID, id))
                    }
                case let .outcomeIndex(index)?:
                    peers.note(device: index.deviceID)
                    for id in index.intentIDs {
                        guard let name = try? mapper.recordID(outcomeIntentID: id, deviceID: index.deviceID).recordName else { continue }
                        wantedOutcomes.append((name, index.deviceID, id))
                    }
                case let .offerIndex(index)?:
                    // The offer records are fetched only when the index generation moved since the last read.
                    if seenOfferGeneration != index.generation {
                        offerEntries = index.entryIDs
                        observedNewOfferGeneration = index.generation
                    }
                case let .playback(channel, value)?:
                    peers.note(device: value.deviceID, entry: value.entryID)
                    observed[record.recordID.recordName] = (channel, ObservedPlayback(
                        record: value, serverModifiedAt: record.modificationDate ?? .distantPast))
                case let .intent(value)?: intentCache[record.recordID.recordName] = value
                case let .outcome(value)?: outcomeCache[record.recordID.recordName] = value
                case let .deviceDirectory(value)?:
                    directory = value
                    consecutiveDirectoryFailures = 0
                    directoryRecordPresent = true
                    let now = clock()
                    for device in value.devices {
                        if now.timeIntervalSince(device.announcedAt) <= LibraryDeviceDirectory.announcementLifetime {
                            if !peers.devices.contains(device.deviceID) && device.deviceID != deviceID {
                                introduced.append(device.deviceID)
                            }
                            peers.note(device: device.deviceID, announcedAt: device.announcedAt)
                        } else {
                            peers.remove(device: device.deviceID)
                        }
                    }
                case let .deviceLink(value)? where value.deviceID == deviceID: link = value
                default: break
                }
            }
        }

        var offerRecords: [CKRecord] = []
        do {
            absorb(try await fetchPresent(first))
        } catch {
            if options.contains(.deviceDirectory) { consecutiveDirectoryFailures += 1 }
            throw error
        }
        if asksOwnIntentIndex, !sawOwnIntentIndex { ownIntentIndexMissing = true }

        var second: [CKRecord.ID] = []
        if options.contains(.intents) { second += introduced.compactMap { try? mapper.recordID(intentIndexFor: $0) } }
        second += wantedIntents.filter { intentCache[$0.name] == nil }
            .compactMap { try? mapper.recordID(intentID: $0.id, deviceID: $0.deviceID) }
        second += wantedOutcomes.filter { outcomeCache[$0.name] == nil }
            .compactMap { try? mapper.recordID(outcomeIntentID: $0.id, deviceID: $0.deviceID) }
        if readsRecords {
            let currentDevices = peers.devices.union([deviceID]).sorted()
            second += askProgress(followUpPairs(devices: currentDevices, observed: observed))
            second += introduced.compactMap { try? mapper.recordID(nowPlayingFor: $0) }
        }
        second = unasked(second)
        let offerIDs = (offerEntries ?? []).compactMap { try? mapper.recordID(offerFor: $0) }
        if !second.isEmpty || !offerIDs.isEmpty {
            let found = try await fetchPresent(second + offerIDs)
            let offerNames = Set(offerIDs.map(\.recordName))
            offerRecords = found.filter { offerNames.contains($0.recordID.recordName) }
            absorb(found.filter { !offerNames.contains($0.recordID.recordName) })
            // The progress just fetched may name entries only a now-playing record introduced.
        }
        // A newly introduced device can name both intents and active progress in the second read.
        if !introduced.isEmpty {
            var pending = wantedIntents.filter { intentCache[$0.name] == nil }
                .compactMap { try? mapper.recordID(intentID: $0.id, deviceID: $0.deviceID) }
            if readsRecords {
                pending += askProgress(followUpPairs(devices: peers.devices.union([deviceID]).sorted(), observed: observed))
            }
            let third = unasked(pending)
            if !third.isEmpty { absorb(try await fetchPresent(third)) }
        }

        var result = LibraryPollResult()
        result.directory = directory
        if options.contains(.deviceLink) {
            result.deviceLinkRead = true
            result.deviceLink = link
        }
        if options.contains(.intents) {
            result.intents = wantedIntents.compactMap { intentCache[$0.name] }
                .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        }
        if options.contains(.outcomes) {
            result.outcomes = wantedOutcomes.compactMap { outcomeCache[$0.name] }
                .sorted { ($0.decidedAt, $0.intentID) < ($1.decidedAt, $1.intentID) }
        }
        if options.contains(.offers) {
            if let newGen = observedNewOfferGeneration {
                lastObservedOfferGeneration = newGen
                cachedOffers = offerRecords.compactMap { record -> LibraryMediaOffer? in
                    guard case let .offer(offer)? = try? mapper.decode(record) else { return nil }
                    return offer
                }.sorted { $0.entryID.rawValue < $1.entryID.rawValue }
            }
            result.offers = cachedOffers
        }
        if readsRecords {
            bookProgressReads(progressAsked, found: fetched)
            let known = knownProgressPairs(devices: peers.devices.union([deviceID]).sorted())
            // The cache, not this read, is the answer for every known pair: it holds what was just
            // fetched, or an own save that landed while the read was in flight.
            for (name, cached) in cachedProgress(of: known, skipping: []) { observed[name] = (.progress, cached) }
            func ordered(_ channel: PlaybackChannel) -> [ObservedPlayback] {
                observed.values.filter { $0.channel == channel }.map(\.observed)
                    .sorted { ($0.record.deviceID, $0.record.entryID.rawValue) < ($1.record.deviceID, $1.record.entryID.rawValue) }
            }
            let records = LibraryDeviceRecords(nowPlaying: ordered(.nowPlaying), progress: ordered(.progress))
            progressReads.hotEntries = Set(records.nowPlaying.map(\.record.entryID))
            result.records = records
        }
        return result
        }
    }
}

// MARK: - Progress selection and cached results

extension CloudKitLibraryTransport {
    /// A progress name asked in one read, with the cached record it had when asked.
    typealias ProgressAsk = (pair: LibraryPlaybackPair, cached: CKRecord?)

    /// Empties the record cache and the progress read history with it, so the next poll reads
    /// every known pair once.
    func clearRecordCache() {
        serverRecords = [:]
        progressReads = LibraryProgressReads()
    }

    /// Every observed pair, plus each seed entry paired with each of `devices`.
    func knownProgressPairs(devices: [String]) -> Set<LibraryPlaybackPair> {
        var pairs = peers.observedPairs
        for device in devices {
            for entry in peers.seedEntries { pairs.insert(LibraryPlaybackPair(deviceID: device, entryID: entry)) }
        }
        return pairs
    }

    func progressName(_ pair: LibraryPlaybackPair) -> String? {
        try? mapper.recordID(progressFor: pair.deviceID, entryID: pair.entryID).recordName
    }

    /// A pair is read while it has a cached record or was read and found missing since the last clear.
    func hasRead(_ pair: LibraryPlaybackPair) -> Bool {
        guard let name = progressName(pair) else { return true }
        return serverRecords[name] != nil || progressReads.foundMissing.contains(name)
    }

    /// The record IDs for `pairs`, noting each in `ledger` so the read can be booked when it ends.
    func progressIDs(_ pairs: [LibraryPlaybackPair], ledger: inout [String: ProgressAsk]) -> [CKRecord.ID] {
        pairs.compactMap { pair in
            guard let id = try? mapper.recordID(progressFor: pair.deviceID, entryID: pair.entryID) else { return nil }
            if ledger[id.recordName] == nil { ledger[id.recordName] = (pair, serverRecords[id.recordName]) }
            return id
        }
    }

    /// Notes every known pair whose progress name is among `ids`.
    func noteProgressAsks(_ ids: [CKRecord.ID], devices: [String], ledger: inout [String: ProgressAsk]) {
        let names = Set(ids.map(\.recordName))
        _ = progressIDs(knownProgressPairs(devices: devices).filter { progressName($0).map(names.contains) == true },
                        ledger: &ledger)
    }

    /// Pairs a later request of the same round reads: pairs never read (a new device's seeds, an
    /// entry a now-playing record just introduced) and pairs a now-playing record in this read
    /// made hot. The caller drops the ones already asked.
    func followUpPairs(devices: [String],
                       observed: [String: (channel: PlaybackChannel, observed: ObservedPlayback)]) -> [LibraryPlaybackPair] {
        let hot = Set(observed.values.filter { $0.channel == .nowPlaying }.map(\.observed.record.entryID))
        return knownProgressPairs(devices: devices)
            .filter { !hasRead($0) || ($0.deviceID != deviceID && hot.contains($0.entryID)) }
            .sorted { ($0.deviceID, $0.entryID.rawValue) < ($1.deviceID, $1.entryID.rawValue) }
    }

    /// Books a finished read. A found record is already cached by `fetchPresent`. A name asked and
    /// not found leaves the cache and is marked missing, unless an own save cached it meanwhile.
    func bookProgressReads(_ ledger: [String: ProgressAsk], found: Set<String>) {
        for (name, ask) in ledger {
            progressReads.lastReadRound[ask.pair] = progressReads.round
            if found.contains(name) {
                progressReads.foundMissing.remove(name)
            } else if serverRecords[name] === ask.cached {
                serverRecords[name] = nil
                progressReads.foundMissing.insert(name)
            }
        }
    }

    /// Cached progress records of `known` pairs not asked in this read, keyed by record name.
    func cachedProgress(of known: Set<LibraryPlaybackPair>, skipping asked: Set<String>) -> [String: ObservedPlayback] {
        var cached: [String: ObservedPlayback] = [:]
        for pair in known {
            guard let name = progressName(pair), !asked.contains(name), let record = serverRecords[name],
                  case let .playback(.progress, value)? = try? mapper.decode(record) else { continue }
            cached[name] = ObservedPlayback(record: value, serverModifiedAt: record.modificationDate ?? .distantPast)
        }
        return cached
    }
}
