import AVFoundation
import Foundation
import Observation
import WiltedDomain

/// The small audio surface needed by the controller.  Keeping AVFoundation
/// behind this protocol makes all playback state tests deterministic.
@MainActor
public protocol PlaybackBackend: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    var rate: Float { get set }
    var volume: Float { get set }
    var loadedGeneration: UInt64 { get }
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)? { get set }

    func load(url: URL) throws
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

/// AVFoundation implementation used by the Mac producer at runtime.
@MainActor
public final class AVAudioPlayerBackend: NSObject, PlaybackBackend, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var playerGenerations: [ObjectIdentifier: UInt64] = [:]
    public private(set) var loadedGeneration: UInt64 = 0
    public var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
    public var rate: Float = 1 {
        didSet { player?.rate = rate }
    }
    public var volume: Float = 1 {
        didSet { player?.volume = volume }
    }

    public override init() {
        super.init()
    }

    public var duration: TimeInterval { player?.duration ?? 0 }
    public var currentTime: TimeInterval {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = max(0, newValue) }
    }
    public var isPlaying: Bool { player?.isPlaying ?? false }

    public func load(url: URL) throws {
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self
        next.enableRate = true
        next.rate = rate
        next.volume = volume
        // No `prepareToPlay()` here: the app restores the last episode at
        // launch, and priming the player wakes the output hardware, which on
        // external speakers and DACs is an audible click before anyone has
        // asked for sound. `play()` primes on demand.
        forgetCurrentPlayer()
        loadedGeneration &+= 1
        playerGenerations[ObjectIdentifier(next)] = loadedGeneration
        player = next
    }

    @discardableResult
    public func play() -> Bool { player?.play() ?? false }
    public func pause() { player?.pause() }
    public func stop() {
        player?.stop()
        forgetCurrentPlayer()
        player = nil
    }

    /// The generation map is keyed on `ObjectIdentifier`, which is the player's
    /// address. An entry left behind for a released player can therefore be
    /// matched by a later `AVAudioPlayer` allocated at the same address, and the
    /// completion callback would then report a superseded generation. Drop the
    /// entry at every point this backend stops owning the player; the natural
    /// completion path already removes its own entry when it fires.
    private func forgetCurrentPlayer() {
        guard let player else { return }
        playerGenerations.removeValue(forKey: ObjectIdentifier(player))
    }

    /// Test seam for the pruning above; the map itself stays private.
    var trackedGenerationCount: Int { playerGenerations.count }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let generation = self.playerGenerations.removeValue(forKey: playerID) else {
                return
            }
            self.completionHandler?(generation, flag)
        }
    }
}

public enum PlaybackControllerError: Error, Equatable, Sendable {
    case revisionBelongsToDifferentItem
    case noLoadedRevision
    case invalidSeek(TimeInterval)
    case podcastMediaUnavailable(ItemID)
    case podcastMediaUnreadable(ItemID)
    /// The audio engine reported unsuccessful playback, including failure at
    /// the final frame. Recoverable: the listener can press play again.
    case playbackFailed(ItemID)
}

/// Main-actor playback orchestration and durable resume state.
@Observable
@MainActor
public final class PlaybackController {
    @ObservationIgnored let store: LocalLibraryStore
    @ObservationIgnored public let backend: any PlaybackBackend
    public let deviceID: String

    public private(set) var itemID: ItemID?
    public private(set) var revisionID: RevisionID?
    public private(set) var mediaURL: URL?
    /// The rate every load starts at unless the episode has its own saved
    /// speed. The owner's last chosen speed, not 1: a listener who always
    /// plays at 1.25× should not have to re-select it for each article and
    /// each first play of an episode.
    public var defaultRate: Float {
        get { clampedDefaultRate }
        set { clampedDefaultRate = Self.clampRate(newValue) }
    }
    private var clampedDefaultRate: Float = 1
    public internal(set) var positionSeconds: TimeInterval = 0
    public private(set) var durationSeconds: TimeInterval = 0
    public internal(set) var isPlaying = false
    /// The playhead as the audio engine reports it right now.
    ///
    /// `positionSeconds` is checkpoint state: it moves only when something
    /// causal happens (load, seek, checkpoint), because that is the value
    /// that gets persisted and synced. A readout that polls it while audio
    /// runs therefore sees it frozen at the last checkpoint, which is why the
    /// producer's elapsed time only moved when a transport button was
    /// pressed. A failed backend may reset its clock, so that state displays
    /// the retained stop checkpoint. These display reads write nothing.
    public var livePositionSeconds: TimeInterval {
        if let itemID, recoverableFault == .playbackFailed(itemID) { return positionSeconds }
        return clamp(backend.currentTime)
    }
    public var liveIsPlaying: Bool { backend.isPlaying }
    public var playbackRate: Float { backend.rate }

