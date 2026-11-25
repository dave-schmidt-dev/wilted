import CryptoKit
import Foundation
import OSLog
import WiltedLibrary

private let bulletinAudioLog = Logger(subsystem: "com.zerodelta.wilted", category: "BulletinAudio")
private enum LibraryApprovedBulletinVoiceID: String, CaseIterable {
    case caseyKasem = "casey-kasem"
    case wolfmanJack = "wolfman-jack"
    case paulHarvey = "paul-harvey"
    case rodSerling = "rod-serling"
}

private struct LibraryBulletinAudioEntry: Codable, Equatable, Identifiable {
    let ownerToken: String
    let bulletinID: String
    let requestID: String
    let issuedAt: Date
    let expiresAt: Date
    let textHash: String
    var intent: LibraryIntent
    var requestSent: Bool
    var requestAttempts: Int
    var statusAttempts: Int
    var audioCached: Bool
    var downloadAttempts: Int
    var nextRequestAt: Date?
    var nextStatusAt: Date?
    var nextDownloadAt: Date?
    var offer: LibraryStoryAudioOffer?
    var failure: LibraryListenNextStatus.Failure?

    var id: String { requestID }

    init(
        ownerToken: String, bulletinID: String, requestID: String, issuedAt: Date, expiresAt: Date,
        textHash: String, intent: LibraryIntent, requestSent: Bool, requestAttempts: Int,
        statusAttempts: Int, audioCached: Bool, downloadAttempts: Int, nextRequestAt: Date?,
        nextStatusAt: Date?, nextDownloadAt: Date?, offer: LibraryStoryAudioOffer?,
        failure: LibraryListenNextStatus.Failure?
    ) {
        self.ownerToken = ownerToken
        self.bulletinID = bulletinID
        self.requestID = requestID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.textHash = textHash
        self.intent = intent
        self.requestSent = requestSent
        self.requestAttempts = requestAttempts
        self.statusAttempts = statusAttempts
        self.audioCached = audioCached
        self.downloadAttempts = downloadAttempts
        self.nextRequestAt = nextRequestAt
        self.nextStatusAt = nextStatusAt
        self.nextDownloadAt = nextDownloadAt
        self.offer = offer
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case ownerToken, bulletinID, requestID, issuedAt, expiresAt, textHash, intent
        case requestSent, requestAttempts, statusAttempts, audioCached, downloadAttempts
        case nextRequestAt, nextStatusAt, nextDownloadAt, offer, failure
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ownerToken = try values.decode(String.self, forKey: .ownerToken)
        bulletinID = try values.decode(String.self, forKey: .bulletinID)
        requestID = try values.decode(String.self, forKey: .requestID)
        issuedAt = try values.decode(Date.self, forKey: .issuedAt)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        textHash = try values.decode(String.self, forKey: .textHash)
        intent = try values.decode(LibraryIntent.self, forKey: .intent)
        requestSent = try values.decode(Bool.self, forKey: .requestSent)
        requestAttempts = try values.decode(Int.self, forKey: .requestAttempts)
        statusAttempts = try values.decode(Int.self, forKey: .statusAttempts)
        offer = try values.decodeIfPresent(LibraryStoryAudioOffer.self, forKey: .offer)
        failure = try values.decodeIfPresent(LibraryListenNextStatus.Failure.self, forKey: .failure)
        audioCached = try values.decodeIfPresent(Bool.self, forKey: .audioCached) ?? (offer != nil)
        downloadAttempts = try values.decodeIfPresent(Int.self, forKey: .downloadAttempts) ?? 0
        nextRequestAt = try values.decodeIfPresent(Date.self, forKey: .nextRequestAt)
        nextStatusAt = try values.decodeIfPresent(Date.self, forKey: .nextStatusAt)
        nextDownloadAt = try values.decodeIfPresent(Date.self, forKey: .nextDownloadAt)
    }
}

private struct LibraryBulletinAudioManifest: Codable {
    let version: Int
    let ownerToken: String
    var entries: [LibraryBulletinAudioEntry]
}

