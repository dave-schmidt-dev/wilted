import Foundation
@preconcurrency import Intents
import WiltedDomain
import WiltedLibrary

/// Maps what Siri understood of a "play ..." request onto voice-layer commands, in the order to
/// try them. Pure, so it is tested without Siri; the matching itself stays in `VoiceCommandPlanner`.
enum PlayMediaRequest {
    static func commands(for search: INMediaSearch?) -> [VoiceCommand] {
        let name = clean(search?.mediaName)
        let showHint = clean(search?.artistName) ?? clean(search?.albumName)
        let newest = search?.sortOrder == .newest
        func show(_ title: String?) -> VoiceCommand { newest ? .playLatest(show: title) : .playNext(show: title) }

        guard let name else { return [show(showHint)] }
        switch search?.mediaType {
        case .podcastShow?, .podcastPlaylist?: return [show(name)]
        case .podcastEpisode?: return [.playEpisode(title: name, show: showHint)]
        default:
            // The car often gives only a name: an episode title if one matches, else a show.
            return [.playEpisode(title: name, show: showHint), show(name)]
        }
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Picks and plays downloaded episodes for SiriKit media requests. Everything is decided by the
/// same planner and runtime the App Intents use, so a request can only ever play an episode that
/// is already on the phone, through the shared player, after an offline `prepare()`.
@MainActor
enum PlayMediaCore {
    /// The first episode any of `commands` resolves to.
    static func episode(for commands: [VoiceCommand]) async -> VoiceEpisode? {
        guard let target = await VoiceRuntime.target() else { return nil }
        let snapshot = await target.voiceSnapshot()
        for command in commands {
            if case let .play(id) = VoiceCommandPlanner.plan(command, snapshot: snapshot).action {
                return snapshot.downloaded.first { $0.id == id }
            }
        }
        return nil
    }

    /// The downloaded episode Siri already chose (an identifier from an earlier resolution), if it is
    /// still on the phone.
    static func episode(withIdentifier raw: String?) async -> VoiceEpisode? {
        guard let raw, let id = try? ItemID(rawValue: raw), let target = await VoiceRuntime.target() else { return nil }
        return await target.voiceSnapshot().downloaded.first { $0.id == id }
    }

    static func play(_ id: ItemID) async -> Bool {
        guard let target = await VoiceRuntime.target() else { return false }
        return await target.perform(.play(id)) == .done
    }
}

/// Plays what an `INPlayMediaIntent` asks for, inside the app: the Intents extension answers `.handleInApp`
/// and the app delegate calls this (also returned from `application(_:handlerFor:)` for in-app handling).
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    /// The episode a request resolves to: the one Siri already chose if still downloaded, else the best
    /// match for the search.
    static func resolvedEpisode(for intent: INPlayMediaIntent) async -> VoiceEpisode? {
        if let chosen = await PlayMediaCore.episode(withIdentifier: intent.mediaItems?.first?.identifier) { return chosen }
        return await PlayMediaCore.episode(for: PlayMediaRequest.commands(for: intent.mediaSearch))
    }

    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        guard let episode = await Self.resolvedEpisode(for: intent) else { return [.unsupported()] }
        let item = INMediaItem(
            identifier: episode.id.rawValue, title: episode.title, type: .podcastEpisode, artwork: nil,
            artist: episode.showTitle)
        return [.success(with: item)]
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        var id = intent.mediaItems?.first?.identifier.flatMap { try? ItemID(rawValue: $0) }
        if id == nil {
            id = await PlayMediaCore.episode(for: PlayMediaRequest.commands(for: intent.mediaSearch))?.id
        }
        guard let id, await PlayMediaCore.play(id) else {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }
        return INPlayMediaIntentResponse(code: .success, userActivity: nil)
    }
}