    public internal(set) var sessionID: String?
    public internal(set) var sequence: Int64 = 1
    public internal(set) var intent: PlaybackIntent = .progress
    public internal(set) var completed = false
    public internal(set) var recoverableFault: PlaybackControllerError?
    @ObservationIgnored public var podcastStateHandler: (@MainActor @Sendable (ItemID?, PlaybackControllerError?) -> Void)?
    /// Fired when the backend stops unsuccessfully, or finishes an item with
    /// nothing advancing behind it: an article, or the last queued episode.
    /// `podcastStateHandler` carries queue advances and podcast faults; this
    /// handler also lets surfaces observe that playback stopped.
    @ObservationIgnored public var playbackDidFinishHandler: (@MainActor @Sendable () -> Void)?
    /// Fired once the durable "finished" checkpoint for a podcast episode has
    /// been written, before any queue-advance logic runs. Never fired for
    /// articles. The caller must not touch the podcast queue from inside
    /// this handler: it runs mid-suspension inside `handleBackendCompletion`,
    /// before that function re-reads queue state, and a queue mutation here
    /// would race that read.
    @ObservationIgnored public var podcastCompletionHandler: (@MainActor @Sendable (ItemID) -> Void)?
    /// Predicate used to determine whether a queued podcast episode is eligible
    /// for playback (e.g. downloaded, prepared, and ready media available).
    @ObservationIgnored public var episodeEligibilityPredicate: (@MainActor @Sendable (ItemID) async -> Bool)?

    var currentRevision: AudioRevision?
    var checkpointTask: Task<Void, Never>?
    var completionHandledGeneration: UInt64?
    /// Bumped by every explicit pause or stop. A queue advance compares it
    /// with the value at the end of file to tell whether one was issued since.
    var explicitHoldSerial: UInt64 = 0
    var loadedBackendGeneration: UInt64?
    var loadedIsPodcastEpisode = false
    var pendingSpeedIntervals: [PendingSpeedInterval] = []
    /// Program position at the last accounting boundary. Forward seeks reset
    /// this baseline before persistence, so skipped audio is never playback.
    var speedSavingsBaselineSeconds: TimeInterval = 0
    var speedSavingsRate = 1.0
    /// The last state written for the loaded revision, so a checkpoint that changes nothing (paused,
    /// same position, session, intent and completion) keeps its original time. Otherwise every
    /// idle checkpoint, such as the one taken when the app goes to the background, would look
    /// newer than a position another device saved in the meantime.
    var lastWritten: (sessionID: String, position: TimeInterval, completed: Bool, intent: PlaybackIntent, at: Date)?
    /// Measured lifetime totals (played and manually skipped time) for the
    /// loaded attempt, plus amounts still waiting to be admitted to the store.
    @ObservationIgnored var lifetimeMeter = PlaybackLifetimeMeter()
    /// Monotonic seconds used to measure active listening. System uptime
    /// stops while the Mac sleeps, so sleep is never counted as listening.
    /// Tests replace it with a fake clock.
    @ObservationIgnored var listeningClock: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    public init(
        store: LocalLibraryStore,
        backend: any PlaybackBackend = AVAudioPlayerBackend(),
        deviceID: String = "mac"
    ) {
        self.store = store
        self.backend = backend
        self.deviceID = deviceID
        self.backend.completionHandler = { [weak self] generation, successfully in
            // Read at the end of file itself, so a pause issued before the
            // task below runs still counts as issued after the end.
            let holdAtEnd = self?.explicitHoldSerial ?? 0
            Task { @MainActor [weak self] in
                await self?.handleBackendCompletion(
                    generation: generation, successfully: successfully, holdAtEnd: holdAtEnd)
            }
        }
    }