private struct VerifiedBulletinAudio: Sendable {
    let ownerToken: String
    let offer: LibraryStoryAudioOffer
    let url: URL
    let byteCount: Int64
    let modifiedAt: Date?
}

/// Keeps only Mac-rendered bulletin clips for the current local library owner.
@MainActor
final class LibraryBulletinAudioManager {
    private static let version = 2
    private static let maxEntries = 100
    private static let retryDelays: [TimeInterval] = [10, 60, 300]
    private static let statusPollDelays: [TimeInterval] = [10, 30, 120, 300]
    private static let downloadRetryDelays: [TimeInterval] = [10, 60, 300]

    private weak var model: LibraryAppModel?
    private let manifestURL: URL?
    private let cache: LibraryListenNextAudioCache
    private let now: @Sendable () -> Date
    private var loadedOwner: String?
    private var entries: [String: LibraryBulletinAudioEntry] = [:]
    private var pendingBulletins: [String: Bulletin] = [:]
    private var verifiedAudio: [String: VerifiedBulletinAudio] = [:]
    private var inFlight = false
    private var isWritable = true

    init(model: LibraryAppModel, now: (@Sendable () -> Date)? = nil) {
        self.model = model
        let outboxURL = model.listenNextState.outbox.url
        manifestURL = outboxURL?.deletingLastPathComponent().appendingPathComponent("bulletin-audio-cache.json")
        cache = model.listenNextState.audioCache
        self.now = now ?? model.now
    }

    func prepare(_ bulletin: Bulletin) {
        guard bulletin.kind == .headline || bulletin.kind == .alert,
              bulletin.expiresAt > now(), let requestID = Self.requestID(for: bulletin, deviceID: model?.deviceID ?? "") else {
            return
        }
        pendingBulletins[requestID] = bulletin
    }

    var canRequestAudio: Bool {
        guard let model, model.storyAudioTransport != nil,
              let owner = localOwner, load(owner: owner),
              model.macAddActions?.contains("requestBulletinAudio") == true else { return false }
        return true
    }

    func failure(for bulletin: Bulletin) -> LibraryListenNextStatus.Failure? {
        guard let model, let owner = localOwner, load(owner: owner),
              let requestID = Self.requestID(for: bulletin, deviceID: model.deviceID),
              let entry = entries[requestID], entry.ownerToken == owner else { return nil }
        return entry.failure
    }

