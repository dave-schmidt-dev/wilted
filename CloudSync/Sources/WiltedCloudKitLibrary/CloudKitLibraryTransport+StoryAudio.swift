import CloudKit
import Foundation
import WiltedLibrary

extension CloudKitLibraryTransport: LibraryStoryAudioTransport {
    public func publishStoryAudio(offer: LibraryStoryAudioOffer, fileURL: URL, expectedOwner: String) async throws {
        guard isLibraryWriter else { throw LibraryTransportError.ownershipViolation("Only the Mac can publish a reading.") }
        try LibraryStoryAudioRecord.verifySizeLimit(offer)
        let generation = try await storyContext(expectedOwner)
        try await verifyStoryRequest(offer, generation: generation, owner: expectedOwner)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await Task.detached {
            try FileManager.default.copyItem(at: fileURL, to: scratch)
            try LibraryStoryAudioRecord.verifyFile(scratch, expected: offer)
        }.value
        try verifyFetchContext(generation: generation, owner: expectedOwner)
        let target = driver
        let zone = mapper.mediaZoneID
        let record = try LibraryStoryAudioRecord.record(for: offer, audio: scratch, in: zone)
        try await target.ensureZone(zone)
        try verifyFetchContext(generation: generation, owner: expectedOwner)
        try await withMediaWatchdog { touch in
            try await target.saveRecordRaw(record) { _ in touch() }
        }
        try verifyFetchContext(generation: generation, owner: expectedOwner)
    }

    public func fetchStoryAudio(_ expected: LibraryStoryAudioOffer, expectedOwner: String,
                                progress: @escaping MediaProgressHandler) async throws -> URL {
        guard expected.requesterDeviceID == deviceID else {
            throw LibraryTransportError.ownershipViolation("This reading belongs to a different device.")
        }
        try LibraryStoryAudioRecord.verifySizeLimit(expected)
        let generation = try await storyContext(expectedOwner)
        try await verifyStoryRequest(expected, generation: generation, owner: expectedOwner)
        let id = try LibraryStoryAudioRecord.id(for: expected, in: mapper.mediaZoneID)
        let target = driver
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try await withMediaWatchdog { touch in
                let record = try await target.fetchAssetRecordRaw(
                    id, assetField: LibraryMediaRecord.assetField, to: destination
                ) { fraction in
                    touch()
                    if fraction.isFinite { progress(Int64(min(max(fraction, 0), 1) * Double(expected.byteCount))) }
                }
                try LibraryStoryAudioRecord.verify(record, expected: expected, id: id)
                try LibraryStoryAudioRecord.verifyFile(destination, expected: expected)
            }
            try verifyFetchContext(generation: generation, owner: expectedOwner)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw failure(error)
        }
    }

    public func removeStoryAudio(_ offer: LibraryStoryAudioOffer, expectedOwner: String) async throws {
        guard isLibraryWriter else { throw LibraryTransportError.ownershipViolation("Only the Mac can remove a reading.") }
        let generation = try await storyContext(expectedOwner)
        let id = try LibraryStoryAudioRecord.id(for: offer, in: mapper.mediaZoneID)
        try await driver.deleteRecordsRaw([id])
        try verifyFetchContext(generation: generation, owner: expectedOwner)
    }

    func storyContext(_ expectedOwner: String) async throws -> UInt64 {
        let generation = operationGenerationValue
        guard !expectedOwner.isEmpty else { throw LibraryTransportError.superseded }
        try await observeCurrentOwner(generation: generation)
        try verifyFetchContext(generation: generation, owner: expectedOwner)
        return generation
    }

    private func verifyStoryRequest(_ offer: LibraryStoryAudioOffer, generation: UInt64, owner: String) async throws {
        let id = try mapper.recordID(intentID: offer.requestID, deviceID: offer.requesterDeviceID)
        let records = try await driver.fetchRecordsIfPresent([id], desiredKeys: nil)
        try verifyFetchContext(generation: generation, owner: owner)
        guard let record = records.first, record.recordID == id,
              case let .intent(intent) = try mapper.decode(record),
              intent.id == offer.requestID, intent.deviceID == offer.requesterDeviceID,
              offer.matchesRequest(intent) else {
            throw LibraryTransportError.ownershipViolation("The device did not request this reading.")
        }
    }
}

private extension LibraryStoryAudioOffer {
    func matchesRequest(_ intent: LibraryIntent) -> Bool {
        switch intent.action {
        case let .listenNext(story, _): return story.id == storyID
        case let .requestBulletinAudio(bulletinID): return bulletinID == storyID
        default: return false
        }
    }
}
