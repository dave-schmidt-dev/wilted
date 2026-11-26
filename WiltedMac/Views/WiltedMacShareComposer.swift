import Observation
import SwiftUI

#if canImport(WiltedProducer)
import WiltedProducer

/// Stable selection identity: playback sessions can change without changing the source transcript.
struct WiltedMacShareComposerKey: Hashable {
    let store: ObjectIdentifier
    let account: ObjectIdentifier?
    let owner: String?
    let generation: UInt64?
    let item: String
    let revision: String
}

/// Owns one item/revision summary request and a bounded verified cache.
@MainActor @Observable
final class WiltedMacShareComposerState {
    struct Preview { let text: String; let title: String; let url: URL? }
    private struct CacheKey: Hashable {
        let store: ObjectIdentifier
        let account: ObjectIdentifier?
        let owner: String?
        let generation: UInt64?
        let item: String
        let revision: String
        let transcriptDigest: String
        let modelDigest: String
        let semanticFingerprint: String
    }
    private struct Cached { let context: WiltedMacShareContext; let preview: Preview; let promptIdentity: String }
    private struct Completed {
        let candidate: Cached
        let semantic: String
        let modelDigest: String
    }
    @ObservationIgnored weak var model: WiltedMacModel?
    let service: TranscriptSummaryService
    let configuration: TranscriptSummaryService.Configuration
    let selectionKey: WiltedMacShareComposerKey?
    private let fingerprint: @Sendable () async -> String?
    var presented = false
    private(set) var includeSummary = false
    private(set) var preview: Preview?
    private(set) var progress: String?
    private(set) var failure: String?
    private(set) var activeID: UUID?
    private var request: Task<Void, Never>?
    private var completed: Completed?
    private var cache: [CacheKey: Cached] = [:]
    private var order: [CacheKey] = []
    var cachedCount: Int { cache.count }

    init(model: WiltedMacModel, selectionKey: WiltedMacShareComposerKey? = nil,
         service: TranscriptSummaryService = TranscriptSummaryService(),
         configuration: TranscriptSummaryService.Configuration = .resolved(),
         fingerprint: @escaping @Sendable () async -> String? = {
             await Task.detached(priority: .utility) { PodcastPreparationPipeline.resolvedSemanticFingerprint() }.value
         }) {
        self.model = model; self.selectionKey = selectionKey
        self.service = service; self.configuration = configuration; self.fingerprint = fingerprint
    }