    /// Checks a bounded status batch and retries ready-clip downloads at a sparse cadence.
    func refreshPreparedAudio() async {
        guard !inFlight, let model, let owner = localOwner, load(owner: owner) else { return }
        inFlight = true
        defer { inFlight = false }
        removeExpiredEntries()
        let requestedIDs = Set(pendingBulletins.values.compactMap {
            Self.requestID(for: $0, deviceID: model.deviceID)
        })
        await verifyCachedAudio(owner: owner, requestIDs: requestedIDs)
        guard localOwner == owner, !model.accountQuarantined else { return }
        guard let storyAudioTransport = model.storyAudioTransport,
              let context = await model.liveListenNextContext(), context.ownerToken == owner else { return }
        guard model.macAddActions?.contains("requestBulletinAudio") == true else { return }
        admitPendingBulletins(owner: owner, deviceID: model.deviceID, limit: 1)
        await sendDueRequests(model: model, context: context)
        guard await model.mediaContextIsCurrent(context, live: true) else { return }
        let due = entries.values.filter {
            $0.requestSent && $0.offer == nil && $0.failure == nil && $0.expiresAt > now()
                && ($0.nextStatusAt.map { $0 <= now() } ?? true)
        }.sorted { $0.issuedAt < $1.issuedAt }.prefix(5)
        if !due.isEmpty {
            let requestIDs = Set(due.map(\.requestID))
            do {
                let statuses = try await storyAudioTransport.listenNextStatuses(
                    requestIDs: requestIDs, expectedOwner: context.ownerToken)
                guard await model.mediaContextIsCurrent(context, live: true) else { return }
                let byID = Dictionary(statuses.map { ($0.requestID, $0) }, uniquingKeysWith: { _, latest in latest })
                for id in requestIDs {
                    guard var entry = entries[id], entry.ownerToken == context.ownerToken else { continue }
                    advanceStatusPoll(&entry)
                    if let status = byID[id] {
                        guard status.requestID == entry.requestID, status.requesterDeviceID == model.deviceID,
                              status.storyID == entry.bulletinID else {
                            entry.failure = .transferFailed
                            entry.nextStatusAt = nil
                            entries[id] = entry
                            continue
                        }
                        switch status.phase {
                        case .preparing:
                            break
                        case .failed, .cancelled:
                            entry.failure = status.failure ?? .narrationFailed
                            entry.nextStatusAt = nil
                        case .ready:
                            guard let offer = status.audioOffer,
                                  offer.requestID == entry.requestID, offer.storyID == entry.bulletinID,
                                  offer.requesterDeviceID == model.deviceID,
                                  LibraryApprovedBulletinVoiceID(rawValue: offer.voiceID) != nil else {
                                entry.failure = .transferFailed
                                entry.nextStatusAt = nil
                                entries[id] = entry
                                continue
                            }
                            entry.offer = offer
                            entry.audioCached = false
                            entry.downloadAttempts = 0
                            entry.nextDownloadAt = now()
                            entry.nextStatusAt = nil
                        }
                    }
                    entries[id] = entry
                }
                try? persist()
            } catch {
                guard await model.mediaContextIsCurrent(context, live: true) else { return }
                advanceStatusBackoff(for: requestIDs)
                try? persist()
            }
        }
        await downloadDueOffers(model: model, context: context, limit: 3)
    }

    func canSpeak(_ bulletin: Bulletin) -> Bool { audioURL(for: bulletin) != nil }

    func audioURL(for bulletin: Bulletin) -> URL? {
        guard let model, let owner = localOwner, !model.accountQuarantined,
              !model.listenNextState.heldForAccountReview,
              load(owner: owner), bulletin.expiresAt > now(),
              let requestID = Self.requestID(for: bulletin, deviceID: model.deviceID),
              let entry = entries[requestID], entry.ownerToken == owner,
              entry.bulletinID == bulletin.id, entry.issuedAt == bulletin.issuedAt,
              entry.expiresAt == bulletin.expiresAt, entry.textHash == Self.textHash(bulletin.text),
              let offer = entry.offer, entry.audioCached, offer.storyID == bulletin.id,
              LibraryApprovedBulletinVoiceID(rawValue: offer.voiceID) != nil,
              let url = cache.url(for: offer, ownerToken: owner),
              let verified = verifiedAudio[requestID], verified.ownerToken == owner,
              verified.offer == offer, verified.url.standardizedFileURL == url.standardizedFileURL,
              Self.fileIdentityMatches(url, verified: verified) else { return nil }
        return url
    }

    private var localOwner: String? {
        guard let model, !model.accountQuarantined, model.headlinePhoneState.isBoundToLocalOwner else { return nil }
        return model.headlinePhoneState.ownerForActions
    }

