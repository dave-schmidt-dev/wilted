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
    /// True when the show's title or address resembles a feed that may already be ad-free.
    static func looksAdFree(title: String, feedURL: URL?) -> Bool {
        guard let feedURL else { return false }
        return hasAdFreeTitle(title) || hasCredentialedAddress(feedURL) || hasTokenLikeAddress(feedURL)
    }

    private static func hasAdFreeTitle(_ title: String) -> Bool {
        let pattern = #"\b(premium|private|subscribers?|patrons?|members?|plus|ad[- ]free)\b"#
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasCredentialedAddress(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        if parts.user != nil || parts.password != nil { return true }
        let credentialKeys: Set<String> = ["token", "auth", "key", "sig", "signature"]
        return (parts.queryItems ?? []).contains { credentialKeys.contains($0.name.lowercased()) }
    }

    private static func hasTokenLikeAddress(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        var candidates = parts.path.split(separator: "/").map(String.init)
        candidates += (parts.queryItems ?? []).flatMap { [$0.name, $0.value ?? ""] }
        return candidates.contains { part in
            if part.count >= 64 { return true }
            return part.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).contains { run in
                run.count >= 24 && run.contains(where: \.isLetter) && run.contains(where: \.isNumber)
            }
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
        guard Self.looksAdFree(title: feed.title, feedURL: feed.canonicalURL) else {
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
