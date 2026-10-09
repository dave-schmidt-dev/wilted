import Foundation

/// Pure state machine behind the Add sheet. The caller feeds it text, runs the
/// returned ``Effect`` with its own classifier and search closures, and applies
/// the ``Answer``. Every request carries a generation; answers for any older
/// generation are dropped, so slow responses never overwrite newer input.
public struct AddQuery: Equatable, Sendable {
    /// What trimmed text means.
    public enum Input: Equatable, Sendable {
        case empty
        case link(URL)
        case search(String)
        case unsupported(String)
    }

    /// A caller's verdict on a link.
    public enum LinkKind: Equatable, Sendable {
        case article
        case podcastFeed
        case unsupported(String)
    }

    public struct Result: Equatable, Sendable {
        public let show: PodcastCatalogShow
        public let alreadyFollowed: Bool

        public init(show: PodcastCatalogShow, alreadyFollowed: Bool) {
            self.show = show
            self.alreadyFollowed = alreadyFollowed
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case classifying
        case searching
        case results([Result])
        case article(URL)
        case podcastFeed(URL)
        case unsupported(String)
        case unreachable
        case cancelled
    }

    /// Work the caller must start for the current generation.
    public enum Effect: Equatable, Sendable {
        case none
        case classify(URL, generation: Int)
        case search(String, generation: Int)
    }

    public struct Answer: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            case classified(LinkKind)
            case searched([PodcastCatalogShow])
            case failed
            case cancelled
        }

        public let generation: Int
        public let outcome: Outcome

        public init(generation: Int, outcome: Outcome) {
            self.generation = generation
            self.outcome = outcome
        }
    }

    public private(set) var state: State = .idle
    public private(set) var generation = 0

    public init() {}

    /// Classifies trimmed text. Links are https URLs, or bare text with a dot and
    /// no spaces that parses as one after adding `https://`. Anything with a
    /// space and no scheme is a search.
    public static func parse(_ text: String) -> Input {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.contains(where: \.isWhitespace) { return .search(trimmed) }
        let hasScheme = trimmed.contains("://")
        if !hasScheme {
            guard trimmed.contains("."), let url = URL(string: "https://" + trimmed), hasDomainHost(url) else {
                return .search(trimmed)
            }
            return linkOrUnsupported(url)
        }
        guard let url = URL(string: trimmed), url.host?.isEmpty == false else { return .search(trimmed) }
        return linkOrUnsupported(url)
    }

    /// Starts a new request, invalidating anything in flight.
    public mutating func begin(_ text: String) -> Effect {
        generation += 1
        pendingLink = nil
        switch Self.parse(text) {
        case .empty:
            state = .idle
            return .none
        case .unsupported(let reason):
            state = .unsupported(reason)
            return .none
        case .link(let url):
            state = .classifying
            pendingLink = url
            return .classify(url, generation: generation)
        case .search(let term):
            state = .searching
            return .search(term, generation: generation)
        }
    }

    /// Cancels the current request; late answers are dropped.
    public mutating func cancel() {
        generation += 1
        state = .cancelled
    }

    /// Applies an answer unless it belongs to an older generation.
    public mutating func apply(_ answer: Answer, isFollowed: (PodcastCatalogShow) -> Bool = { _ in false }) {
        guard answer.generation == generation else { return }
        switch (state, answer.outcome) {
        case (.classifying, .classified(let kind)):
            guard let url = pendingLink else { return }
            state = Self.state(for: kind, url: url)
        case (.searching, .searched(let shows)):
            state = .results(shows.map { Result(show: $0, alreadyFollowed: isFollowed($0)) })
        case (.classifying, .failed), (.searching, .failed):
            state = .unreachable
        case (.classifying, .cancelled), (.searching, .cancelled):
            state = .cancelled
        default:
            break
        }
    }

    /// Runs one effect with the injected closures; errors become `.failed`,
    /// cancellation becomes `.cancelled`.
    public static func run(
        _ effect: Effect,
        classify: @Sendable (URL) async throws -> LinkKind,
        search: @Sendable (String) async throws -> [PodcastCatalogShow]
    ) async -> Answer? {
        switch effect {
        case .none:
            return nil
        case .classify(let url, let generation):
            do { return Answer(generation: generation, outcome: .classified(try await classify(url))) } catch {
                return Answer(generation: generation, outcome: failure(error))
            }
        case .search(let term, let generation):
            do { return Answer(generation: generation, outcome: .searched(try await search(term))) } catch {
                return Answer(generation: generation, outcome: failure(error))
            }
        }
    }

    // MARK: Private

    private var pendingLink: URL?

    private static func failure(_ error: Error) -> Answer.Outcome {
        error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
    }

    private static func state(for kind: LinkKind, url: URL) -> State {
        switch kind {
        case .article: .article(url)
        case .podcastFeed: .podcastFeed(url)
        case .unsupported(let reason): .unsupported(reason)
        }
    }

    private static func hasDomainHost(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return true
    }

    private static func linkOrUnsupported(_ url: URL) -> Input {
        guard url.scheme?.lowercased() == "https" else { return .unsupported("Only https links can be added.") }
        guard url.user == nil, url.password == nil else { return .unsupported("Links with a login are not supported.") }
        return .link(url)
    }
}
