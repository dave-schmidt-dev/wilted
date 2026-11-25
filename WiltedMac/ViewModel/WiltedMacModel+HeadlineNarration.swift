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
    @ObservationIgnored private let availability: @MainActor (ApprovedReadingVoiceID) -> ArticleVoiceAvailability
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderGeneration: UInt64 = 0
    @ObservationIgnored private var activeRenderID: String?
    @ObservationIgnored private var voiceID: ApprovedReadingVoiceID?
    @ObservationIgnored private var accountIdentity: String?
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
        availability: @escaping @MainActor (ApprovedReadingVoiceID) -> ArticleVoiceAvailability = {
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

    /// Candidate IDs are admitted only when the local hub observes a new channel bulletin.
    func update(
        current headlines: [Bulletin],
        newlyPublished: [Bulletin],
        enabled: Bool,
        selectedVoice: ApprovedReadingVoiceID?,
        accountIdentity: String?,
        isEligible: @MainActor (Bulletin) -> Bool
    ) {
        let incoming = Dictionary(headlines.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        current = incoming
        if !enabled {
            clearCandidates()
            self.accountIdentity = accountIdentity
            return
        }

        let validIDs = Set(candidates.compactMap { id, bulletin in
            incoming[id] == bulletin && bulletin.expiresAt > now() && isEligible(bulletin) ? id : nil
        })
        for id in Array(candidates.keys) where !validIDs.contains(id) {
            candidates.removeValue(forKey: id)
            assets.removeValue(forKey: id).map { try? FileManager.default.removeItem(at: $0.url) }
        }
        queue.removeAll { !validIDs.contains($0) }
        states = states.filter { _, state in validIDs.contains(where: { candidates[$0]?.headlineStoryID == state.storyID }) }

        let newCandidate = newlyPublished.filter {
            incoming[$0.id] == $0 && $0.kind == .headline && $0.headlineStoryID != nil
                && $0.expiresAt > now() && isEligible($0)
        }.max(by: { $0.issuedAt < $1.issuedAt })
        if let newCandidate { candidates[newCandidate.id] = newCandidate }

        var retainedIDs = Set(candidates.values.max(by: { $0.issuedAt < $1.issuedAt }).map { [$0.id] } ?? [])
        if let activeRenderID, validIDs.contains(activeRenderID), candidates[activeRenderID] != nil {
            retainedIDs.insert(activeRenderID)
        }
        let removedActiveRender = activeRenderID.map { !retainedIDs.contains($0) } ?? false
        for id in Array(candidates.keys) where !retainedIDs.contains(id) {
            candidates.removeValue(forKey: id)
            assets.removeValue(forKey: id).map { try? FileManager.default.removeItem(at: $0.url) }
            states.removeValue(forKey: id)
        }
        queue.removeAll { !retainedIDs.contains($0) }
        if removedActiveRender {
            renderGeneration &+= 1
            renderTask?.cancel()
            renderTask = nil
            activeRenderID = nil
        }

        let voiceChanged = selectedVoice != voiceID
        let accountChanged = accountIdentity != self.accountIdentity
        let changedBetweenApprovedOwners = self.accountIdentity != nil && accountIdentity != self.accountIdentity
        if voiceChanged || accountChanged {
            renderGeneration &+= 1
            renderTask?.cancel()
            renderTask = nil
            activeRenderID = nil
            voiceID = selectedVoice
            if changedBetweenApprovedOwners {
                candidates.removeAll()
                queue.removeAll()
            }
            queue.removeAll()
            for asset in assets.values { try? FileManager.default.removeItem(at: asset.url) }
            assets.removeAll()
            states.removeAll()
        }
        self.accountIdentity = accountIdentity

        for bulletin in candidates.values.sorted(by: { $0.issuedAt < $1.issuedAt }) {
            guard let storyID = bulletin.headlineStoryID else { continue }
            if selectedVoice == nil {
                states[bulletin.id] = .chooseVoice(storyID: storyID, bulletinID: bulletin.id)
            } else if voiceChanged || accountChanged || states[bulletin.id] == nil {
                queue.append(bulletin.id)
            }
        }
        refreshLatestCandidate()
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
        guard current[bulletin.id] == bulletin, candidates[bulletin.id] == bulletin,
              accountIdentity == self.accountIdentity,
              bulletin.expiresAt > now(), let voiceID, let asset = assets[bulletin.id],
              asset.bulletin == bulletin, asset.voiceID == voiceID,
              asset.voiceRevision == ArticleNarrationCoordinator.voiceRevision(for: voiceID) else { return nil }
        return asset.url
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
        activeRenderID = nil
        queue.removeAll()
        candidates.removeAll()
        states.removeAll()
        for asset in assets.values { try? FileManager.default.removeItem(at: asset.url) }
        assets.removeAll()
        refreshLatestCandidate()
    }

    private func refreshLatestCandidate() {
        latestCandidateStoryID = candidates.values.filter { $0.expiresAt > now() }
            .max { $0.issuedAt < $1.issuedAt }?.headlineStoryID
    }

    private func startNextIfPossible() {
        guard renderTask == nil, let voiceID, let id = queue.first,
              let bulletin = candidates[id], current[id] == bulletin else { return }
        queue.removeFirst()
        let storyID = bulletin.headlineStoryID ?? ""
        let voiceRevision = ArticleNarrationCoordinator.voiceRevision(for: voiceID)
        let state = WiltedMacHeadlineNarrationState.preparing(
            storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, voiceRevision: voiceRevision)
        states[id] = state
        switch availability(voiceID) {
        case .available: break
        case .missingVoice:
            states[id] = .unavailable(storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, reason: .voiceFilesMissing)
            startNextIfPossible()
            return
        case .missingModel:
            states[id] = .unavailable(storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, reason: .modelMissing)
            startNextIfPossible()
            return
        case .missingRuntime:
            states[id] = .unavailable(storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, reason: .runtimeUnavailable)
            startNextIfPossible()
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            states[id] = .unavailable(storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, reason: .renderFailed)
            startNextIfPossible()
            return
        }
        let outputURL = directory.appending(path: "\(UUID().uuidString).m4a")
        let generation = renderGeneration
        let render = self.render
        activeRenderID = id
        renderTask = Task { @MainActor [weak self] in
            do {
                let audio = try await render(bulletin.text, voiceID, outputURL)
                guard let self else { try? FileManager.default.removeItem(at: outputURL); return }
                guard !Task.isCancelled, self.renderGeneration == generation,
                      self.voiceID == voiceID, self.candidates[id] == bulletin,
                      self.current[id] == bulletin, bulletin.expiresAt > self.now(),
                      audio.voiceRevision == voiceRevision, audio.audioURL == outputURL else {
                    try? FileManager.default.removeItem(at: outputURL)
                    if self.renderGeneration == generation {
                        self.renderTask = nil
                        self.activeRenderID = nil
                        self.startNextIfPossible()
                    }
                    return
                }
                self.assets[id] = (bulletin, voiceID, audio.voiceRevision, audio.audioURL)
                self.states[id] = .ready(
                    storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, voiceRevision: voiceRevision)
                self.onReady?(bulletin)
            } catch {
                guard let self else { return }
                try? FileManager.default.removeItem(at: outputURL)
                guard self.renderGeneration == generation else { return }
                if self.candidates[id] == bulletin {
                    self.states[id] = .unavailable(
                        storyID: storyID, bulletinID: bulletin.id, voiceID: voiceID, reason: .renderFailed)
                }
            }
            if self?.renderGeneration == generation {
                self?.renderTask = nil
                self?.activeRenderID = nil
                self?.startNextIfPossible()
            }
        }
    }
}

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
    private let alertSpeaker: any BulletinSpeaking
    private let audioURL: @MainActor (Bulletin) -> URL?
    private let audioPlayer: any WiltedMacHeadlineAudioPlaying

    init(alertSpeaker: any BulletinSpeaking = SystemBulletinSpeaker(),
         audioURL: @escaping @MainActor (Bulletin) -> URL?,
         audioPlayer: any WiltedMacHeadlineAudioPlaying = WiltedMacAVHeadlineAudioPlayer()) {
        self.alertSpeaker = alertSpeaker
        self.audioURL = audioURL
        self.audioPlayer = audioPlayer
    }

    func speak(_ text: String, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        false
    }

    func speak(_ bulletin: Bulletin, playbackVolume: Float,
               finished: @escaping @MainActor () -> Void) -> Bool {
        guard bulletin.kind == .headline else {
            audioPlayer.stop()
            return alertSpeaker.speak(bulletin, playbackVolume: playbackVolume, finished: finished)
        }
        guard let url = audioURL(bulletin) else { return false }
        alertSpeaker.stop()
        return audioPlayer.play(
            url: url, volume: BulletinSpeechGain.volume(forPlaybackVolume: playbackVolume), finished: finished)
    }

    func stop() {
        alertSpeaker.stop()
        audioPlayer.stop()
    }
}