    private func load(owner: String) -> Bool {
        guard !owner.isEmpty, let manifestURL else { return false }
        if loadedOwner == owner { return isWritable }
        guard let data = try? Data(contentsOf: manifestURL) else {
            if FileManager.default.fileExists(atPath: manifestURL.path) { isWritable = false; return false }
            loadedOwner = owner
            entries = [:]
            verifiedAudio = [:]
            isWritable = true
            return true
        }
        guard let saved = try? JSONDecoder().decode(LibraryBulletinAudioManifest.self, from: data),
              (1...Self.version).contains(saved.version), !saved.ownerToken.isEmpty,
              Set(saved.entries.map(\.requestID)).count == saved.entries.count,
              saved.entries.count <= Self.maxEntries,
              saved.entries.allSatisfy({
                  $0.ownerToken == saved.ownerToken && $0.requestAttempts >= 0
                      && $0.requestAttempts <= Self.retryDelays.count && $0.statusAttempts >= 0
                      && $0.statusAttempts <= Self.statusPollDelays.count && $0.downloadAttempts >= 0
                      && $0.downloadAttempts <= Self.downloadRetryDelays.count
                      && (!$0.audioCached || $0.offer != nil) && $0.intent.id == $0.requestID
              }) else {
            isWritable = false
            bulletinAudioLog.error("The cached bulletin audio list is unreadable; automatic speech stays off.")
            return false
        }
        if saved.ownerToken != owner {
            for entry in saved.entries { try? cache.removeAudio(for: entry.requestID, ownerToken: saved.ownerToken) }
            loadedOwner = owner
            entries = [:]
            verifiedAudio = [:]
            pendingBulletins = [:]
            try? persist()
        } else {
            loadedOwner = owner
            entries = Dictionary(uniqueKeysWithValues: saved.entries.map { ($0.requestID, $0) })
        }
        isWritable = true
        if saved.version != Self.version { try? persist() }
        return true
    }

    private func admitPendingBulletins(owner: String, deviceID: String, limit: Int) {
        let candidates = pendingBulletins.values
            .filter { $0.expiresAt > now() }
            .sorted {
                if $0.kind != $1.kind { return $0.kind == .alert }
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                if $0.issuedAt != $1.issuedAt { return $0.issuedAt < $1.issuedAt }
                return $0.id < $1.id
            }
        var admitted = 0
        for bulletin in candidates {
            guard entries.count < Self.maxEntries,
                  let requestID = Self.requestID(for: bulletin, deviceID: deviceID), entries[requestID] == nil,
                  let intent = try? LibraryIntent.requestBulletinAudio(
                    bulletinID: bulletin.id, deviceID: deviceID, createdAt: now(), id: requestID) else { continue }
            entries[requestID] = LibraryBulletinAudioEntry(
                ownerToken: owner, bulletinID: bulletin.id, requestID: requestID,
                issuedAt: bulletin.issuedAt, expiresAt: bulletin.expiresAt, textHash: Self.textHash(bulletin.text),
                intent: intent, requestSent: false, requestAttempts: 0, statusAttempts: 0,
                audioCached: false, downloadAttempts: 0, nextRequestAt: nil,
                nextStatusAt: nil, nextDownloadAt: nil, offer: nil, failure: nil)
            admitted += 1
            if admitted >= limit { break }
        }
        pendingBulletins = pendingBulletins.filter { $0.value.expiresAt > now() }
        try? persist()
    }

    private func sendDueRequests(model: LibraryAppModel, context: LibraryMediaContext) async {
        let due = entries.values.filter {
            !$0.requestSent && $0.failure == nil && $0.expiresAt > now()
                && ($0.nextRequestAt.map { $0 <= now() } ?? true)
                && $0.requestAttempts < Self.retryDelays.count
        }
        for var entry in due.prefix(1) {
            guard await model.mediaContextIsCurrent(context, live: true),
                  entry.ownerToken == context.ownerToken,
                  entry.intent.deviceID == model.deviceID else { return }
            do {
                try await model.transport.send(intent: entry.intent)
                guard await model.mediaContextIsCurrent(context, live: true) else { return }
                entry.requestSent = true
                entry.nextStatusAt = now()
            } catch {
                guard await model.mediaContextIsCurrent(context, live: true) else { return }
                entry.requestAttempts += 1
                entry.nextRequestAt = Self.retryDate(attempt: entry.requestAttempts, now: now())
                if entry.requestAttempts >= Self.retryDelays.count { entry.failure = .transferFailed }
            }
            entries[entry.requestID] = entry
            try? persist()
        }
    }