    @discardableResult
    func loadRevision(
        _ revision: AudioRevision, mediaURL: URL, expectedGeneration: UInt64? = nil, isPodcast: Bool = false
    ) async throws -> UInt64 {
        // Admit the outgoing attempt's measured time before it is replaced, so
        // switching items never leaves more than the crash-tail bound unsaved.
        // A statistics failure must not block loading; the amount stays pending.
        try? await flushLifetimeMeasures()
        let persisted = try await store.playbackState(
            for: revision.itemID,
            revisionID: revision.revisionID
        )
        if let expectedGeneration, loadedBackendGeneration != expectedGeneration {
            throw CancellationError()
        }
        try backend.load(url: mediaURL)
        beginLifetimeAttempt(itemID: revision.itemID, revisionID: revision.revisionID)
        checkpointTask?.cancel()
        pendingSpeedIntervals.removeAll()
        loadedBackendGeneration = backend.loadedGeneration
        setRate(defaultRate)

        currentRevision = revision
        itemID = revision.itemID
        revisionID = revision.revisionID
        loadedIsPodcastEpisode = isPodcast
        self.mediaURL = mediaURL
        durationSeconds = revision.durationSeconds
        if backend.duration > 0 { durationSeconds = backend.duration }

        if let persisted {
            sessionID = persisted.sessionID
            sequence = persisted.sequence
            intent = persisted.intent
            completed = persisted.completed
            positionSeconds = clamp(persisted.positionSeconds)
            lastWritten = (persisted.sessionID, persisted.positionSeconds, persisted.completed, persisted.intent, persisted.updatedAt.date)
        } else {
            lastWritten = nil
            sessionID = Self.newSessionID()
            sequence = 1
            intent = .progress
            completed = false
            positionSeconds = 0
        }
        backend.currentTime = positionSeconds
        speedSavingsBaselineSeconds = positionSeconds
        speedSavingsRate = Double(backend.rate)
        isPlaying = false
        recoverableFault = nil
        completionHandledGeneration = nil
        return backend.loadedGeneration
    }

    /// Restores the durable current queue item without starting a duplicate
    /// playback session. Loading the exact revision reuses its saved session.
    public func restorePodcastQueue() async {
        guard let current = try? await store.podcastQueueState().currentEpisodeID else { return }
        do { try await loadQueuedEpisode(current, playAfterLoad: false) }
        catch { podcastStateHandler?(current, recoverableFault) }
    }

    public func replacePodcastQueue(_ state: PodcastQueueState) async throws {
        try await store.replacePodcastQueue(state)
    }

    public func addPodcastQueueEpisode(_ episodeID: ItemID) async throws {
        try await store.addPodcastQueueEpisode(episodeID)
    }

    public func removePodcastQueueEpisode(_ episodeID: ItemID) async throws {
        try await store.removePodcastQueueEpisode(episodeID)
    }

    public func movePodcastQueueEpisode(from source: Int, to destination: Int) async throws {
        try await store.movePodcastQueueEpisode(from: source, to: destination)
    }

    public func selectPodcastQueueEpisode(_ episodeID: ItemID, autoplay: Bool = false) async throws {
        try await loadQueuedEpisode(episodeID, playAfterLoad: autoplay)
        try await store.addPodcastQueueEpisode(episodeID)
        try await store.setCurrentPodcastQueueEpisode(episodeID)
        podcastStateHandler?(episodeID, nil)
    }

