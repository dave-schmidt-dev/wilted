import CryptoKit
import Foundation
import WiltedDomain

#if canImport(WiltedProducer)
import WiltedProducer

struct WiltedMacShareSelection: Sendable {
    let store: LocalLibraryStore
    let account: WiltedMacLibraryAccountController?
    let storeID: ObjectIdentifier
    let accountID: ObjectIdentifier?
    let itemID: ItemID
    let revisionID: RevisionID
    let binding: LocalLibraryAccountBinding?
    let accountGateGeneration: UInt64?
}

#endif

struct WiltedMacShareContext: Sendable {
    #if canImport(WiltedProducer)
    let store: LocalLibraryStore
    let account: WiltedMacLibraryAccountController?
    let storeID: ObjectIdentifier
    let accountID: ObjectIdentifier?
    let itemID: ItemID
    let revisionID: RevisionID
    let binding: LocalLibraryAccountBinding?
    let accountGateGeneration: UInt64?
    let transcript: String
    let transcriptDigest: String
    let title: String
    let subtitle: String?
    let hostCredit: String?
    let shareURL: URL?
    #endif

    static func usablePublicShareURL(
        episodeLink: URL?,
        enclosureURL: URL? = nil,
        feedURL: URL? = nil,
        title: String,
        show: String?
    ) -> URL? {
        if let episodeLink, isSafePublicWebLink(episodeLink, enclosureURL: enclosureURL, feedURL: feedURL) {
            return episodeLink
        }
        return safeSearchURL(title: title, show: show)
    }

    static func isSafePublicWebLink(_ url: URL, enclosureURL: URL? = nil, feedURL: URL? = nil) -> Bool {
        guard PodcastEpisode.isValidEpisodeLink(url) else { return false }
        if let enclosureURL, withoutFragment(url) == withoutFragment(enclosureURL) { return false }
        let mediaExtensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "wav", "ogg", "opus", "flac", "m3u", "m3u8", "pls", "mpd"]
        if mediaExtensions.contains(url.pathExtension.lowercased()) { return false }
        if let feedURL, withoutFragment(url) == withoutFragment(feedURL) { return false }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems {
            let sensitiveKeys: Set<String> = [
                "signature", "sig", "x-amz-signature", "x-goog-signature",
                "token", "access_token", "auth_token", "auth", "jwt", "key", "api_key", "apikey",
                "secret", "ticket", "session", "session_id", "sessionid", "credential"
            ]
            for item in items {
                let name = item.name.lowercased()
                if sensitiveKeys.contains(name) || name.hasSuffix("_token") || name.hasSuffix("token")
                    || name.contains("signature") || name.hasPrefix("x-amz-") || name.hasPrefix("x-goog-") {
                    return false
                }
            }
        }
        return true
    }

    static func safeSearchURL(title: String, show: String?) -> URL? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShow = show?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let queryTerms = [trimmedTitle, trimmedShow].filter { !$0.isEmpty }
        guard !queryTerms.isEmpty else { return nil }
        let queryValue = queryTerms.joined(separator: " ")
        let query = String(String.UnicodeScalarView(queryValue.unicodeScalars.prefix(120)))
        var components = URLComponents(string: "https://podcasts.apple.com/search")
        components?.queryItems = [URLQueryItem(name: "term", value: query)]
        // URLQueryItem may leave `+` literal; form-style servers can decode it as a space.
        if let encodedQuery = components?.percentEncodedQuery {
            components?.percentEncodedQuery = encodedQuery.replacingOccurrences(of: "+", with: "%2B")
        }
        return components?.url
    }

    /// Returns only a plainly labeled host credit from feed notes, never a publisher or byline.
    static func explicitHostCredit(from notes: String?) -> String? {
        guard let notes else { return nil }
        let pattern = #"^\s*(?:episode\s+)?hosts?\s*:\s*(.{1,240})\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for line in notes.components(separatedBy: .newlines) {
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: lineRange),
                  let valueRange = Range(match.range(at: 1), in: line) else { continue }
            let credit = line[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !credit.isEmpty { return credit }
        }
        return nil
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}

#if canImport(WiltedProducer)
enum WiltedMacShareContextError: LocalizedError {
    case unavailable
    case transcriptUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: "The current item is no longer available to share."
        case .transcriptUnavailable: "A complete local transcript is not available for this item."
        }
    }
}

extension WiltedMacModel {
    /// Freezes the selected revision and owner before the async summary job starts.
    func captureShareSelection() throws -> WiltedMacShareSelection {
        guard !isClosingTemporaryState, let store, let playback,
              let itemID = playback.itemID, let revisionID = playback.revisionID else {
            throw WiltedMacShareContextError.unavailable
        }
        let account = libraryAccount
        let binding: LocalLibraryAccountBinding?
        let gateGeneration: UInt64?
        let accountID: ObjectIdentifier?
        if let account {
            guard let current = account.binding, account.gate.isOpen else {
                throw WiltedMacShareContextError.unavailable
            }
            binding = current
            gateGeneration = account.gate.generation
            accountID = ObjectIdentifier(account)
        } else {
            binding = nil
            gateGeneration = nil
            accountID = nil
        }
        return WiltedMacShareSelection(store: store, account: account, storeID: ObjectIdentifier(store),
            accountID: accountID, itemID: itemID, revisionID: revisionID,
            binding: binding, accountGateGeneration: gateGeneration)
    }