    func setIncludeSummary(_ value: Bool) {
        includeSummary = value
        if value { summarize() } else { cancel() }
    }
    func cancel() {
        activeID = nil; request?.cancel()
        includeSummary = false; progress = nil; preview = nil; failure = nil; completed = nil
    }
    func cancelAndDismiss() { cancel(); presented = false }
    func present() {
        presented = true
        guard let model, !model.isClosingTemporaryState, let completed else { return }
        // Do not expose a retained preview until its account, transcript and model
        // have been checked again after the panel was closed.
        preview = nil
        let id = UUID(); activeID = id; progress = "Checking summary…"
        request = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let digest = try await TranscriptSummaryService.modelIdentity(at: configuration.modelURL, requestID: id,
                    onProgress: progressHandler(id))
                guard eligible(id) else { return }
                guard digest == completed.modelDigest else { invalidateContext(); return }
                guard await owned(id, completed.candidate.context, completed.semantic) else { return }
                guard eligible(id) else { return }
                guard model.matchesShareContext(completed.candidate.context) else {
                    activeID = nil; request = nil; progress = nil
                    return
                }
                activeID = nil; request = nil; progress = nil; preview = completed.candidate.preview
            } catch {
                if activeID == id { invalidateContext() }
            }
        }
    }
    func dismiss() { presented = false }
    func teardown() { presented = false; cancel() }
    func invalidateContext() { cancel(); cache.removeAll(); order.removeAll(); presented = false }
    func waitForCompletion() async { await request?.value }
    func startOrAttach() {
        guard let model, !model.isClosingTemporaryState,
              selectionKey == nil || model.shareComposerSelectionIdentity == selectionKey else { return }
        presented = true
        if activeID != nil, request != nil { return }
        if activeID == nil { request = nil }
        if completed != nil { present(); return }
        if failure != nil { return }
        setIncludeSummary(true)
    }
    func payload(_ preview: Preview) -> String {
        preview.url.map { "\(preview.text)\n\n\($0.absoluteString)" } ?? preview.text
    }

    func summarize() {
        guard let model, !model.isClosingTemporaryState,
              selectionKey == nil || model.shareComposerSelectionIdentity == selectionKey else { return }
        let selection: WiltedMacShareSelection
        do { selection = try model.captureShareSelection() }
        catch {
            cancel(); includeSummary = true; failure = WiltedMacShareComposer.message(for: error)
            return
        }
        cancel(); includeSummary = true
        let id = UUID(); activeID = id; progress = "Loading local transcript…"
        request = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let semantic = await fingerprint(), eligible(id) else {
                    throw WiltedMacShareContextError.unavailable
                }
                let context = try await model.captureShareContext(for: selection)
                guard await owned(id, context, semantic) else { return }
                let digest = try await TranscriptSummaryService.modelIdentity(at: configuration.modelURL, requestID: id,
                    onProgress: progressHandler(id))
                guard await owned(id, context, semantic) else { return }
                let key = CacheKey(store: context.storeID, account: context.accountID,
                    owner: context.binding?.ownerToken, generation: context.accountGateGeneration,
                    item: context.itemID.rawValue, revision: context.revisionID.rawValue,
                    transcriptDigest: context.transcriptDigest, modelDigest: digest, semanticFingerprint: semantic)
                let candidate: Cached
                if let retained = cache[key] { candidate = retained }
                else {
                    progress = "Summarizing locally…"
                    let result = try await service.summarize(transcript: context.transcript, modelURL: configuration.modelURL,
                        requestID: id, expectedModelIdentity: digest, onProgress: progressHandler(id))
                    guard result.requestID == id, result.transcriptDigest == context.transcriptDigest,
                          result.modelIdentity == digest, await owned(id, context, semantic) else { return }
                    candidate = Cached(context: context, preview: Preview(text: result.summary, title: context.title,
                                                                        url: context.shareURL), promptIdentity: result.promptIdentity)
                }
                // A cached result is never reused on path spelling alone. Rehash
                // after the asynchronous context/worker boundary as well.
                let currentDigest = try await TranscriptSummaryService.modelIdentity(at: configuration.modelURL, requestID: id,
                    onProgress: progressHandler(id))
                guard currentDigest == digest, await owned(id, context, semantic) else { return }
                if cache[key] == nil {
                    cache[key] = candidate; order.append(key)
                    if order.count > 8 { cache.removeValue(forKey: order.removeFirst()) }
                }
                completed = Completed(candidate: candidate, semantic: semantic, modelDigest: digest)
                activeID = nil; request = nil
                progress = nil; failure = nil
                preview = model.matchesShareContext(context) ? candidate.preview : nil
            } catch is CancellationError { } catch {
                guard eligible(id) else { return }
                activeID = nil; request = nil
                progress = nil; failure = WiltedMacShareComposer.message(for: error)
            }
        }
    }
    private func eligible(_ id: UUID) -> Bool {
        activeID == id && includeSummary && !Task.isCancelled && model?.isClosingTemporaryState == false
    }
    private func owned(_ id: UUID, _ context: WiltedMacShareContext, _ semantic: String) async -> Bool {
        guard eligible(id) else { return false }
        guard let model else { return false }
        let owned = await model.stillOwnsShareContext(context)
        guard eligible(id) else { return false }
        guard owned, await fingerprint() == semantic, eligible(id) else {
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
        _state = State(initialValue: model.shareComposerState(service: service, configuration: configuration))
    }
    var body: some View {
        @Bindable var state = state
        HStack(spacing: 2) {
            Button {
                state.startOrAttach()
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share with summary").lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share summary").lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Create and review a local summary")
            .accessibilityLabel("Share with summary")
            .accessibilityHint("Create and review a local summary.")
            .accessibilityIdentifier("wilted-player-share")
            .popover(isPresented: $state.presented) {
                WiltedMacShareComposerPanel(progress: state.progress, failure: state.failure,
                    preview: state.preview.map { (text: $0.text, title: $0.title, url: $0.url) },
                    onRetry: state.summarize, onCancel: state.cancelAndDismiss,
                    payload: { value in state.payload(.init(text: value.text, title: value.title, url: value.url)) }).padding()
            }
            Menu {
                WiltedMacPlaybackShareItems(model: model)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(minWidth: 24, minHeight: 24)
            }
            .menuStyle(.borderlessButton)
            .help("More share options")
            .accessibilityLabel("More share options")
            .accessibilityHint("Share the page link or title and show.")
            .accessibilityIdentifier("wilted-player-share-options")
        }
        .onChange(of: state.presented) { _, visible in if !visible { state.dismiss() } }
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
    let progress: String?
    let failure: String?
    let preview: (text: String, title: String, url: URL?)?
    let onRetry: () -> Void
    let onCancel: () -> Void
    let payload: ((text: String, title: String, url: URL?)) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress {
                ProgressView(progress).controlSize(.small).accessibilityIdentifier("wilted-share-summary-progress")
                Text("You can close this panel while this runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("wilted-share-summary-dismiss-hint")
            }
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
