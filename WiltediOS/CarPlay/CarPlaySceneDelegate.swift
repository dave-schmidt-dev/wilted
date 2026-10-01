import CarPlay
import Combine
import UIKit

/// The car screen: one list of episodes already on this iPhone, plus the system's Now Playing
/// template. The car offers listening only, so nothing here downloads, manages or configures
/// anything, and the audio session is never touched: the player activates it when playback
/// starts, because activating at launch would stop the car's radio.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var listTemplate: CPListTemplate?
    private var model: LibraryAppModel?
    private var player: LibraryPlayer?
    private var subscriptions = Set<AnyCancellable>()

    // MARK: CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let runtime = LibraryRuntime.shared
        model = runtime.model
        player = runtime.player
        self.interfaceController = interfaceController

        let list = CPListTemplate(
            title: "Episodes", sections: [], assistantCellConfiguration: CarPlaySiri.assistantCellConfiguration())
        listTemplate = list
        configureNowPlayingButtons()
        interfaceController.setRootTemplate(list, animated: false, completion: nil)
        observeChanges()
        render()

        Task { await runtime.start() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        listTemplate = nil
        model = nil
        player = nil
        subscriptions.removeAll()
    }

    // MARK: Episode list

    /// Rebuilds the list from the model as it stands. The template stays the root; only its
    /// sections and empty-view text change.
    private func render() {
        guard let template = listTemplate, let model, let player else { return }
        let list = CarEpisodeList.make(
            model: model, playingID: player.item?.entryID, limit: max(1, CPListTemplate.maximumItemCount))
        switch list.content {
        case let .episodes(rows):
            template.emptyViewTitleVariants = []
            template.updateSections([CPListSection(items: rows.map(listItem))])
        case let .empty(message):
            template.emptyViewTitleVariants = [message]
            template.updateSections([])
        }
    }

    private func listItem(for row: CarEpisodeRow) -> CPListItem {
        let item = CPListItem(text: row.title, detailText: row.detail)
        item.isPlaying = row.isPlaying
        item.handler = { [weak self] _, completion in
            // CarPlay calls item handlers on the main thread; the runtime is main-actor isolated.
            MainActor.assumeIsolated {
                guard let self else { completion(); return }
                Task { await self.play(row, then: completion) }
            }
        }
        return item
    }

    /// Starts the episode, shows Now Playing, and always ends the item's spinner.
    private func play(_ row: CarEpisodeRow, then completion: @escaping () -> Void) async {
        await model?.playCached(row.row)
        showNowPlaying()
        completion()
    }

    private func observeChanges() {
        guard let model, let player else { return }
        let changes: [AnyPublisher<Void, Never>] = [
            model.$queued.map { _ in () }.eraseToAnyPublisher(),
            model.$media.map { _ in () }.eraseToAnyPublisher(),
            model.$sort.map { _ in () }.eraseToAnyPublisher(),
            model.$lastSynchronizedAt.map { _ in () }.eraseToAnyPublisher(),
            model.$isRefreshing.map { _ in () }.eraseToAnyPublisher(),
            player.$item.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.render() } }
            .store(in: &subscriptions)
    }

    // MARK: Now Playing

    private func configureNowPlayingButtons() {
        let rateButton = CPNowPlayingPlaybackRateButton { [weak self] _ in
            // CarPlay calls button handlers on the main thread.
            MainActor.assumeIsolated { self?.advanceRate() }
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([rateButton])
    }

    /// Steps to the next offered speed, wrapping from the fastest back to the slowest.
    private func advanceRate() {
        guard let player else { return }
        let rates = LibraryPlayer.rates
        let index = rates.firstIndex(of: player.rate) ?? 0
        player.setRate(rates[(index + 1) % rates.count])
    }

    /// Pushes Now Playing unless it is already on top, keeping the stack at list + Now Playing.
    private func showNowPlaying() {
        guard let interfaceController,
              interfaceController.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
