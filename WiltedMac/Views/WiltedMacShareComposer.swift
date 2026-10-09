import Observation
import SwiftUI

#if canImport(WiltedProducer)
import WiltedProducer

/// Owns only a popover request and eight verified in-memory summaries.
@MainActor @Observable
final class WiltedMacShareComposerState {
    struct Preview { let text: String; let title: String; let url: URL? }
    private struct CacheKey: Hashable {
        let store: ObjectIdentifier
        let controller: ObjectIdentifier
        let account: ObjectIdentifier?
        let owner: String?
        let generation: UInt64?
        let item: String
        let revision: String
        let session: String
        let transcriptDigest: String
        let modelDigest: String
        let semanticFingerprint: String
    }
    private struct Cached { let context: WiltedMacShareContext; let preview: Preview; let promptIdentity: String }
    let model: WiltedMacModel
    let service: TranscriptSummaryService
    let configuration: TranscriptSummaryService.Configuration
    private let fingerprint: @Sendable () async -> String?
    var presented = false
    private(set) var includeSummary = false
    private(set) var preview: Preview?
    private(set) var progress: String?
    private(set) var failure: String?
    private(set) var activeID: UUID?
    private var request: Task<Void, Never>?
    private var cache: [CacheKey: Cached] = [:]
    private var order: [CacheKey] = []
    var cachedCount: Int { cache.count }

    init(model: WiltedMacModel, service: TranscriptSummaryService = TranscriptSummaryService(),
         configuration: TranscriptSummaryService.Configuration = .resolved(),
         fingerprint: @escaping @Sendable () async -> String? = {
             await Task.detached(priority: .utility) { PodcastPreparationPipeline.resolvedSemanticFingerprint() }.value
         }) {
        self.model = model; self.service = service; self.configuration = configuration; self.fingerprint = fingerprint
    }

    func setIncludeSummary(_ value: Bool) {
        includeSummary = value
        if value { summarize() } else { cancel() }
    }
    func cancel() {
        activeID = nil; request?.cancel()
        includeSummary = false; progress = nil; preview = nil; failure = nil
    }
    func dismiss() { presented = false; cancel() }
    func invalidateContext() { cancel(); cache.removeAll(); order.removeAll() }
    func waitForCompletion() async { await request?.value }
    func payload(_ preview: Preview) -> String {
        preview.url.map { "\(preview.text)\n\n\($0.absoluteString)" } ?? preview.text
    }

    func summarize() {
        cancel(); includeSummary = true
        guard presented else { return }
        let id = UUID(); activeID = id; progress = "Loading local transcript…"
        request = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let semantic = await fingerprint(), eligible(id) else {
                    throw WiltedMacShareContextError.unavailable
                }
                let context = try await model.captureShareContext()
                guard await current(id, context, semantic) else { return }
                let digest = try await TranscriptSummaryService.modelIdentity(at: configuration.modelURL, requestID: id,
                    onProgress: progressHandler(id))
                guard await current(id, context, semantic) else { return }
                let key = CacheKey(store: context.storeID, controller: context.controllerID, account: context.accountID,
                    owner: context.binding?.ownerToken, generation: context.accountGateGeneration,
                    item: context.itemID.rawValue, revision: context.revisionID.rawValue, session: context.sessionID,
                    transcriptDigest: context.transcriptDigest, modelDigest: digest, semanticFingerprint: semantic)
                let candidate: Cached
                if let retained = cache[key] { candidate = retained }
                else {
                    progress = "Summarizing locally…"
                    let result = try await service.summarize(transcript: context.transcript, modelURL: configuration.modelURL,
                        requestID: id, expectedModelIdentity: digest, onProgress: progressHandler(id))
                    guard result.requestID == id, result.transcriptDigest == context.transcriptDigest,
                          result.modelIdentity == digest, await current(id, context, semantic) else { return }
                    candidate = Cached(context: context, preview: Preview(text: result.summary, title: context.title,
                                                                        url: context.shareURL), promptIdentity: result.promptIdentity)
                }
                // A cached result is never reused on path spelling alone. Rehash
                // after the asynchronous context/worker boundary as well.
                let currentDigest = try await TranscriptSummaryService.modelIdentity(at: configuration.modelURL, requestID: id,
                    onProgress: progressHandler(id))
                guard currentDigest == digest, await current(id, context, semantic) else { return }
                if cache[key] == nil {
                    cache[key] = candidate; order.append(key)
                    if order.count > 8 { cache.removeValue(forKey: order.removeFirst()) }
                }
                activeID = nil; request = nil
                progress = nil; failure = nil; preview = candidate.preview
            } catch is CancellationError { } catch {
                guard eligible(id) else { return }
                activeID = nil; request = nil
                progress = nil; failure = WiltedMacShareComposer.message(for: error)
            }
        }
    }
    private func eligible(_ id: UUID) -> Bool {
        activeID == id && includeSummary && presented && !Task.isCancelled && !model.isClosingTemporaryState
    }
    private func current(_ id: UUID, _ context: WiltedMacShareContext, _ semantic: String) async -> Bool {
        guard eligible(id) else { return false }
        let owned = await model.stillOwnsShareContext(context)
        guard eligible(id) else { return false }
        guard owned, await fingerprint() == semantic, eligible(id), model.matchesShareContext(context) else {
            if activeID == id { invalidateContext() }
            return false
        }
        return true
    }
    private func progressHandler(_ id: UUID) -> @Sendable (PodcastPreparationProgress) -> Void {
        { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.eligible(id), event.requestID == id else { return }
                self.progress = event.detail
            }
        }
    }
}

