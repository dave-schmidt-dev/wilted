import Foundation
import WiltedLibrary
import WiltedProducer

#if canImport(WiltedProducer)

@MainActor
final class WiltedMacWeatherAlertNarration {
    typealias RenderOperation = WiltedMacHeadlineBulletinSpeaker.ShortTextNarration

    private struct Asset {
        let bulletin: Bulletin
        let voiceID: ApprovedReadingVoiceID
        let voiceRevision: String
        let url: URL
    }

    private struct Failed {
        let bulletin: Bulletin
        let voiceID: ApprovedReadingVoiceID
    }

    private let render: RenderOperation
    private let availability: @MainActor (ApprovedReadingVoiceID) -> ArticleVoiceAvailability
    private let now: @Sendable () -> Date
    private let directory: URL
    private var renderTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var expiryGeneration: UInt64 = 0
    private var activeID: String?
    private var activeBulletin: Bulletin?
    private var activeOutputURL: URL?
    private var enabled = false
    private var voiceID: ApprovedReadingVoiceID?
    private var current: [String: Bulletin] = [:]
    private var queue: [String] = []
    private var assets: [String: Asset] = [:]
    private var failed: [String: Failed] = [:]
    var onReady: (@MainActor (Bulletin) -> Void)?
    var onChanged: (@MainActor () -> Void)?

