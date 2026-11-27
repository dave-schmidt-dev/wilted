import AVFoundation
import Foundation
import Observation
import WiltedLibrary
import WiltedProducer

/// The local voice status for the exact story attached to a live headline bulletin.
enum WiltedMacHeadlineNarrationState: Equatable, Sendable {
    enum UnavailableReason: Equatable, Sendable {
        case voiceFilesMissing
        case modelMissing
        case runtimeUnavailable
        case renderFailed
    }

    case notScheduled(storyID: String)
    case chooseVoice(storyID: String, bulletinID: String)
    case preparing(storyID: String, bulletinID: String, voiceID: ApprovedReadingVoiceID, voiceRevision: String)
    case ready(storyID: String, bulletinID: String, voiceID: ApprovedReadingVoiceID, voiceRevision: String)
    case unavailable(storyID: String, bulletinID: String, voiceID: ApprovedReadingVoiceID?, reason: UnavailableReason)

    var storyID: String {
        switch self {
        case let .notScheduled(storyID), let .chooseVoice(storyID, _), let .preparing(storyID, _, _, _),
             let .ready(storyID, _, _, _), let .unavailable(storyID, _, _, _): storyID
        }
    }
}

/// Serial local pre-rendering for newly published, still-current Mac headlines.
@MainActor
@Observable
final class WiltedMacHeadlineNarration {
    typealias RenderOperation = @Sendable (
        String, ApprovedReadingVoiceID, URL
    ) async throws -> ArticleNarrationAudio

    @ObservationIgnored private let render: RenderOperation
    @ObservationIgnored private let availability: @Sendable (ApprovedReadingVoiceID) -> ArticleVoiceAvailability
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var renderGeneration: UInt64 = 0
    @ObservationIgnored private var activeRenderID: String?
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var voiceID: ApprovedReadingVoiceID?
    @ObservationIgnored private var accountIdentity: String?
    @ObservationIgnored private var eligibility: @MainActor (Bulletin) -> Bool = { _ in false }
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var candidates: [String: Bulletin] = [:]
    @ObservationIgnored private var current: [String: Bulletin] = [:]
    @ObservationIgnored private var assets: [String: (
        bulletin: Bulletin, voiceID: ApprovedReadingVoiceID, voiceRevision: String, url: URL
    )] = [:]
    private(set) var states: [String: WiltedMacHeadlineNarrationState] = [:]
    private(set) var latestCandidateStoryID: String?
    var onReady: (@MainActor (Bulletin) -> Void)?