struct WiltedMacShareComposer: View {
    let model: WiltedMacModel
    @State private var state: WiltedMacShareComposerState
    init(model: WiltedMacModel, service: TranscriptSummaryService = TranscriptSummaryService(),
         configuration: TranscriptSummaryService.Configuration = .resolved()) {
        self.model = model
        _state = State(initialValue: WiltedMacShareComposerState(model: model, service: service, configuration: configuration))
    }
    var body: some View {
        @Bindable var state = state
        Button { state.presented = true } label: { Image(systemName: "chevron.down") }
            .help("Share options").accessibilityLabel("Share options")
            .accessibilityIdentifier("wilted-player-share-options")
            .popover(isPresented: $state.presented) {
                WiltedMacShareComposerPanel(includeSummary: Binding(get: { state.includeSummary }, set: state.setIncludeSummary),
                    progress: state.progress, failure: state.failure,
                    preview: state.preview.map { (text: $0.text, title: $0.title, url: $0.url) },
                    onRetry: state.summarize, onCancel: state.cancel,
                    payload: { value in state.payload(.init(text: value.text, title: value.title, url: value.url)) }).padding()
            }
            .onChange(of: state.presented) { _, visible in if !visible { state.dismiss() } }
            .onChange(of: model.playback?.itemID) { state.invalidateContext() }
            .onChange(of: model.playback?.revisionID) { state.invalidateContext() }
            .onChange(of: model.playback?.sessionID) { state.invalidateContext() }
            .onChange(of: model.libraryAccountStatus) { state.invalidateContext() }
            .onChange(of: model.libraryAccount?.binding) { state.invalidateContext() }
            .onChange(of: model.isClosingTemporaryState) { state.invalidateContext() }
            .onDisappear { state.dismiss() }
    }
    static func message(for error: Error) -> String {
        switch error {
        case TranscriptSummaryError.emptyTranscript, TranscriptSummaryError.incompleteResponse:
            "A complete local transcript is required before sharing a summary."
        case TranscriptSummaryError.modelUnavailable, TranscriptSummaryError.modelChanged:
            "Select an available local model and try again."
        case TranscriptSummaryError.identityMismatch, TranscriptSummaryError.malformedResponse:
            "The local summary could not be verified. Try again."
        case TranscriptSummaryError.workerFailed(_, let message): message
        case is WiltedMacShareContextError: error.localizedDescription
        default: "The local summary could not be completed. Try again."
        }
    }
}
#endif

struct WiltedMacShareComposerPanel: View {
    @Binding var includeSummary: Bool
    let progress: String?
    let failure: String?
    let preview: (text: String, title: String, url: URL?)?
    let onRetry: () -> Void
    let onCancel: () -> Void
    let payload: ((text: String, title: String, url: URL?)) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Include transcript summary", isOn: $includeSummary)
            if let progress { ProgressView(progress).controlSize(.small).accessibilityIdentifier("wilted-share-summary-progress") }
            if let failure {
                Text(failure).foregroundStyle(.red).accessibilityIdentifier("wilted-share-summary-error")
                Button("Retry", action: onRetry).accessibilityIdentifier("wilted-share-summary-retry")
            }
            if let preview {
                Text("Preview").font(.headline)
                ScrollView { Text(preview.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 220).accessibilityIdentifier("wilted-share-summary-preview")
                ShareLink(item: payload(preview), subject: Text(preview.title)) {
                    Label("Share summary", systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("wilted-player-share-summary")
            }
            if progress != nil { Button("Cancel", action: onCancel).accessibilityIdentifier("wilted-share-summary-cancel") }
        }.frame(width: 360, alignment: .leading)
    }
}
