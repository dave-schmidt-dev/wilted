import CloudKit
import Foundation
import WiltedDomain
import WiltedLibrary

// MARK: - One round's reads as one batch

extension CloudKitLibraryTransport {
    /// Everything a sync round reads from the zone, by name, in as few requests as the names allow.
    ///
    /// The first request holds every name that is known up front: the intent and outcome indexes,
    /// the offer index and each device's now-playing and progress records. A second request exists
    /// only when the first named something new (intents or outcomes not cached yet, the offers the
    /// index lists, progress for an entry a now-playing record just introduced). An idle round is
    /// therefore one request. Names that do not exist cost nothing extra, since they ride along.
    public func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
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
        var asked = Set<String>()
        func unasked(_ ids: [CKRecord.ID]) -> [CKRecord.ID] { ids.filter { asked.insert($0.recordName).inserted } }
        if options.contains(.deviceRecords) { first += playbackNames(devices: devices, nowPlaying: true) }
        first = unasked(first)

        var observed: [String: (channel: PlaybackChannel, observed: ObservedPlayback)] = [:]
        var wantedIntents: [(name: String, deviceID: String, id: String)] = []
        var wantedOutcomes: [(name: String, deviceID: String, id: String)] = []
        var offerEntries: [ItemID]?
        var sawOwnIntentIndex = false

        func absorb(_ records: [CKRecord]) {
            for record in records {
                switch try? mapper.decode(record) {
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
                    index.entryIDs.forEach { peers.note(entry: $0) }
                    offerEntries = index.entryIDs
                case let .playback(channel, value)?:
                    peers.note(device: value.deviceID, entry: value.entryID)
                    observed[record.recordID.recordName] = (channel, ObservedPlayback(
                        record: value, serverModifiedAt: record.modificationDate ?? .distantPast))
                case let .intent(value)?: intentCache[record.recordID.recordName] = value
                case let .outcome(value)?: outcomeCache[record.recordID.recordName] = value
                default: break
                }
            }
        }

        var offerRecords: [CKRecord] = []
        absorb(try await fetchPresent(first))
        if asksOwnIntentIndex, !sawOwnIntentIndex { ownIntentIndexMissing = true }

        var second: [CKRecord.ID] = []
        second += wantedIntents.filter { intentCache[$0.name] == nil }
            .compactMap { try? mapper.recordID(intentID: $0.id, deviceID: $0.deviceID) }
        second += wantedOutcomes.filter { outcomeCache[$0.name] == nil }
            .compactMap { try? mapper.recordID(outcomeIntentID: $0.id, deviceID: $0.deviceID) }
        if options.contains(.deviceRecords) { second += playbackNames(devices: devices, nowPlaying: false) }
        second = unasked(second)
        let offerIDs = (offerEntries ?? []).compactMap { try? mapper.recordID(offerFor: $0) }
        if !second.isEmpty || !offerIDs.isEmpty {
            let found = try await fetchPresent(second + offerIDs)
            let offerNames = Set(offerIDs.map(\.recordName))
            offerRecords = found.filter { offerNames.contains($0.recordID.recordName) }
            absorb(found.filter { !offerNames.contains($0.recordID.recordName) })
            // The progress just fetched may name entries only a now-playing record introduced.
        }

        var result = LibraryPollResult()
        if options.contains(.intents) {
            result.intents = wantedIntents.compactMap { intentCache[$0.name] }
                .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        }
        if options.contains(.outcomes) {
            result.outcomes = wantedOutcomes.compactMap { outcomeCache[$0.name] }
                .sorted { ($0.decidedAt, $0.intentID) < ($1.decidedAt, $1.intentID) }
        }
        if options.contains(.offers) {
            result.offers = offerRecords.compactMap { record -> LibraryMediaOffer? in
                guard case let .offer(offer)? = try? mapper.decode(record) else { return nil }
                return offer
            }.sorted { $0.entryID.rawValue < $1.entryID.rawValue }
        }
        if options.contains(.deviceRecords) {
            func ordered(_ channel: PlaybackChannel) -> [ObservedPlayback] {
                observed.values.filter { $0.channel == channel }.map(\.observed)
                    .sorted { ($0.record.deviceID, $0.record.entryID.rawValue) < ($1.record.deviceID, $1.record.entryID.rawValue) }
            }
            result.records = LibraryDeviceRecords(nowPlaying: ordered(.nowPlaying), progress: ordered(.progress))
        }
        return result
    }

    /// Each known device's playback names: its now-playing record, and its progress record for every
    /// known entry.
    private func playbackNames(devices: [String], nowPlaying: Bool) -> [CKRecord.ID] {
        let entries = peers.entries.sorted { $0.rawValue < $1.rawValue }
        var ids: [CKRecord.ID] = []
        for device in devices {
            if nowPlaying, let id = try? mapper.recordID(nowPlayingFor: device) { ids.append(id) }
            ids += entries.compactMap { try? mapper.recordID(progressFor: device, entryID: $0) }
        }
        return ids
    }
}