    init(
        render: @escaping RenderOperation = { text, voiceID, outputURL in
            try await ArticleNarrationCoordinator().synthesizeShortText(text, voiceID: voiceID, outputURL: outputURL)
        },
        availability: @escaping @Sendable (ApprovedReadingVoiceID) -> ArticleVoiceAvailability = {
            ArticleNarrationCoordinator().availability(for: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        directory: URL = FileManager.default.temporaryDirectory
            .appending(path: "wilted-headline-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
    ) {
        self.render = render
        self.availability = availability
        self.now = now
        self.directory = directory
    }

    /// Newly published eligible candidates stay available until spoken, expired, or invalidated.
    func update(
        current headlines: [Bulletin],
        newlyPublished: [Bulletin],
        enabled: Bool,
        selectedVoice: ApprovedReadingVoiceID?,
        accountIdentity: String?,
        isEligible: @escaping @MainActor (Bulletin) -> Bool
    ) {
        let incoming = Dictionary(headlines.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        current = incoming
        self.enabled = enabled
        self.eligibility = isEligible
        if !enabled {
            clearCandidates()
            self.accountIdentity = accountIdentity
            return
        }

        let validIDs = Set(candidates.compactMap { id, bulletin in
            bulletin.expiresAt > now() && isEligible(bulletin) ? id : nil
        })
        for id in Array(candidates.keys) where !validIDs.contains(id) {
            candidates.removeValue(forKey: id)
            assets.removeValue(forKey: id).map { try? FileManager.default.removeItem(at: $0.url) }
        }
        queue.removeAll { !validIDs.contains($0) }
        states = states.filter { id, _ in validIDs.contains(id) }

        let newCandidates = newlyPublished.filter {
            incoming[$0.id] == $0 && $0.kind == .headline && $0.headlineStoryID != nil
                && $0.expiresAt > now() && isEligible($0)
        }

        let voiceChanged = selectedVoice != voiceID
        let accountChanged = accountIdentity != self.accountIdentity
        let purgeAccountContext = accountChanged && !candidates.isEmpty
        if voiceChanged || accountChanged {
            renderGeneration &+= 1
            renderTask?.cancel()
            renderTask = nil
            activeRenderID = nil
            voiceID = selectedVoice
            queue.removeAll()
            for asset in assets.values { try? FileManager.default.removeItem(at: asset.url) }
            assets.removeAll()
            states.removeAll()
            if purgeAccountContext { candidates.removeAll() }
        }
        self.accountIdentity = accountIdentity

        for bulletin in newCandidates { candidates[bulletin.id] = bulletin }

        for bulletin in candidates.values.sorted(by: { $0.issuedAt < $1.issuedAt }) {
            guard let storyID = bulletin.headlineStoryID else { continue }
            if selectedVoice == nil {
                states[bulletin.id] = .chooseVoice(storyID: storyID, bulletinID: bulletin.id)
            } else if voiceChanged || accountChanged || states[bulletin.id] == nil {
                if !queue.contains(bulletin.id) { queue.append(bulletin.id) }
            }
        }
        refreshLatestCandidate()
        scheduleExpiry()
        startNextIfPossible()
    }

    func state(for storyID: String) -> WiltedMacHeadlineNarrationState {
        guard let bulletin = candidates.values
            .filter({ $0.headlineStoryID == storyID && $0.expiresAt > now() })
            .max(by: { $0.issuedAt < $1.issuedAt }) else {
            return .notScheduled(storyID: storyID)
        }
        return states[bulletin.id] ?? .notScheduled(storyID: storyID)
    }

    func audioURL(for bulletin: Bulletin, accountIdentity: String?) -> URL? {
        guard candidates[bulletin.id] == bulletin,
              accountIdentity == self.accountIdentity,
              bulletin.expiresAt > now(), let voiceID, let asset = assets[bulletin.id],
              asset.bulletin == bulletin, asset.voiceID == voiceID,
              asset.voiceRevision == ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID) else { return nil }
        return asset.url
    }

    var readyBulletins: [Bulletin] {
        candidates.values.filter { audioURL(for: $0, accountIdentity: accountIdentity) != nil }
            .sorted { $0.issuedAt < $1.issuedAt }
    }

    func didStart(_ bulletin: Bulletin) {
        guard candidates[bulletin.id] == bulletin else { return }
        candidates.removeValue(forKey: bulletin.id)
        queue.removeAll { $0 == bulletin.id }
        states.removeValue(forKey: bulletin.id)
        if let asset = assets.removeValue(forKey: bulletin.id) {
            try? FileManager.default.removeItem(at: asset.url)
        }
        refreshLatestCandidate()
        scheduleExpiry()
    }

    func shutdown() {
        renderGeneration &+= 1
        renderTask?.cancel()
        renderTask = nil
        activeRenderID = nil
        clearCandidates()
        try? FileManager.default.removeItem(at: directory)
    }

    private func clearCandidates() {
        renderGeneration &+= 1
        renderTask?.cancel()
        renderTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        activeRenderID = nil
        queue.removeAll()
        candidates.removeAll()
        states.removeAll()
        for asset in assets.values { try? FileManager.default.removeItem(at: asset.url) }
        assets.removeAll()
        refreshLatestCandidate()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard enabled, let expiresAt = candidates.values.map(\.expiresAt).min() else { return }
        let delay = max(0.01, expiresAt.timeIntervalSince(now()))
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.expiryTask = nil
            self.update(current: Array(self.current.values), newlyPublished: [], enabled: self.enabled,
                        selectedVoice: self.voiceID, accountIdentity: self.accountIdentity,
                        isEligible: self.eligibility)
        }
    }

    private func refreshLatestCandidate() {
        latestCandidateStoryID = candidates.values.filter { $0.expiresAt > now() }
            .max { $0.issuedAt < $1.issuedAt }?.headlineStoryID
    }

    private func startNextIfPossible() {
        guard renderTask == nil, let voiceID, let id = queue.first,
              let bulletin = candidates[id] else { return }
        queue.removeFirst()
        let storyID = bulletin.headlineStoryID ?? ""
        let voiceRevision = ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID)
        states[id] = .preparing(
            storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, voiceRevision: voiceRevision)
        let generation = renderGeneration
        activeRenderID = id
        renderTask = Task { @MainActor [weak self] in
            await self?.checkAvailabilityAndRender(
                bulletin, id: id, storyID: storyID, voiceID: voiceID,
                voiceRevision: voiceRevision, generation: generation)
        }
    }

    private func checkAvailabilityAndRender(
        _ bulletin: Bulletin, id: String, storyID: String, voiceID: ApprovedReadingVoiceID,
        voiceRevision: String, generation: UInt64
    ) async {
        guard taskStillOwns(bulletin, id: id, voiceID: voiceID, generation: generation) else {
            discardExpiredCandidateIfNeeded(bulletin, id: id)
            finishRenderTask(generation)
            return
        }
        let availability = self.availability
        let result = await Task.detached(priority: .utility) { availability(voiceID) }.value
        guard taskStillOwns(bulletin, id: id, voiceID: voiceID, generation: generation) else {
            discardExpiredCandidateIfNeeded(bulletin, id: id)
            finishRenderTask(generation)
            return
        }
        if let reason = unavailableReason(for: result) {
            states[id] = .unavailable(
                storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, reason: reason)
            finishRenderTask(generation)
            return
        }
        guard let outputURL = makeOutputURL() else {
            states[id] = .unavailable(
                storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, reason: .renderFailed)
            finishRenderTask(generation)
            return
        }
        await renderCandidate(bulletin, id: id, storyID: storyID, voiceID: voiceID,
                     voiceRevision: voiceRevision, generation: generation, outputURL: outputURL)
    }

    private func taskStillOwns(
        _ bulletin: Bulletin, id: String, voiceID: ApprovedReadingVoiceID, generation: UInt64
    ) -> Bool {
        !Task.isCancelled && renderGeneration == generation
            && self.voiceID == voiceID && candidates[id] == bulletin && bulletin.expiresAt > now()
    }

    private func discardExpiredCandidateIfNeeded(_ bulletin: Bulletin, id: String) {
        guard bulletin.expiresAt <= now(), candidates[id] == bulletin else { return }
        candidates.removeValue(forKey: id)
        queue.removeAll { $0 == id }
        states.removeValue(forKey: id)
        refreshLatestCandidate()
        scheduleExpiry()
    }

    private func unavailableReason(
        for availability: ArticleVoiceAvailability
    ) -> WiltedMacHeadlineNarrationState.UnavailableReason? {
        switch availability {
        case .available: nil
        case .missingVoice: .voiceFilesMissing
        case .missingModel: .modelMissing
        case .missingRuntime: .runtimeUnavailable
        }
    }

    private func makeOutputURL() -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return directory.appending(path: "\(UUID().uuidString).m4a")
        } catch {
            return nil
        }
    }

    private func renderCandidate(
        _ bulletin: Bulletin, id: String, storyID: String, voiceID: ApprovedReadingVoiceID,
        voiceRevision: String, generation: UInt64, outputURL: URL
    ) async {
        do {
            let audio = try await render(bulletin.text, voiceID, outputURL)
            guard taskStillOwns(bulletin, id: id, voiceID: voiceID, generation: generation),
                  bulletin.expiresAt > now(), audio.voiceRevision == voiceRevision,
                  audio.audioURL == outputURL else {
                try? FileManager.default.removeItem(at: outputURL)
                finishRenderTask(generation)
                return
            }
            assets[id] = (bulletin, voiceID, audio.voiceRevision, audio.audioURL)
            states[id] = .ready(
                storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, voiceRevision: voiceRevision)
            onReady?(bulletin)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            guard renderGeneration == generation else { return }
            if candidates[id] == bulletin {
                states[id] = .unavailable(
                    storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, reason: .renderFailed)
            }
        }
        finishRenderTask(generation)
    }

    private func finishRenderTask(_ generation: UInt64) {
        guard renderGeneration == generation else { return }
        renderTask = nil
        activeRenderID = nil
        startNextIfPossible()
    }
}

