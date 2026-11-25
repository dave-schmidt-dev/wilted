import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedWeather

extension LibraryInterruptionController {
    /// The production stack for the phone player, this phone's location and the synced transcripts.
    static func live(player: LibraryPlayer, model: LibraryAppModel) -> LibraryInterruptionController {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let transport = model.transport
        return LibraryInterruptionController(
            player: player,
            dependencies: Dependencies(
                speaker: LibraryBulletinAudioSpeaker(model: model),
                previewSpeaker: LibraryBulletinAudioSpeaker(model: model),
                playingPreviewSpeaker: LibraryBulletinAudioSpeaker(model: model),
                fetchBulletins: { try await transport.fetchBulletins() },
                makeMonitor: { deliver in
                    AlertMonitor(
                        source: NWSClient(appVersion: version, repositoryURL: "https://github.com/dave-schmidt-dev/wilted"),
                        deliver: deliver)
                },
                location: LibraryLocationProvider(manager: LibraryCoreLocationManager()),
                adBreakSeams: { [weak model] entryID, revisionID in
                    guard let transcript = model?.transcript(for: entryID), transcript.revisionID == revisionID else {
                        return []
                    }
                    return transcript.cuts?.map(\.preparedSeconds) ?? []
                },
                prepareAdBreaks: { [weak model] entryID in
                    await model?.prepareTranscript(entryID: entryID)
                },
                revision: { [weak model] in await model?.mediaCache.cachedEntries()[$0]?.revisionID },
                now: { [weak model] in model?.now() ?? Date() },
                isForeground: { [weak model] in model?.tickState.sceneActive ?? false }))
    }
}
