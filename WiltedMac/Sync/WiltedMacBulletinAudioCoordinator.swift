import AVFoundation
import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

/// Renders one current Mac-owned bulletin with its approved local voice and returns only audio
/// to the requesting phone. The request itself contains only the bulletin identity.
@MainActor
final class WiltedMacBulletinAudioCoordinator {
    typealias RenderOperation = @Sendable (
        String, ApprovedReadingVoiceID, URL
    ) async throws -> ArticleNarrationAudio

    private struct Context: Equatable {
        let owner: String
        let generation: UInt64
    }

    private struct RetainedOffer: Codable, Equatable {
        let owner: String
        let offer: LibraryStoryAudioOffer
        let expiresAt: Date
    }

    private struct RetainedOffers: Codable {
        var version = 1
        var entries: [RetainedOffer]
    }

    private struct ResolvedBulletin {
        enum Source { case macLocal, publicIdentity }
        let bulletin: Bulletin
        let source: Source
    }

    private let audioTransport: any LibraryStoryAudioTransport
    private let deviceID: String
    private let directory: URL
    private let retainedOffersURL: URL
    private let currentOwner: @Sendable () async -> String?
    private let currentGeneration: @Sendable () async -> UInt64
    private let bulletin: @MainActor (String) -> Bulletin?
    private let bulletinFallback: @MainActor (String) async -> Bulletin?
    private let readyAudioURL: @MainActor (Bulletin, ApprovedReadingVoiceID) -> URL?
    private let selectedVoice: @MainActor () -> ApprovedReadingVoiceID?
    private let voiceAvailability: @MainActor (ApprovedReadingVoiceID) -> ArticleVoiceAvailability
    private let render: RenderOperation
    private let now: @Sendable () -> Date
    private var tasks: [String: Task<Void, Never>] = [:]
    private var cleanupTasks: [String: Task<Void, Never>] = [:]

