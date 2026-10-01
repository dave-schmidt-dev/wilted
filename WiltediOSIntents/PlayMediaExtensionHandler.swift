@preconcurrency import Intents

/// Resolves and confirms a "play ..." request in the extension and hands it to the app. An extension's
/// lifespan is short and it cannot see the downloaded episodes, so it never plays or matches anything:
/// the app decides which downloaded episode is meant (`PlayMediaIntentHandler`) and plays it through the
/// shared player, started in the background by `.handleInApp` (Apple: media playback belongs in the app).
final class PlayMediaExtensionHandler: NSObject, INPlayMediaIntentHandling {
    /// What Siri already chose, kept as is; nil when nothing was chosen and the app must match the search.
    static func chosenItems(for intent: INPlayMediaIntent) -> [INMediaItem]? {
        guard let items = intent.mediaItems, !items.isEmpty else { return nil }
        return items
    }

    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        guard let items = Self.chosenItems(for: intent) else { return [.notRequired()] }
        return items.map { .success(with: $0) }
    }

    func confirm(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        INPlayMediaIntentResponse(code: .ready, userActivity: nil)
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil)
    }
}