    /// Plays an episode immediately while preserving the displaced episode's
    /// place in the listening sequence. This is the Mac "Play Now" operation;
    /// ordinary Previous/Next selection intentionally keeps its existing
    /// current-marker-only semantics.
    ///
    /// `startsIf` is asked at the moment the loaded episode would start, after
    /// the last await, so a caller that owns start intent can decline when a
    /// newer command (a Pause) arrived while the media loaded. Declining
    /// still loads the episode and moves the queue.
    public func playPodcastQueueEpisodeNow(
        _ episodeID: ItemID, startsIf shouldStart: () -> Bool = { true }
    ) async throws {
        guard try await isEpisodeEligible(episodeID) else {
            recoverableFault = .podcastMediaUnavailable(episodeID)
            throw PlaybackControllerError.podcastMediaUnavailable(episodeID)
        }
        let state = try await store.podcastQueueState()
        if state.currentEpisodeID == episodeID {
            if itemID == episodeID, loadedIsPodcastEpisode {
                if !backend.isPlaying, shouldStart() { try play() }
            } else {
                try await loadQueuedEpisode(episodeID, playAfterLoad: true, startsIf: shouldStart)
            }
            podcastStateHandler?(episodeID, nil)
            return
        }

        // Persist the outgoing playhead before loading another episode. The
        // queue itself is not touched until the target media loads, so a
        // missing or unreadable target leaves its durable order and current
        // identity intact.
        if itemID == state.currentEpisodeID, currentRevision != nil {
            try await checkpoint()
        }
        try await loadQueuedEpisode(episodeID, playAfterLoad: true, startsIf: shouldStart)

        var episodeIDs = state.episodeIDs
        episodeIDs.removeAll { $0 == episodeID }
        if let current = state.currentEpisodeID,
           let currentIndex = episodeIDs.firstIndex(of: current) {
            // "Play Now" inserts at the current slot. The interrupted episode
            // remains immediately after it, so Next resumes what was playing
            // instead of sending it to the target's former queue position.
            episodeIDs.insert(episodeID, at: currentIndex)
        } else {
            episodeIDs.insert(episodeID, at: episodeIDs.startIndex)
        }
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: episodeIDs,
            currentEpisodeID: episodeID
        ))
        podcastStateHandler?(episodeID, nil)
    }

    /// Resolves the first eligible episode before `anchorID` (or current episode)
    /// by walking backward through the queued episode IDs.
    public func previousEligibleEpisodeID(before anchorID: ItemID? = nil) async throws -> ItemID? {
        let state = try await store.podcastQueueState()
        let activeID = anchorID ?? state.currentEpisodeID ?? itemID
        let endIndex: Int
        if let activeID, let idx = state.episodeIDs.firstIndex(of: activeID) {
            endIndex = idx
        } else if let currentIndex = state.currentIndex {
            endIndex = currentIndex
        } else {
            return nil
        }
        guard endIndex > state.episodeIDs.startIndex else { return nil }
        for candidate in state.episodeIDs[..<endIndex].reversed() {
            if try await isEpisodeEligible(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Selects the first eligible queue item before the current episode, if one exists.
    @discardableResult
    public func selectPreviousPodcastQueueEpisode(autoplay: Bool = true) async throws -> Bool {
        guard let previous = try await previousEligibleEpisodeID() else { return false }
        try await selectPodcastQueueEpisode(previous, autoplay: autoplay)
        return true
    }

    /// Whether an episode satisfies playback eligibility. If the store records
    /// a durable removal (retirement or dismissal), the episode is ineligible
    /// until restored. Otherwise, an external predicate is consulted if
    /// provided, or the store is checked for a ready revision and valid
    /// preparation outcome.
    public func isEpisodeEligible(_ episodeID: ItemID) async throws -> Bool {
        if try await store.retiredAt(for: episodeID) != nil {
            return false
        }
        if try await store.removalKind(for: episodeID) != nil {
            return false
        }
        if let episodeEligibilityPredicate {
            return await episodeEligibilityPredicate(episodeID)
        }
        guard let stored = try await store.readyRevision(for: episodeID) else {
            return false
        }
        if let outcome = try await store.preparationOutcome(for: episodeID, revisionID: stored.revision.revisionID) {
            return outcome.eligibility != .invalid
        }
        return false
    }

    /// Resolves the first eligible episode after `anchorID` (or current episode)
    /// by walking forward through the queued episode IDs.
    public func nextEligibleEpisodeID(after anchorID: ItemID? = nil) async throws -> ItemID? {
        let state = try await store.podcastQueueState()
        let activeID = anchorID ?? state.currentEpisodeID ?? itemID
        let startIndex: Int
        if let activeID, let idx = state.episodeIDs.firstIndex(of: activeID) {
            startIndex = state.episodeIDs.index(after: idx)
        } else if let currentIndex = state.currentIndex {
            startIndex = state.episodeIDs.index(after: currentIndex)
        } else {
            startIndex = state.episodeIDs.startIndex
        }
        guard startIndex < state.episodeIDs.endIndex else { return nil }
        for candidate in state.episodeIDs[startIndex...] {
            if try await isEpisodeEligible(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Selects the first eligible queue item after the current episode, if one exists.
    @discardableResult
    public func selectNextPodcastQueueEpisode(autoplay: Bool = true) async throws -> Bool {
        guard let next = try await nextEligibleEpisodeID() else { return false }
        let state = try await store.podcastQueueState()

        // Keep the outgoing checkpoint recoverable until the successor is
        // actually open. In particular, a playhead parked at the final frame
        // is still resumable when the successor cannot load; pressing Next is
        // not evidence that the outgoing episode was completed.
        if itemID == state.currentEpisodeID, currentRevision != nil {
            try await checkpoint(markCompletedAtEnd: false)
        }
        let completion = manualNextCompletionCandidate(currentQueueItem: state.currentEpisodeID)
        let skipped = manualNextSkip(currentQueueItem: state.currentEpisodeID)

        // Loading precedes both the durable queue move and the completion
        // write. A missing or corrupt successor therefore leaves the current
        // item, its queue identity, and its resumable checkpoint intact.
        try await loadQueuedEpisode(next, playAfterLoad: autoplay)
        if let skipped { recordManualNextSkip(skipped) }
        try await store.addPodcastQueueEpisode(next)
        try await store.setCurrentPodcastQueueEpisode(next)
        if let completion {
            try await persistManualNextCompletion(completion)
            podcastCompletionHandler?(completion.itemID)
        }
        podcastStateHandler?(next, nil)
        return true
    }

    public func setRate(_ value: Float) {
        if currentRevision != nil {
            stageSpeedInterval(endingAt: livePositionSeconds)
        }
        let rate = Self.clampRate(value)
        backend.rate = rate
        speedSavingsRate = Double(rate)
    }

    private static func clampRate(_ value: Float) -> Float {
        min(max(value.isFinite ? value : 1, 0.5), 2)
    }

    public func setVolume(_ value: Float) {
        backend.volume = min(max(value.isFinite ? value : 1, 0), 1)
    }

    /// Retires the loaded revision without playing the rest of it.
    ///
    /// Progress is written from where the audio actually is, so an episode the
    /// listener is finished with at 91% stays at 91% for good: nothing else
    /// writes the completed flag except audio reaching the end on its own. The
    /// same terminal checkpoint is written here, so a manually finished episode
    /// and a naturally finished one are the same durable record.
    ///
    /// Nothing advances. The queue moving on is what happens when audio ends
    /// while someone is listening; pressing this says they are done, not that
    /// they want the next thing. The backend's generation is marked handled for
    /// the same reason — its clock now sits at the end of the file, so a later
    /// resume would otherwise fire a natural completion and pull in the next
    /// episode unasked.
    public func markCompleted() async throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        backend.pause()
        isPlaying = false
        meterListening()
        completionHandledGeneration = loadedBackendGeneration
        recoverableFault = nil
        try await checkpointCompletedRevision(accountPlaybackToEnd: false)
    }

    /// Adopts a position another device saved for this exact revision (the Mac adopting the
    /// phone's), unless it is not newer than the stored one, the episode is finished here, or it
    /// is playing here. Never starts playback and never touches a playing episode.
    ///
    /// Not loaded: only the stored state changes, so a later load resumes there. Loaded and
    /// paused: the playhead and the checkpoint state move too, so the next checkpoint keeps the
    /// position instead of overwriting it. The stored state is stamped with when the other
    /// device saved it, which makes a repeat of the same request `.notNewer`.
    public func applyRemotePosition(_ request: RemotePositionRequest) async throws -> RemotePositionOutcome {
        func loadedHere() -> Bool { itemID == request.itemID && revisionID == request.revisionID }
        func playingHere() -> Bool { loadedHere() && (backend.isPlaying || isPlaying) }
        if playingHere() { return .playing }
        let persisted = try await store.playbackState(for: request.itemID, revisionID: request.revisionID)
        if playingHere() { return .playing }
        let duration = loadedHere() && durationSeconds > 0 ? durationSeconds : request.durationSeconds
        if let refusal = RemotePositionRules.refusal(
            persisted: persisted, positionSeconds: request.positionSeconds, durationSeconds: duration,
            observedAt: request.observedAt) { return refusal }
        let state = try RemotePositionRules.state(
            persisted: persisted, request: request, deviceID: deviceID, now: Date(), newSessionID: Self.newSessionID)
        try await store.save(playback: state)
        // Loaded (possibly while the write was in flight): bring the in-memory state to the stored one.
        if loadedHere(), !playingHere() {
            lastWritten = (state.sessionID, state.positionSeconds, false, state.intent, state.updatedAt.date)
            stageSpeedInterval(endingAt: livePositionSeconds)
            sessionID = state.sessionID
            sequence = state.sequence
            intent = state.intent
            completed = false
            positionSeconds = clamp(state.positionSeconds)
            backend.currentTime = positionSeconds
            speedSavingsBaselineSeconds = positionSeconds
            recoverableFault = nil
        }
        return .applied
    }

    private func handleBackendCompletion(generation: UInt64, successfully: Bool, holdAtEnd: UInt64) async {
        guard generation == loadedBackendGeneration,
              completionHandledGeneration != generation,
              let completedItemID = itemID else { return }
        completionHandledGeneration = generation
        if successfully {
            backend.pause()
            isPlaying = false
            meterListening()
            let completedIsPodcastEpisode = loadedIsPodcastEpisode
            do { try await checkpointCompletedRevision(accountPlaybackToEnd: true) }
            catch {
                guard generation == loadedBackendGeneration, itemID == completedItemID else { return }
                playbackDidFinishHandler?()
                return
            }
            if completedIsPodcastEpisode {
                podcastCompletionHandler?(completedItemID)
            }
            guard generation == loadedBackendGeneration, itemID == completedItemID else { return }
            let state = try? await store.podcastQueueState()
            guard generation == loadedBackendGeneration, itemID == completedItemID else { return }
            guard let state, state.currentEpisodeID == completedItemID else {
                // An article, or an episode played outside the queue. Nothing
                // advances, so this is the only notice that the audio stopped.
                playbackDidFinishHandler?()
                return
            }
            await advanceQueue(after: completedItemID, in: state, generation: generation, holdAtEnd: holdAtEnd)
        } else {
            // Both callback outcomes consume the same generation. Only an
            // explicit retry or reload can allow another completion.
            backend.pause()
            isPlaying = false
            meterListening()
            if let itemID { recoverableFault = .playbackFailed(itemID) }
            // Keep the interrupted playhead, including failure at the final
            // frame, without turning it into a completed revision. A store
            // failure must not suppress the playback fault or stop signal.
            try? await checkpoint()
            let state = try? await store.podcastQueueState()
            guard generation == loadedBackendGeneration,
                  completionHandledGeneration == generation,
                  itemID == completedItemID else { return }
            if state?.currentEpisodeID == completedItemID {
                podcastStateHandler?(completedItemID, .playbackFailed(completedItemID))
            }
            playbackDidFinishHandler?()
        }
    }

    /// Immutable details of an outgoing podcast eligible for manual-Next
    /// completion. The controller captures these before loading a successor,
    /// because the successor replaces the mutable current-revision fields.
    private struct ManualNextCompletion {
        let itemID: ItemID
        let revisionID: RevisionID
        let sessionID: String
        let sequence: Int64
        let durationSeconds: TimeInterval
        let intent: PlaybackIntent
    }

    /// A manual Next completes only a loaded current podcast whose *live*
    /// playhead has reached the owner-selected 95% threshold. Saved row
    /// position is intentionally not consulted here.
    private func manualNextCompletionCandidate(currentQueueItem: ItemID?) -> ManualNextCompletion? {
        guard loadedIsPodcastEpisode, currentRevision != nil,
              let itemID, let revisionID, let sessionID,
              itemID == currentQueueItem,
              durationSeconds.isFinite, durationSeconds > 0,
              livePositionSeconds >= durationSeconds * 0.95 else { return nil }
        return ManualNextCompletion(
            itemID: itemID, revisionID: revisionID, sessionID: sessionID,
            sequence: sequence, durationSeconds: durationSeconds, intent: intent
        )
    }

    /// Persists the terminal playback and listening records only after the
    /// successor has loaded and become the queue's durable current item.
    private func persistManualNextCompletion(_ completion: ManualNextCompletion) async throws {
        let now = Timestamp(Date())
        let playbackState = try PlaybackState(
            itemID: completion.itemID, revisionID: completion.revisionID,
            sessionID: completion.sessionID, sequence: max(1, completion.sequence + 1),
            positionSeconds: completion.durationSeconds, durationSeconds: completion.durationSeconds,
            completed: true, intent: completion.intent, deviceID: deviceID, updatedAt: now
        )
        try await store.save(playback: playbackState, listening: PodcastListeningState(
            episodeID: completion.itemID, completedAt: now,
            lastRevisionID: completion.revisionID, updatedAt: now
        ))
    }

    func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value.isFinite ? value : 0, 0), max(durationSeconds, 0))
    }

    static func newSessionID() -> String {
        "session-\(UUID().uuidString.lowercased())"
    }
}