    init(
        render: @escaping RenderOperation = { text, voiceID, outputURL in
            try await ArticleNarrationCoordinator().synthesizeShortText(
                text, voiceID: voiceID, outputURL: outputURL)
        },
        availability: @escaping @MainActor (ApprovedReadingVoiceID) -> ArticleVoiceAvailability = {
            ArticleNarrationCoordinator().availability(for: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        directory: URL = FileManager.default.temporaryDirectory
            .appending(path: "wilted-weather-alert-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
    ) {
        self.render = render
        self.availability = availability
        self.now = now
        self.directory = directory
    }

    func update(current alerts: [Bulletin], enabled: Bool, selectedVoice: ApprovedReadingVoiceID?) {
        let time = now()
        let previous = current
        let incoming = enabled
            ? Dictionary(alerts.filter { $0.kind == .alert && $0.expiresAt > time }
                .map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            : [:]
        let voiceChanged = selectedVoice != voiceID
        let enabledChanged = enabled != self.enabled
        self.enabled = enabled
        voiceID = selectedVoice
        current = incoming

        if !enabled || voiceChanged || enabledChanged {
            cancelRender(requeue: false)
            removeAssets()
            failed.removeAll()
            queue.removeAll()
        } else {
            for id in Array(assets.keys) where incoming[id] != assets[id]?.bulletin {
                removeAsset(id)
            }
            for id in Array(failed.keys) where incoming[id] != failed[id]?.bulletin
                || failed[id]?.voiceID != selectedVoice {
                failed.removeValue(forKey: id)
            }
            queue.removeAll { incoming[$0] == nil || assets[$0] != nil || failed[$0] != nil }
            if let activeID, incoming[activeID] != activeBulletin {
                cancelRender(requeue: false)
            }
        }

        guard enabled, selectedVoice != nil else {
            scheduleExpiry()
            if previous != incoming { onChanged?() }
            return
        }

        for bulletin in incoming.values where assets[bulletin.id] == nil && failed[bulletin.id] == nil
            && bulletin.id != activeID && !queue.contains(bulletin.id) {
            queue.append(bulletin.id)
        }
        sortQueue()
        if let activeID, let active = activeBulletin, let next = queue.first,
           let higher = incoming[next], higher.severity > active.severity {
            cancelRender(requeue: true)
            sortQueue()
        }
        scheduleExpiry()
        startNextIfPossible()
        if previous != incoming { onChanged?() }
    }

    var readyBulletins: [Bulletin] {
        current.values.filter { audioURL(for: $0) != nil }.sorted(by: Self.priorityOrder)
    }

    func audioURL(for bulletin: Bulletin) -> URL? {
        guard enabled, voiceID != nil, current[bulletin.id] == bulletin,
              bulletin.expiresAt > now(), let voiceID, let asset = assets[bulletin.id],
              asset.bulletin == bulletin, asset.voiceID == voiceID,
              asset.voiceRevision == ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID) else {
            return nil
        }
        return asset.url
    }

    func shutdown() {
        enabled = false
        current.removeAll()
        queue.removeAll()
        expiryGeneration &+= 1
        expiryTask?.cancel()
        expiryTask = nil
        cancelRender(requeue: false)
        removeAssets()
        failed.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func scheduleExpiry() {
        expiryGeneration &+= 1
        expiryTask?.cancel()
        expiryTask = nil
        guard enabled, let expiresAt = current.values.map(\.expiresAt).min() else { return }
        let token = expiryGeneration
        let delay = max(0.01, expiresAt.timeIntervalSince(now()))
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.expiryGeneration == token else { return }
            self.expiryTask = nil
            self.update(current: Array(self.current.values), enabled: self.enabled, selectedVoice: self.voiceID)
        }
    }

    private func sortQueue() {
        queue.sort { leftID, rightID in
            guard let left = current[leftID], let right = current[rightID] else { return leftID < rightID }
            return Self.priorityOrder(left, right)
        }
    }

    private static func priorityOrder(_ left: Bulletin, _ right: Bulletin) -> Bool {
        if left.severity != right.severity { return left.severity > right.severity }
        if left.issuedAt != right.issuedAt { return left.issuedAt < right.issuedAt }
        return left.id < right.id
    }

    private func cancelRender(requeue: Bool) {
        guard let activeID else { return }
        generation &+= 1
        renderTask?.cancel()
        renderTask = nil
        if let activeOutputURL { try? FileManager.default.removeItem(at: activeOutputURL) }
        activeOutputURL = nil
        self.activeID = nil
        activeBulletin = nil
        if requeue, current[activeID] != nil, failed[activeID] == nil, !queue.contains(activeID) {
            queue.append(activeID)
        }
    }

    private func removeAsset(_ id: String) {
        if let asset = assets.removeValue(forKey: id) { try? FileManager.default.removeItem(at: asset.url) }
    }

    private func removeAssets() {
        for asset in assets.values { try? FileManager.default.removeItem(at: asset.url) }
        assets.removeAll()
    }

    private func startNextIfPossible() {
        guard renderTask == nil, let voiceID, let id = queue.first, let bulletin = current[id] else { return }
        queue.removeFirst()
        switch availability(voiceID) {
        case .available: break
        case .missingVoice, .missingModel, .missingRuntime:
            failed[id] = Failed(bulletin: bulletin, voiceID: voiceID)
            startNextIfPossible()
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            failed[id] = Failed(bulletin: bulletin, voiceID: voiceID)
            startNextIfPossible()
            return
        }

        let outputURL = directory.appending(path: "\(UUID().uuidString).m4a")
        let token = generation
        let expectedRevision = ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID)
        let render = self.render
        activeID = id
        activeBulletin = bulletin
        activeOutputURL = outputURL
        renderTask = Task { @MainActor [weak self] in
            do {
                let audio = try await render(bulletin.text, voiceID, outputURL)
                guard let self else { try? FileManager.default.removeItem(at: outputURL); return }
                guard !Task.isCancelled, self.generation == token, self.enabled,
                      self.voiceID == voiceID, self.current[id] == bulletin, bulletin.expiresAt > self.now(),
                      audio.voiceRevision == expectedRevision, audio.audioURL == outputURL,
                      FileManager.default.fileExists(atPath: outputURL.path) else {
                    try? FileManager.default.removeItem(at: outputURL)
                    if self.generation == token {
                        self.failed[id] = Failed(bulletin: bulletin, voiceID: voiceID)
                        self.finishRender(token)
                    }
                    return
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
                self.assets[id] = Asset(
                    bulletin: bulletin, voiceID: voiceID, voiceRevision: audio.voiceRevision, url: outputURL)
                self.finishRender(token)
                self.onReady?(bulletin)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                guard let self, self.generation == token else { return }
                if self.current[id] == bulletin { self.failed[id] = Failed(bulletin: bulletin, voiceID: voiceID) }
                self.finishRender(token)
            }
        }
    }

    private func finishRender(_ token: UInt64) {
        guard generation == token else { return }
        renderTask = nil
        activeID = nil
        activeBulletin = nil
        activeOutputURL = nil
        sortQueue()
        startNextIfPossible()
    }
}

#endif