/// Renders active Mac weather alerts before the player receives them.
@MainActor
protocol WiltedMacHeadlineAudioPlaying: AnyObject {
    func play(url: URL, volume: Float, finished: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

@MainActor
final class WiltedMacAVHeadlineAudioPlayer: NSObject, WiltedMacHeadlineAudioPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: (@MainActor () -> Void)?
    private var playingID: ObjectIdentifier?

    func play(url: URL, volume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        self.player = player
        completion = finished
        player.volume = volume
        player.delegate = self
        guard player.prepareToPlay(), player.play() else {
            self.player = nil
            completion = nil
            return false
        }
        playingID = ObjectIdentifier(player)
        return true
    }

    func stop() {
        player?.stop()
        player?.delegate = nil
        player = nil
        completion = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.finish(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.finish(id) }
    }

    private func finish(_ id: ObjectIdentifier) {
        guard playingID == id else { return }
        playingID = nil
        player?.delegate = nil
        player = nil
        let finished = completion
        completion = nil
        finished?()
    }
}

@MainActor
final class WiltedMacHeadlineBulletinSpeaker: BulletinSpeaking {
    typealias ShortTextNarration = @Sendable (
        String, ApprovedReadingVoiceID, URL
    ) async throws -> ArticleNarrationAudio

    private let audioURL: @MainActor (Bulletin) -> URL?
    private let audioPlayer: any WiltedMacHeadlineAudioPlaying
    private let selectedVoice: @MainActor () -> ApprovedReadingVoiceID?
    private let renderShortText: ShortTextNarration
    private var shortTextTask: Task<Void, Never>?
    private var shortTextDirectory: URL?
    private var shortTextFinished: (@MainActor () -> Void)?
    private var shortTextGeneration: UInt64 = 0

