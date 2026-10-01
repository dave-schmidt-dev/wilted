import AppIntents
import Combine
import Foundation

/// Tells Siri when the Larder's set of show and episode titles changes, so a newly added show or
/// episode can be spoken in a phrase that names it. Siri is told only when the set differs from the
/// last one it was told, and never for an empty first state.
@MainActor
final class ShortcutParameterRefresher {
    private var known: Set<String>?
    private let update: @MainActor () -> Void

    init(update: @escaping @MainActor () -> Void = { WiltedShortcuts.updateAppShortcutParameters() }) {
        self.update = update
    }

    func names(changedTo titles: [String]) {
        let set = Set(titles.filter { !$0.isEmpty }.map { $0.lowercased() })
        guard set != known else { return }
        let wasUnknown = known == nil
        known = set
        if wasUnknown && set.isEmpty { return }
        update()
    }

    /// Watches the model's queued rows for the life of the returned subscription.
    static func observe(_ model: LibraryAppModel, refresher: ShortcutParameterRefresher = ShortcutParameterRefresher()) -> AnyCancellable {
        // Show titles for every queued row, episode titles only for the ones on the phone (what Siri
        // can play), so downloading or removing an episode refreshes the phrases too.
        model.$queued.combineLatest(model.$media)
            .map { rows, media in rows.flatMap { media[$0.id] == .onPhone ? [$0.showTitle, $0.title] : [$0.showTitle] } }.sink { titles in
            MainActor.assumeIsolated { refresher.names(changedTo: titles) }
        }
    }
}
