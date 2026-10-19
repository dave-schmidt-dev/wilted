import Combine
import Foundation

/// The library model, the player and the settings, built once per process and reachable without
/// any iPhone window scene. The phone's `LibraryRoot`, a CarPlay scene and Siri intents all use
/// `LibraryRuntime.shared`, so there is one model, one transport and one `AVAudioSession` owner.
///
/// Nothing here is built until `shared` is first read, so a legacy-fixture launch and unit tests
/// never create the live stack. Tests replace `shared` (or build their own runtime) with fakes.
@MainActor
final class LibraryRuntime {
    /// The process-wide runtime, built lazily from the live environment.
    static var shared = LibraryRuntime.live()

    let model: LibraryAppModel
    let player: LibraryPlayer
    let settings: LibrarySettingsStore
    private let artwork: LibraryArtworkCache?
    private let watchSession: (any WatchSessionProtocol)?
    private let pushHandler: any LibraryPushHandling
    private var watchBridge: WatchBridge?
    private var watchBuffer: WatchSessionBackgroundBuffer?
    private var prepareTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var pushHandlerAttached = false
    private var backgroundEntryPointsStarted = false

    init(
        model: LibraryAppModel, player: LibraryPlayer, settings: LibrarySettingsStore,
        artwork: LibraryArtworkCache? = nil, watchSession: (any WatchSessionProtocol)? = nil,
        pushHandler: any LibraryPushHandling = LibraryPushHandler.shared
    ) {
        self.artwork = artwork
        self.watchSession = watchSession.map { WatchSessionActivationGate($0) as (any WatchSessionProtocol) }
        self.pushHandler = pushHandler
        self.model = model
        self.player = player
        self.settings = settings
    }

    /// The production stack: CloudKit-backed model, real audio engine, `UserDefaults` settings, and
    /// the system Watch session.
    static func live() -> LibraryRuntime {
        LibraryRuntime(
            model: LibraryEnvironment.makeModel(), player: .live(), settings: LibrarySettingsStore(),
            artwork: .shared, watchSession: WatchSession())
    }

    /// Wires the entry points a launch with no scene still needs: the silent-push handler, the system
    /// transport commands (a car or Bluetooth play command relaunches a killed app in the background and
    /// is dropped unless a handler is registered by then) and an activated Watch session whose delegate
    /// holds Watch traffic until the bridge starts. A silent push then awaits `prepare()` and handles
    /// the push, a play command resumes after `prepare()`, and a Watch message is buffered until
    /// `prepare()` replays it. Nothing here loads local state, syncs or touches audio, and repeated
    /// calls do nothing.
    func bootstrapBackgroundEntryPoints() {
        guard !backgroundEntryPointsStarted else { return }
        backgroundEntryPointsStarted = true
        installRemoteCommands()
        attachPushHandler()
        guard watchBridge == nil, let watchSession, watchSession.isSupported else { return }
        let buffer = WatchSessionBackgroundBuffer()
        watchBuffer = buffer
        watchSession.delegate = buffer
        watchSession.activate()
    }

    /// Wires the player to the model and the settings and loads what is already on the phone, with no
    /// network call, so a scene or an intent can list and play downloaded episodes at once. Safe to
    /// call from every entry point; the work happens once and later callers wait for it.
    func prepare() async {
        if prepareTask == nil { prepareTask = Task { await performPrepare() } }
        await prepareTask?.value
    }

    /// `prepare()`, then the first sync. The sync can be slow or fail with no signal, so anything that
    /// must act on downloaded episodes (playing one) awaits `prepare()`, not this.
    func start() async {
        if startTask == nil { startTask = Task { await prepare(); await model.start() } }
        await startTask?.value
    }

    private func performPrepare() async {
        installRemoteCommands()
        model.attachPlayer(player)
        player.authorizePlayback = { [weak model] item in
            guard let model else { return false }
            let token = model.beginExternalStart()
            guard let cached = await model.verifiedCachedMedia(item.entryID, token: token) else { return false }
            return cached.url == item.fileURL
        }
        let model = model
        attachPushHandler()
        player.apply(settings.playback)
        ShortcutParameterRefresher.observe(model).store(in: &subscriptions)
        subscriptions.insert(SpotlightIndexer.observe(model))
        IntentDonor.shared.observe(model, player).forEach { subscriptions.insert($0) }
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self.map { $0.player.apply($0.settings.playback) } }
            }
            .store(in: &subscriptions)
        // Published emits before storage changes. Use both emitted full-library values
        // synchronously so queue/media removal clears Now Playing before a remote resume.
        model.$queued.combineLatest(model.$media)
            .sink { [weak self] queued, media in
                MainActor.assumeIsolated {
                    guard let player = self?.player, let playing = player.item else { return }
                    if !queued.contains(where: { $0.id == playing.entryID }) || media[playing.entryID] != .onPhone {
                        player.invalidateLoadedItem()
                    }
                }
            }
            .store(in: &subscriptions)
        await model.loadLocalState()
        keepArtworkCached()
        startWatchBridge()
    }

    /// Installs this runtime's one silent-push fetch. It waits for `prepare()`, so a push that
    /// arrives before any scene still runs against the loaded library.
    private func attachPushHandler() {
        guard !pushHandlerAttached else { return }
        pushHandlerAttached = true
        pushHandler.attach { [weak self] in
            guard let self else { return false }
            await self.prepare()
            return await self.model.handleSilentPush()
        }
    }

    /// Starts the Watch bridge after the runtime has prepared. The bridge never blocks or fails
    /// prepare: it does nothing when the system does not support watch sessions or when this
    /// runtime was built without a session (tests, previews).
    private func startWatchBridge() {
        guard let watchSession, watchBridge == nil else { return }
        guard watchSession.isSupported else {
            watchBuffer?.rejectPending()
            watchBuffer = nil
            return
        }
        let bridge = WatchBridge(
            session: watchSession,
            target: LibraryVoiceTarget(model: model, player: player, settings: settings),
            source: LibraryWatchSource(model: model, player: player))
        watchBridge = bridge
        bridge.start()
        watchBuffer?.flush(to: bridge)
        watchBuffer = nil
    }

    /// Downloads artwork for the episodes on the phone while the app has a connection, so the car and
    /// the lock screen can show it from disk later. Runs on the app's own schedule, never on a car path.
    private func keepArtworkCached() {
        guard let artwork else { return }
        let model = model
        let onPhoneArtwork: @MainActor () -> [URL] = {
            let onPhone = model.preparedIDs.onPhone
            return model.queued.filter { onPhone.contains($0.id) }.flatMap { [$0.artworkURL, $0.showArtworkURL].compactMap { $0 } }
        }
        var running: Task<Void, Never>?
        Publishers.Merge3(
            model.$media.map { _ in () }, model.$queued.map { _ in () }, model.$lastSynchronizedAt.map { _ in () })
            .receive(on: DispatchQueue.main)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    running?.cancel()
                    let urls = onPhoneArtwork().filter { !artwork.isCached($0) }
                    // Artwork for episodes that left the queue goes; an empty queue (nothing loaded yet) prunes nothing.
                    let keep = model.queued.flatMap { [$0.artworkURL, $0.showArtworkURL].compactMap { $0 } }
                    running = Task {
                        if !urls.isEmpty { await artwork.prefetch(urls) }
                        if !keep.isEmpty { artwork.prune(keeping: keep) }
                    }
                }
            }
            .store(in: &subscriptions)
    }
}