    init(audioURL: @escaping @MainActor (Bulletin) -> URL?,
         audioPlayer: any WiltedMacHeadlineAudioPlaying = WiltedMacAVHeadlineAudioPlayer(),
         selectedVoice: @escaping @MainActor () -> ApprovedReadingVoiceID? = { nil },
         renderShortText: @escaping ShortTextNarration = { text, voiceID, outputURL in
             try await ArticleNarrationCoordinator().synthesizeShortText(
                 text, voiceID: voiceID, outputURL: outputURL)
         }) {
        self.audioURL = audioURL
        self.audioPlayer = audioPlayer
        self.selectedVoice = selectedVoice
        self.renderShortText = renderShortText
    }

    func speak(_ text: String, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        stop()
        guard let voiceID = selectedVoice(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= ArticleNarrationCoordinator.maximumShortTextUTF8Bytes else { return false }
        return speakShortText(text, voiceID: voiceID, playbackVolume: playbackVolume, finished: finished)
    }

    func speak(_ bulletin: Bulletin, playbackVolume: Float,
               finished: @escaping @MainActor () -> Void) -> Bool {
        stop()
        guard bulletin.kind == .headline || bulletin.kind == .alert else { return false }
        guard let url = audioURL(bulletin) else { return false }
        return audioPlayer.play(
            url: url, volume: BulletinSpeechGain.measuredAudioVolume(forPlaybackVolume: playbackVolume),
            finished: finished)
    }

    func stop() {
        shortTextGeneration &+= 1
        shortTextTask?.cancel()
        shortTextTask = nil
        shortTextFinished = nil
        if let shortTextDirectory { try? FileManager.default.removeItem(at: shortTextDirectory) }
        shortTextDirectory = nil
        audioPlayer.stop()
    }

    private func speakShortText(
        _ text: String,
        voiceID: ApprovedReadingVoiceID,
        playbackVolume: Float,
        finished: @escaping @MainActor () -> Void
    ) -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "wilted-short-bulletin-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }

        let outputURL = directory.appending(path: "bulletin.m4a")
        shortTextDirectory = directory
        shortTextFinished = finished
        let generation = shortTextGeneration
        let render = renderShortText
        let volume = BulletinSpeechGain.measuredAudioVolume(forPlaybackVolume: playbackVolume)
        shortTextTask = Task { @MainActor [weak self] in
            do {
                let audio = try await render(text, voiceID, outputURL)
                guard let self else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                guard !Task.isCancelled, self.shortTextGeneration == generation,
                      audio.audioURL == outputURL,
                      audio.voiceRevision == ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID),
                      audio.duration > 0, Self.fileSize(at: outputURL) > 44 else {
                    self.finishShortText(generation)
                    return
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
                self.shortTextTask = nil
                guard self.audioPlayer.play(url: outputURL, volume: volume, finished: { [weak self] in
                    self?.finishShortText(generation)
                }) else {
                    self.finishShortText(generation)
                    return
                }
            } catch {
                guard let self, self.shortTextGeneration == generation else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                self.finishShortText(generation)
            }
        }
        return true
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private func finishShortText(_ generation: UInt64) {
        guard shortTextGeneration == generation else { return }
        shortTextTask = nil
        let directory = shortTextDirectory
        shortTextDirectory = nil
        let finished = shortTextFinished
        shortTextFinished = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        finished?()
    }
}