    init(
        audioTransport: any LibraryStoryAudioTransport,
        deviceID: String,
        directory: URL,
        currentOwner: @escaping @Sendable () async -> String?,
        currentGeneration: @escaping @Sendable () async -> UInt64,
        bulletin: @escaping @MainActor (String) -> Bulletin?,
        bulletinFallback: @escaping @MainActor (String) async -> Bulletin? = { _ in nil },
        readyAudioURL: @escaping @MainActor (Bulletin, ApprovedReadingVoiceID) -> URL?,
        selectedVoice: @escaping @MainActor () -> ApprovedReadingVoiceID?,
        voiceAvailability: @escaping @MainActor (ApprovedReadingVoiceID) -> ArticleVoiceAvailability = {
            ArticleNarrationCoordinator().availability(for: $0)
        },
        render: @escaping RenderOperation = { text, voiceID, outputURL in
            try await ArticleNarrationCoordinator().synthesizeShortText(text, voiceID: voiceID, outputURL: outputURL)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audioTransport = audioTransport
        self.deviceID = deviceID
        self.directory = directory
        retainedOffersURL = directory.appending(path: "retained-bulletin-audio.json")
        self.currentOwner = currentOwner
        self.currentGeneration = currentGeneration
        self.bulletin = bulletin
        self.bulletinFallback = bulletinFallback
        self.readyAudioURL = readyAudioURL
        self.selectedVoice = selectedVoice
        self.voiceAvailability = voiceAvailability
        self.render = render
        self.now = now
    }

    /// Applies only a request addressed to this Mac's active linked device.
    func handle(_ intent: LibraryIntent) async throws -> IntentOutcome {
        guard case let .requestBulletinAudio(bulletinID) = intent.action,
              intent.deviceID != deviceID,
              let owner = await currentOwner(), !owner.isEmpty else {
            return try .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: now())
        }
        let context = Context(owner: owner, generation: await currentGeneration())
        guard await isCurrent(context) else {
            return try .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: now())
        }
        let existing = try await audioTransport.listenNextStatuses(
            requestIDs: [intent.id], expectedOwner: owner).first
        guard await isCurrent(context) else {
            return try .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: now())
        }
        if let existing {
            guard existing.requesterDeviceID == intent.deviceID, existing.storyID == bulletinID else {
                return try .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: now())
            }
            if existing.phase == .ready || existing.phase == .failed || existing.phase == .cancelled {
                return try .applied(for: intent, at: now())
            }
        }
        if tasks[intent.id] != nil { return try .applied(for: intent, at: now()) }
        guard let resolved = await resolveBulletin(bulletinID),
              await bulletinIsCurrent(resolved, context: context),
              await isCurrent(context) else {
            try await publishFailure(intent, bulletinID: bulletinID, context: context,
                                     revision: (existing?.statusRevision ?? 0) + 1, failure: .unavailableStory)
            return try .applied(for: intent, at: now())
        }
        guard let voice = selectedVoice() else {
            try await publishFailure(intent, bulletinID: bulletinID, context: context,
                                     revision: (existing?.statusRevision ?? 0) + 1, failure: .missingVoice)
            return try .applied(for: intent, at: now())
        }
        try await publishStatus(
            requestID: intent.id, bulletinID: bulletinID, requesterDeviceID: intent.deviceID,
            context: context, revision: (existing?.statusRevision ?? 0) + 1, phase: .preparing,
            voice: voice, offer: nil, failure: nil)
        guard await bulletinIsCurrent(resolved, context: context), selectedVoice() == voice else {
            return try .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: now())
        }
        let task = Task { @MainActor [weak self] in
            await self?.prepare(intent: intent, resolved: resolved, voice: voice, context: context,
                                revision: (existing?.statusRevision ?? 0) + 2)
            self?.tasks.removeValue(forKey: intent.id)
        }
        tasks[intent.id] = task
        return try .applied(for: intent, at: now())
    }

    /// Removes expired remote clips after relaunch or while this Mac remains open.
    func cleanupExpiredOffers() async {
        let values = loadRetainedOffers()
        guard let owner = await currentOwner(), !owner.isEmpty else { return }
        let context = Context(owner: owner, generation: await currentGeneration())
        guard await isCurrent(context) else { return }
        let expired = values.filter { $0.owner == owner && $0.expiresAt <= now() }
        for value in expired {
            guard await isCurrent(context) else { return }
            cleanupTasks[value.offer.requestID]?.cancel()
            cleanupTasks.removeValue(forKey: value.offer.requestID)
            try? await audioTransport.removeStoryAudio(value.offer, expectedOwner: owner)
            guard await isCurrent(context) else { return }
        }
        let retained = values.filter { $0.owner != owner || $0.expiresAt > now() }
        saveRetainedOffers(retained)
        for value in retained where value.owner == owner { scheduleCleanup(value, context: context) }
    }

    func invalidate() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        cleanupTasks.values.forEach { $0.cancel() }
        cleanupTasks.removeAll()
    }

    private func prepare(
        intent: LibraryIntent,
        resolved: ResolvedBulletin,
        voice: ApprovedReadingVoiceID,
        context: Context,
        revision: UInt64
    ) async {
        let expected = resolved.bulletin
        var renderedURL: URL?
        let requestDirectory = directory.appending(path: Self.digest(intent.id), directoryHint: .isDirectory)
        defer {
            if let renderedURL { try? FileManager.default.removeItem(at: renderedURL.deletingLastPathComponent()) }
        }
        do {
            guard await isCurrent(context) else { return }
            guard await bulletinIsCurrent(resolved, context: context) else {
                await fail(intent, bulletin: expected, context: context, revision: revision, failure: .unavailableStory)
                return
            }
            guard selectedVoice() == voice, voiceAvailability(voice).isAvailable else {
                await fail(intent, bulletin: expected, context: context, revision: revision, failure: .missingVoice)
                return
            }
            let sourceURL: URL
            if let ready = readyAudioURL(expected, voice) {
                sourceURL = ready
            } else {
                try FileManager.default.createDirectory(
                    at: requestDirectory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let output = requestDirectory.appending(path: "bulletin.m4a")
                let audio = try await render(expected.text, voice, output)
                guard await bulletinIsCurrent(resolved, context: context) else {
                    await fail(intent, bulletin: expected, context: context, revision: revision, failure: .unavailableStory)
                    return
                }
                guard selectedVoice() == voice else {
                    await fail(intent, bulletin: expected, context: context, revision: revision, failure: .missingVoice)
                    return
                }
                guard audio.audioURL.standardizedFileURL == output.standardizedFileURL,
                      audio.voiceRevision == ArticleNarrationCoordinator.shortTextVoiceRevision(for: voice),
                      audio.duration.isFinite, audio.duration > 0 else {
                    throw ArticleNarrationError.invalidAudio
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                renderedURL = output
                sourceURL = output
            }
            guard await bulletinIsCurrent(resolved, context: context) else {
                await fail(intent, bulletin: expected, context: context, revision: revision, failure: .unavailableStory)
                return
            }
            guard selectedVoice() == voice else {
                await fail(intent, bulletin: expected, context: context, revision: revision, failure: .missingVoice)
                return
            }
            let values = try Self.audioIdentity(sourceURL)
            let offer = try LibraryStoryAudioOffer(
                requestID: intent.id, storyID: expected.id, requesterDeviceID: intent.deviceID,
                voiceID: voice.rawValue, voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voice),
                audioRevision: try RevisionID(rawValue: "bulletin-\(String(values.hash.dropFirst(MediaHash.prefix.count)))"),
                contentHash: values.hash, byteCount: values.byteCount, mediaType: "audio/mp4",
                durationSeconds: values.duration)
            let retained = RetainedOffer(owner: context.owner, offer: offer, expiresAt: expected.expiresAt)
            saveRetainedOffers(loadRetainedOffers().filter { $0.offer.requestID != offer.requestID } + [retained])
            scheduleCleanup(retained, context: context)
            guard await isCurrent(context) else { return }
            try await audioTransport.publishStoryAudio(offer: offer, fileURL: sourceURL, expectedOwner: context.owner)
            guard await bulletinIsCurrent(resolved, context: context), selectedVoice() == voice else {
                if await isCurrent(context) {
                    try? await audioTransport.removeStoryAudio(offer, expectedOwner: context.owner)
                }
                return
            }
            try await publishStatus(
                requestID: intent.id, bulletinID: expected.id, requesterDeviceID: intent.deviceID,
                context: context, revision: revision, phase: .ready,
                voice: voice, offer: offer, failure: nil)
        } catch {
            let failure: LibraryListenNextStatus.Failure
            guard await isCurrent(context) else { return }
            if !(await bulletinIsCurrent(resolved, context: context)) {
                failure = .unavailableStory
            } else if selectedVoice() != voice {
                failure = .missingVoice
            } else {
                failure = .narrationFailed
            }
            await fail(intent, bulletin: expected, context: context, revision: revision, failure: failure)
        }
    }

    private func fail(
        _ intent: LibraryIntent, bulletin: Bulletin, context: Context,
        revision: UInt64, failure: LibraryListenNextStatus.Failure
    ) async {
        guard await isCurrent(context) else { return }
        try? await publishFailure(intent, bulletinID: bulletin.id, context: context,
                                  revision: revision, failure: failure)
    }

    private func publishFailure(
        _ intent: LibraryIntent, bulletinID: String, context: Context,
        revision: UInt64, failure: LibraryListenNextStatus.Failure
    ) async throws {
        try await publishStatus(
            requestID: intent.id, bulletinID: bulletinID, requesterDeviceID: intent.deviceID,
            context: context, revision: revision, phase: .failed, voice: nil, offer: nil, failure: failure)
    }

    private func publishStatus(
        requestID: String, bulletinID: String, requesterDeviceID: String,
        context: Context, revision: UInt64, phase: LibraryListenNextStatus.Phase,
        voice: ApprovedReadingVoiceID?, offer: LibraryStoryAudioOffer?,
        failure: LibraryListenNextStatus.Failure?
    ) async throws {
        let status = try LibraryListenNextStatus(
            requestID: requestID, storyID: bulletinID, requesterDeviceID: requesterDeviceID,
            phase: phase, statusRevision: revision, updatedAt: now(),
            voiceID: voice?.rawValue,
            voiceRevision: voice.map(ArticleNarrationCoordinator.shortTextVoiceRevision(for:)),
            audioOffer: offer, failure: failure)
        guard await isCurrent(context), voice.map({ selectedVoice() == $0 }) ?? true else {
            throw LibraryTransportError.superseded
        }
        try await audioTransport.publishListenNextStatus(status, expectedOwner: context.owner)
    }

    private func isCurrent(_ context: Context) async -> Bool {
        let owner = await currentOwner()
        let generation = await currentGeneration()
        return !Task.isCancelled && owner == context.owner && generation == context.generation
    }

    private func resolveBulletin(_ id: String) async -> ResolvedBulletin? {
        if let local = bulletin(id) {
            return ResolvedBulletin(bulletin: local, source: .macLocal)
        }
        let remote = await bulletinFallback(id)
        return remote.map { ResolvedBulletin(bulletin: $0, source: .publicIdentity) }
    }

    private func bulletinIsCurrent(_ resolved: ResolvedBulletin, context: Context) async -> Bool {
        guard await isCurrent(context), resolved.bulletin.expiresAt > now() else { return false }
        guard case .macLocal = resolved.source else { return true }
        let current = bulletin(resolved.bulletin.id)
        return await isCurrent(context) && current == resolved.bulletin
    }

    private func loadRetainedOffers() -> [RetainedOffer] {
        guard let data = try? Data(contentsOf: retainedOffersURL),
              let saved = try? JSONDecoder().decode(RetainedOffers.self, from: data),
              saved.version == 1 else { return [] }
        return saved.entries
    }

    private func saveRetainedOffers(_ entries: [RetainedOffer]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(RetainedOffers(entries: entries))
            try data.write(to: retainedOffersURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: retainedOffersURL.path)
        } catch {
            return
        }
    }

    private func scheduleCleanup(_ value: RetainedOffer, context: Context) {
        guard cleanupTasks[value.offer.requestID] == nil else { return }
        let delay = max(0, value.expiresAt.timeIntervalSince(now()))
        cleanupTasks[value.offer.requestID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            cleanupTasks[value.offer.requestID] = nil
            guard await isCurrent(context), context.owner == value.owner else { return }
            try? await audioTransport.removeStoryAudio(value.offer, expectedOwner: value.owner)
            guard await isCurrent(context) else { return }
            saveRetainedOffers(loadRetainedOffers().filter { $0.offer.requestID != value.offer.requestID })
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func audioIdentity(_ url: URL) throws -> (hash: String, byteCount: Int64, duration: Double) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0,
              let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
              let player = try? AVAudioPlayer(contentsOf: url), player.duration.isFinite, player.duration > 0 else {
            throw ArticleNarrationError.invalidAudio
        }
        return (try MediaHash.sha256(fileAt: url), byteCount, player.duration)
    }
}

private extension ArticleVoiceAvailability {
    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}