    private func download(
        _ offer: LibraryStoryAudioOffer, entryID: String,
        model: LibraryAppModel, context: LibraryMediaContext
    ) async {
        guard let storyAudioTransport = model.storyAudioTransport,
              await model.mediaContextIsCurrent(context, live: true),
              let pending = entries[entryID], pending.ownerToken == context.ownerToken,
              pending.offer == offer, !pending.audioCached, pending.failure == nil,
              pending.expiresAt > now() else { return }
        do {
            let sourceURL = try await storyAudioTransport.fetchStoryAudio(offer, expectedOwner: context.ownerToken) { _ in }
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            guard await model.mediaContextIsCurrent(context, live: true),
                  let current = entries[entryID], current.ownerToken == context.ownerToken,
                  current.requestID == offer.requestID, current.bulletinID == offer.storyID,
                  current.expiresAt > now() else { return }
            let cache = self.cache
            let cachedURL = try await Task.detached(priority: .utility) {
                try cache.store(sourceURL, for: offer, ownerToken: context.ownerToken)
            }.value
            guard await model.mediaContextIsCurrent(context, live: true),
                  var saved = entries[entryID], saved.ownerToken == context.ownerToken,
                  saved.offer == offer, !saved.audioCached else {
                try? cache.removeAudio(for: offer.requestID, ownerToken: context.ownerToken)
                return
            }
            saved.offer = offer
            saved.audioCached = true
            saved.downloadAttempts = 0
            saved.nextDownloadAt = nil
            saved.failure = nil
            saved.nextStatusAt = nil
            guard let verified = Self.verifiedIdentity(cachedURL, offer: offer, ownerToken: context.ownerToken) else {
                throw LibraryListenNextError.notDurable
            }
            entries[entryID] = saved
            verifiedAudio[entryID] = verified
            try persist()
        } catch {
            guard await model.mediaContextIsCurrent(context, live: true),
                  var entry = entries[entryID], entry.ownerToken == context.ownerToken else { return }
            entry.downloadAttempts += 1
            entry.audioCached = false
            entry.nextDownloadAt = Self.retryDate(
                attempt: entry.downloadAttempts, now: now(), delays: Self.downloadRetryDelays)
            if entry.downloadAttempts >= Self.downloadRetryDelays.count {
                entry.failure = .transferFailed
                entry.nextDownloadAt = nil
            }
            entries[entryID] = entry
            verifiedAudio.removeValue(forKey: entryID)
            try? cache.removeAudio(for: offer.requestID, ownerToken: context.ownerToken)
            try? persist()
            bulletinAudioLog.notice("A bulletin clip transfer failed; a bounded retry was scheduled.")
        }
    }

    private func downloadDueOffers(
        model: LibraryAppModel, context: LibraryMediaContext, limit: Int
    ) async {
        let due = entries.values.filter {
            $0.ownerToken == context.ownerToken && $0.offer != nil && !$0.audioCached && $0.failure == nil
                && $0.expiresAt > now() && $0.downloadAttempts < Self.downloadRetryDelays.count
                && ($0.nextDownloadAt.map { $0 <= now() } ?? true)
        }.sorted { $0.expiresAt < $1.expiresAt }.prefix(limit)
        for entry in due {
            guard await model.mediaContextIsCurrent(context, live: true), let offer = entry.offer else { return }
            await download(offer, entryID: entry.requestID, model: model, context: context)
        }
    }

    private func removeExpiredEntries() {
        let expired = entries.values.filter { $0.expiresAt <= now() }
        for entry in expired {
            try? cache.removeAudio(for: entry.requestID, ownerToken: entry.ownerToken)
            verifiedAudio.removeValue(forKey: entry.requestID)
            entries.removeValue(forKey: entry.requestID)
        }
        if !expired.isEmpty { try? persist() }
    }

    private func advanceStatusBackoff(for ids: Set<String>) {
        for id in ids {
            guard var entry = entries[id] else { continue }
            advanceStatusPoll(&entry)
            entries[id] = entry
        }
    }

