import CarPlay
import Combine
import UIKit

/// The car screen: a tab bar with the episodes already on this iPhone (Downloaded) and one row per
/// show (Shows, each opening that show's episodes), plus the system's Now Playing template, which the
/// system reaches from a button on every screen. The car offers listening only, so nothing here downloads, manages or configures
/// anything, and the audio session is never touched: the player activates it when playback
/// starts, because activating at launch would stop the car's radio.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {
    private var interfaceController: CPInterfaceController?
    private var listTemplate: CPListTemplate?
    private var showsTemplate: CPListTemplate?
    /// The show whose episodes are open, if any, and its list.
    private var showTemplate: CPListTemplate?
    private var openShowTitle: String?
    private var model: LibraryAppModel?
    private var player: LibraryPlayer?
    private var subscriptions = Set<AnyCancellable>()
    /// The rows drawn now, by artwork address, so an image that arrives later lands on its row.
    private var artworkItems: [URL: [CPListItem]] = [:]

    // MARK: CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let runtime = LibraryRuntime.shared
        model = runtime.model
        player = runtime.player
        self.interfaceController = interfaceController
        interfaceController.delegate = self

        let list = CPListTemplate(title: "Episodes", sections: [])
        list.tabTitle = "Downloaded"
        list.tabImage = UIImage(systemName: "arrow.down.circle")
        listTemplate = list
        // Two tabs, so well inside the car's limit; a car that allows fewer gets the single list.
        var root: CPTemplate = list
        if CPTabBarTemplate.maximumTabCount >= 2 {
            let shows = CPListTemplate(title: "Shows", sections: [])
            shows.tabTitle = "Shows"
            shows.tabImage = UIImage(systemName: "square.stack")
            showsTemplate = shows
            root = CPTabBarTemplate(templates: [list, shows])
        }
        configureNowPlayingButtons()
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
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
        showsTemplate = nil
        showTemplate = nil
        openShowTitle = nil
        model = nil
        player = nil
        subscriptions.removeAll()
    }

    // MARK: Episode list

    /// Rebuilds every list from the model as it stands. The templates stay in place; only their
    /// sections and empty-view text change.
    private func render() {
        guard let template = listTemplate, let model, let player else { return }
        artworkItems = [:]
        defer { for url in artworkItems.keys { loadArtwork(url) } }
        let limit = max(1, CPListTemplate.maximumItemCount)
        let list = CarEpisodeList.make(model: model, playingID: player.item?.entryID, limit: limit)
        apply(list, to: template)
        renderShows(model: model, limit: limit)
        renderOpenShow(model: model, player: player, limit: limit)
    }

    private func apply(_ list: CarEpisodeList, to template: CPListTemplate) {
        switch list.content {
        case let .episodes(rows):
            template.emptyViewTitleVariants = []
            template.updateSections([CPListSection(items: rows.map(listItem))])
        case let .empty(message):
            template.emptyViewTitleVariants = [message]
            template.updateSections([])
        }
    }

    private func renderShows(model: LibraryAppModel, limit: Int) {
        guard let template = showsTemplate else { return }
        let shows = CarShowList.make(
            rows: model.queued, onPhone: model.preparedIDs.onPhone, progress: model.progress,
            finished: model.finished, limit: limit)
        guard !shows.isEmpty else {
            template.emptyViewTitleVariants = [CarShowList.emptyMessage]
            template.updateSections([])
            return
        }
        template.emptyViewTitleVariants = []
        template.updateSections([CPListSection(items: shows.map(showItem))])
    }

    /// Keeps an open show's list current; closes it when the show has nothing left on the phone.
    private func renderOpenShow(model: LibraryAppModel, player: LibraryPlayer, limit: Int) {
        guard let template = showTemplate, let title = openShowTitle else { return }
        let list = CarShowList.episodes(
            of: title, rows: model.queued, onPhone: model.preparedIDs.onPhone,
            playingID: player.item?.entryID, progress: model.progress,
            finished: model.finished, limit: limit)
        apply(list, to: template)
        if case .empty = list.content, interfaceController?.topTemplate === template {
            interfaceController?.popTemplate(animated: true, completion: nil)
            showTemplate = nil
            openShowTitle = nil
        }
    }

    private func showItem(for show: CarShowRow) -> CPListItem {
        let item = CPListItem(text: show.title, detailText: show.detail)
        item.accessoryType = .disclosureIndicator
        if let url = show.artworkURL {
            artworkItems[url, default: []].append(item)
            if let data = LibraryArtworkCache.shared.loadedData(for: url), let image = UIImage(data: data) { item.setImage(image) }
        }
        item.handler = { [weak self] _, completion in
            MainActor.assumeIsolated {
                self?.openShow(show.title)
                completion()
            }
        }
        return item
    }

    /// Pushes the show's episodes: tab bar, then this list, then Now Playing, three deep at most.
    private func openShow(_ title: String) {
        guard let interfaceController, let model, let player else { return }
        // Replace, never stack, a list of another show that is still open.
        if let existing = showTemplate, interfaceController.topTemplate === existing {
            interfaceController.popTemplate(animated: false, completion: nil)
        }
        let template = CPListTemplate(title: title, sections: [])
        showTemplate = template
        openShowTitle = title
        renderOpenShow(model: model, player: player, limit: max(1, CPListTemplate.maximumItemCount))
        for url in artworkItems.keys { loadArtwork(url) }
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func listItem(for row: CarEpisodeRow) -> CPListItem {
        let item = CPListItem(text: row.title, detailText: Self.commandDetail(model?.playbackCommand, for: row) ?? row.detail)
        item.isPlaying = row.isPlaying
        if let fraction = row.listenedFraction { item.playbackProgress = CGFloat(fraction) }
        // Local cache only, and never a disk read here: what is already in memory shows at once, the
        // rest is read in the background and set when ready. A miss shows no image.
        if let url = row.row.artworkURL {
            artworkItems[url, default: []].append(item)
            if let data = LibraryArtworkCache.shared.loadedData(for: url), let image = UIImage(data: data) { item.setImage(image) }
        }
        item.handler = { [weak self] _, completion in
            // CarPlay calls item handlers on the main thread; the runtime is main-actor isolated.
            MainActor.assumeIsolated {
                guard let self else { completion(); return }
                Task { await self.select(row, then: completion) }
            }
        }
        return item
    }

    /// An explicit play of the row, never a toggle: a paused current row resumes, a playing one keeps
    /// playing. Now Playing opens only when the episode plays, a failure shows on the row (selecting
    /// it again retries), and the item's spinner ends exactly once whatever happened.
    private func select(_ row: CarEpisodeRow, then completion: @escaping () -> Void) async {
        await CarRowSelection.run(
            row.row, model: model, openNowPlaying: { showNowPlaying() },
            presentFailure: { _ in render() }, completion: completion)
    }

    /// The shared start state for this row: pending, or the failure with how to retry. Audio apps get
    /// list and Now Playing templates only, so the row carries it. The words match the phone's, except
    /// that nothing asks the driver to act on the phone: missing audio only says it is not here.
    static func commandDetail(_ command: LibraryPlaybackCommandStatus?, for row: CarEpisodeRow) -> String? {
        guard let command, command.entryID == row.id else { return nil }
        guard case let .failed(_, _, failure) = command else { return command.text }
        if failure == .missingMedia { return "Audio isn't on this iPhone." }
        return "\(command.text) Select to retry."
    }

    /// Reads `url`'s cached image off the main actor and sets it on the rows showing it.
    private func loadArtwork(_ url: URL) {
        let cache = LibraryArtworkCache.shared
        Task.detached(priority: .utility) { [weak self] in
            guard let data = cache.data(for: url) else { return }
            await MainActor.run {
                guard let self, let image = UIImage(data: data) else { return }
                for item in self.artworkItems[url] ?? [] { item.setImage(image) }
            }
        }
    }

    private func observeChanges() {
        guard let model, let player else { return }
        NotificationCenter.default.publisher(for: LibraryArtworkCache.didCache)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                MainActor.assumeIsolated { if let url = note.object as? URL { self?.loadArtwork(url) } }
            }
            .store(in: &subscriptions)
        let changes: [AnyPublisher<Void, Never>] = [
            model.$queued.map { _ in () }.eraseToAnyPublisher(),
            model.$media.map { _ in () }.eraseToAnyPublisher(),
            model.$progress.map { _ in () }.eraseToAnyPublisher(),
            model.$finished.map { _ in () }.eraseToAnyPublisher(),
            model.$lastSynchronizedAt.map { _ in () }.eraseToAnyPublisher(),
            model.$isRefreshing.map { _ in () }.eraseToAnyPublisher(),
            player.$item.map { _ in () }.eraseToAnyPublisher(),
            model.$playbackCommand.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.render() } }
            .store(in: &subscriptions)
    }

    // MARK: CPInterfaceControllerDelegate

    /// Forgets the open show once the driver has gone back out of it. Now Playing pushed on top also
    /// hides the list, but the list is still on the stack then, and stays current.
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        guard aTemplate === showTemplate,
              interfaceController?.templates.contains(where: { $0 === aTemplate }) != true else { return }
        showTemplate = nil
        openShowTitle = nil
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
        player.setRate(LibraryPlayer.nextRate(after: player.rate))
    }

    /// Pushes Now Playing unless it is already on top, keeping the stack at list + Now Playing.
    private func showNowPlaying() {
        guard let interfaceController,
              interfaceController.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