    /// Captures the frozen revision even after playback moves to another item.
    func captureShareContext(for selection: WiltedMacShareSelection) async throws -> WiltedMacShareContext {
        guard !isClosingTemporaryState, store === selection.store,
              ObjectIdentifier(selection.store) == selection.storeID,
              shareSelectionAccountMatches(selection), await stillOwnsShareSelection(selection) else {
            throw WiltedMacShareContextError.unavailable
        }
        guard let transcript = try await selection.store.transcript(for: selection.itemID, revisionID: selection.revisionID),
              transcript.itemID == selection.itemID, transcript.revisionID == selection.revisionID,
              transcript.availability == .available, let text = transcript.text, !text.isEmpty else {
            throw WiltedMacShareContextError.transcriptUnavailable
        }
        guard await stillOwnsShareSelection(selection) else { throw WiltedMacShareContextError.unavailable }
        let (title, subtitle, hostCredit, shareURL) = try await shareMetadata(for: selection.itemID, in: selection.store)
        let context = WiltedMacShareContext(store: selection.store, account: selection.account,
            storeID: selection.storeID, accountID: selection.accountID, itemID: selection.itemID,
            revisionID: selection.revisionID, binding: selection.binding,
            accountGateGeneration: selection.accountGateGeneration,
            transcript: text, transcriptDigest: Self.shareTranscriptDigest(text), title: title, subtitle: subtitle,
            hostCredit: hostCredit, shareURL: shareURL)
        guard await stillOwnsShareContext(context) else {
            throw WiltedMacShareContextError.unavailable
        }
        return context
    }

    /// Convenience entry for callers whose selection should be captured at call time.
    func captureShareContext() async throws -> WiltedMacShareContext {
        let selection = try captureShareSelection()
        return try await captureShareContext(for: selection)
    }

    /// Checks whether this revision is selected now; playback sessions may change while a job runs.
    func matchesShareContext(_ context: WiltedMacShareContext) -> Bool {
        guard !isClosingTemporaryState, store === context.store,
              playback?.itemID == context.itemID, playback?.revisionID == context.revisionID else { return false }
        return shareContextAccountMatches(context)
    }

    /// Verifies stored ownership and exact source data without requiring the item to remain selected.
    func stillOwnsShareContext(_ context: WiltedMacShareContext) async -> Bool {
        guard !isClosingTemporaryState, store === context.store,
              ObjectIdentifier(context.store) == context.storeID,
              shareContextAccountMatches(context) else { return false }

        guard (try? await context.store.readyRevision(for: context.itemID, revisionID: context.revisionID)) != nil,
              !isClosingTemporaryState, store === context.store, shareContextAccountMatches(context),
              let transcript = try? await context.store.transcript(for: context.itemID, revisionID: context.revisionID),
              transcript.itemID == context.itemID, transcript.revisionID == context.revisionID,
              transcript.availability == .available, transcript.text == context.transcript,
              !isClosingTemporaryState, store === context.store, shareContextAccountMatches(context) else { return false }

        guard let (title, subtitle, hostCredit, shareURL) = try? await shareMetadata(for: context.itemID, in: context.store),
              title == context.title, subtitle == context.subtitle, hostCredit == context.hostCredit,
              shareURL == context.shareURL else { return false }
        let persistedBinding = try? await context.store.libraryAccountBinding()
        return !isClosingTemporaryState && store === context.store
            && shareContextAccountMatches(context) && persistedBinding == context.binding
    }

    private func stillOwnsShareSelection(_ selection: WiltedMacShareSelection) async -> Bool {
        guard !isClosingTemporaryState, store === selection.store,
              shareSelectionAccountMatches(selection),
              (try? await selection.store.readyRevision(for: selection.itemID, revisionID: selection.revisionID)) != nil,
              !isClosingTemporaryState, store === selection.store, shareSelectionAccountMatches(selection),
              (try? await selection.store.libraryAccountBinding()) == selection.binding else { return false }
        return !isClosingTemporaryState && store === selection.store && shareSelectionAccountMatches(selection)
    }

    private func shareSelectionAccountMatches(_ selection: WiltedMacShareSelection) -> Bool {
        if let account = selection.account, let accountID = selection.accountID,
           let generation = selection.accountGateGeneration {
            return libraryAccount === account && ObjectIdentifier(account) == accountID
                && account.binding == selection.binding && account.gate.isOpen
                && account.gate.generation == generation
        }
        return selection.account == nil && selection.accountID == nil
            && selection.binding == nil && selection.accountGateGeneration == nil
            && libraryAccount == nil
    }

    private func shareContextAccountMatches(_ context: WiltedMacShareContext) -> Bool {
        if let account = context.account, let accountID = context.accountID,
           let generation = context.accountGateGeneration {
            return libraryAccount === account && ObjectIdentifier(account) == accountID
                && account.binding == context.binding && account.gate.isOpen
                && account.gate.generation == generation
        }
        return context.account == nil && context.accountID == nil
            && context.binding == nil && context.accountGateGeneration == nil
            && libraryAccount == nil
    }

    private func shareMetadata(for itemID: ItemID, in store: LocalLibraryStore) async throws -> (String, String?, String?, URL?) {
        if let episode = try await store.podcastEpisode(for: itemID) {
            guard try await store.removalKind(for: itemID) == nil else { throw WiltedMacShareContextError.unavailable }
            let feedTitle = (try? await store.podcastFeed(for: episode.feedID))?.title
            let usableURL = WiltedMacShareContext.usablePublicShareURL(
                episodeLink: episode.episodeLink,
                enclosureURL: episode.enclosureURL,
                feedURL: episode.feedURL,
                title: episode.title,
                show: feedTitle
            )
            return (episode.title, feedTitle, WiltedMacShareContext.explicitHostCredit(from: episode.notes), usableURL)
        }
        if let article = try await store.article(for: itemID), !article.isDeleted {
            return (article.title, article.source, nil, article.canonicalURL)
        }
        throw WiltedMacShareContextError.unavailable
    }

    private static func shareTranscriptDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
