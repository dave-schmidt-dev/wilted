import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

/// Shown once before a newly added podcast feed is saved, when it looks paid or ad-free.
struct WiltedMacAdFreeFeedPrompt: Identifiable, Equatable {
    let feedID: String
    let title: String
    /// Tells one ask from the next for the same feed, so a cancelled add cannot answer its successor.
    let token = UUID()
    var id: String { feedID }
}

extension WiltedMacModel {
#if canImport(WiltedProducer)
    /// True when the labelling policy would force the show local for a private title,
    /// token-like feed address, or credentialed address — not for an unknown address alone.
    static func looksAdFree(title: String, feedURL: URL?, feedID: String) -> Bool {
        let reason = RemoteLabellingPolicy.forcedLocalReason(for: RemoteLabellingInput(
            feedID: feedID, feedURL: feedURL, feedTitle: title, customTitle: nil, audioURL: nil
        ))
        switch reason {
        case .privateTitle, .tokenLikeFeedURL, .credentialedURL:
            return true
        default:
            return false
        }
    }

    /// First episodes are admitted right after save, so the ad-free choice must land first.
    func askToExcludeAdFreeFeedIfNeeded(
        feed: PodcastFeed, store: LocalLibraryStore, requestID: UUID?
    ) async throws {
        let feedID = feed.itemID.rawValue
        if try await store.subscription(for: feed.itemID) != nil { return }
        let preference = WiltedMacAdFreeFeedPreference(preferences: preferences)
        if preference.isAdFree(feedID: feedID) { return }
        guard Self.looksAdFree(title: feed.title, feedURL: feed.canonicalURL, feedID: feedID) else {
            return
        }

        let prompt = WiltedMacAdFreeFeedPrompt(feedID: feedID, title: feed.title)
        _ = await awaitAdFreeFeedPromptAnswer(prompt)
        // Cancellation (or a superseded request) must not save after the wait ends.
        try Task.checkCancellation()
        guard requestID == nil || podcastSubscriptionRequestID == requestID else {
            throw CancellationError()
        }
    }
#endif

    /// The only path an answer arrives on. No pending prompt is a no-op.
    func answerAdFreeFeedPrompt(exclude: Bool) {
        guard let continuation = adFreeFeedPromptContinuation else { return }
        adFreeFeedPromptContinuation = nil
        let feedID = pendingAdFreeFeedPrompt?.feedID
        pendingAdFreeFeedPrompt = nil
        if exclude, let feedID {
            WiltedMacAdFreeFeedPreference(preferences: preferences).set(feedID: feedID, adFree: true)
        }
        continuation.resume(returning: exclude)
    }

    /// The alert closed. It also closes as a button runs, in no promised order, so the
    /// default answer waits a turn and applies only if that same question is still open.
    func adFreeFeedPromptWasDismissed() {
        guard let dismissed = pendingAdFreeFeedPrompt else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pendingAdFreeFeedPrompt == dismissed else { return }
            self.answerAdFreeFeedPrompt(exclude: false)
        }
    }

#if canImport(WiltedProducer)
    /// Publishes the prompt and parks the subscribe loop until the owner answers or the add cancels.
    private func awaitAdFreeFeedPromptAnswer(_ prompt: WiltedMacAdFreeFeedPrompt) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Already cancelled: resume now so onCancel's later answer is a no-op.
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                // A superseded add may still be waiting; release it rather than strand it.
                answerAdFreeFeedPrompt(exclude: false)
                pendingAdFreeFeedPrompt = prompt
                adFreeFeedPromptContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                // Only this add's own prompt: a later add's prompt is not this one's to answer.
                guard let self, self.pendingAdFreeFeedPrompt == prompt else { return }
                self.answerAdFreeFeedPrompt(exclude: false)
            }
        }
    }
#endif
}
