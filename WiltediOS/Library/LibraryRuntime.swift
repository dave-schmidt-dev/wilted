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
    private var prepareTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: LibraryAppModel, player: LibraryPlayer, settings: LibrarySettingsStore) {
        self.model = model
        self.player = player
        self.settings = settings
    }

    /// The production stack: CloudKit-backed model, real audio engine, `UserDefaults` settings.
    static func live() -> LibraryRuntime {
        LibraryRuntime(model: LibraryEnvironment.makeModel(), player: .live(), settings: LibrarySettingsStore())
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
        model.attachPlayer(player)
        let model = model
        LibraryPushHandler.shared.attach { await model.handleSilentPush() }
        player.apply(settings.playback)
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self.map { $0.player.apply($0.settings.playback) } }
            }
            .store(in: &subscriptions)
        // Removing the file from the phone must not leave its audio playing.
        model.$media
            .receive(on: DispatchQueue.main)
            .sink { [weak self] media in
                MainActor.assumeIsolated {
                    guard let player = self?.player, let playing = player.item else { return }
                    if media[playing.entryID] != .onPhone { player.stop() }
                }
            }
            .store(in: &subscriptions)
        await model.loadLocalState()
    }
}