    private func advanceStatusPoll(_ entry: inout LibraryBulletinAudioEntry) {
        entry.statusAttempts = min(max(entry.statusAttempts, 0), Self.statusPollDelays.count - 1) + 1
        let current = now()
        let index = min(entry.statusAttempts - 1, Self.statusPollDelays.count - 1)
        let remaining = max(0, entry.expiresAt.timeIntervalSince(current))
        let lifetimeCadence = max(30, remaining / 8)
        let delay = min(Self.statusPollDelays[index], lifetimeCadence)
        entry.nextStatusAt = current.addingTimeInterval(delay)
    }

    private func persist() throws {
        guard isWritable, let manifestURL, let owner = loadedOwner, entries.count <= Self.maxEntries else {
            throw LibraryListenNextError.notDurable
        }
        let saved = LibraryBulletinAudioManifest(
            version: Self.version, ownerToken: owner,
            entries: entries.values.sorted { $0.requestID < $1.requestID })
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: manifestURL, options: [.atomic, LibraryFileProtection.writingOption])
    }

    private static func requestID(for bulletin: Bulletin, deviceID: String) -> String? {
        guard !deviceID.isEmpty else { return nil }
        let identity = [
            deviceID, bulletin.id,
            String(bulletin.issuedAt.timeIntervalSinceReferenceDate.bitPattern),
            String(bulletin.expiresAt.timeIntervalSinceReferenceDate.bitPattern),
            textHash(bulletin.text),
        ].joined(separator: "\0")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "bulletin-audio-\(digest)"
    }

    private static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func retryDate(attempt: Int, now: Date) -> Date {
        retryDate(attempt: attempt, now: now, delays: retryDelays)
    }

    private static func retryDate(attempt: Int, now: Date, delays: [TimeInterval]) -> Date {
        let index = min(max(attempt - 1, 0), delays.count - 1)
        return now.addingTimeInterval(delays[index])
    }

    nonisolated private static func audioFile(_ url: URL, matches offer: LibraryStoryAudioOffer) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == offer.byteCount,
              let hash = try? MediaHash.sha256(fileAt: url) else { return false }
        return hash == offer.contentHash
    }

    private func verifyCachedAudio(owner: String, requestIDs: Set<String>) async {
        for requestID in requestIDs {
            guard localOwner == owner, var entry = entries[requestID], entry.ownerToken == owner,
                  entry.expiresAt > now(), let offer = entry.offer, entry.audioCached,
                  let url = cache.url(for: offer, ownerToken: owner) else { continue }
            if let verified = verifiedAudio[requestID], verified.ownerToken == owner,
               verified.offer == offer, verified.url.standardizedFileURL == url.standardizedFileURL,
               Self.fileIdentityMatches(url, verified: verified) { continue }
            let verified = await Task.detached(priority: .utility) {
                Self.audioFile(url, matches: offer)
                    ? Self.verifiedIdentity(url, offer: offer, ownerToken: owner) : nil
            }.value
            guard localOwner == owner, !modelIsQuarantined, entries[requestID] == entry else { return }
            if let verified {
                verifiedAudio[requestID] = verified
            } else {
                entry.audioCached = false
                entry.nextDownloadAt = now()
                if entry.downloadAttempts >= Self.downloadRetryDelays.count {
                    entry.failure = .transferFailed
                    entry.nextDownloadAt = nil
                }
                entries[requestID] = entry
                verifiedAudio.removeValue(forKey: requestID)
                try? cache.removeAudio(for: requestID, ownerToken: owner)
                try? persist()
            }
        }
    }

    private var modelIsQuarantined: Bool { model?.accountQuarantined ?? true }

    nonisolated private static func verifiedIdentity(
        _ url: URL, offer: LibraryStoryAudioOffer, ownerToken: String
    ) -> VerifiedBulletinAudio? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
              byteCount == offer.byteCount else { return nil }
        return VerifiedBulletinAudio(ownerToken: ownerToken, offer: offer, url: url,
                                     byteCount: byteCount, modifiedAt: attributes[.modificationDate] as? Date)
    }

    nonisolated private static func fileIdentityMatches(_ url: URL, verified: VerifiedBulletinAudio) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == verified.byteCount else { return false }
        return (attributes[.modificationDate] as? Date) == verified.modifiedAt
    }
}
