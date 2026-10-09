import Foundation
import WiltedCatalog
import WiltedDomain
import WiltedLibrary

/// What the phone asks the Mac to add. The phone never writes library state: each request is a
/// `subscribe` or `addArticle` intent, and the Mac applies it or refuses it.
enum LibraryAddRequest: Equatable, Sendable {
    case subscribe(URL)
    case article(URL)

    /// The name the Mac lists in `supportedIntentActions` for this request.
    var actionName: String {
        switch self {
        case .subscribe: "subscribe"
        case .article: "addArticle"
        }
    }

    func intent(deviceID: String, createdAt: Date) throws -> LibraryIntent {
        switch self {
        case let .subscribe(url): try .subscribe(feedURL: url, deviceID: deviceID, createdAt: createdAt)
        case let .article(url): try .addArticle(url: url, deviceID: deviceID, createdAt: createdAt)
        }
    }
}

/// One add the phone sent (or is about to send) and the Mac's answer to it, keyed by intent id.
struct PendingAdd: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Sent; the Mac has not answered.
        case sent
        case applied
        /// The Mac's reason, as it published it.
        case rejected(String)
    }

    let intent: LibraryIntent
    /// What the listener sees: the show's name, or the address of the article.
    let title: String
    var phase: Phase = .sent
    /// False until the transport accepted the intent; unsent adds are retried on the next round.
    var isSent = false

    var id: String { intent.id }
    var isSubscribe: Bool {
        if case .subscribe = intent.action { true } else { false }
    }
    var isFinished: Bool { phase != .sent }
    var isAwaitingAnswer: Bool { phase == .sent }
}

/// What a sent add says, in words, and how it is toned.
struct LibraryAddStatus: Equatable, Sendable {
    let text: String
    let tone: WiltedStatusTone
    let symbol: String
}

extension LibraryAppModel {
    static let updateMacText = "Update Wilted on your Mac to add from iPhone"
    static let macCheckFailedText = "Wilted could not check your Mac. Try again in a moment."
    static let invalidAddLinkText = "Only https links without a login can be added."

    // MARK: - Reading

    /// True while any add still needs the Mac's answer, so the sync round reads the outcomes.
    var hasAddAwaitingAnswer: Bool { adds.contains { $0.isAwaitingAnswer } }

    /// The standing reason adds are off, once the Mac's published actions are known.
    var addCapabilityNotice: String? {
        if macAddCheckFailed { return Self.macCheckFailedText }
        guard let actions = macAddActions else { return nil }
        return actions.isSuperset(of: ["subscribe", "addArticle"]) ? nil : Self.updateMacText
    }

    /// False only when the Mac is known not to apply `request`; unknown stays tappable, and the tap checks.
    func canAdd(_ request: LibraryAddRequest) -> Bool {
        macAddActions.map { $0.contains(request.actionName) } ?? true
    }

    /// Whether the mirrored library already holds this feed as a source.
    func isFollowing(_ feedURL: URL) -> Bool {
        guard let id = try? ItemID.derivePodcastFeed(from: feedURL) else { return false }
        return decisionContent.sources[id] != nil
    }

    func addStatus(for add: PendingAdd) -> LibraryAddStatus {
        switch add.phase {
        case .sent:
            guard add.isSent else {
                return LibraryAddStatus(text: "Not sent yet. Trying again.", tone: .caution, symbol: "arrow.triangle.2.circlepath")
            }
            let overdue = now().timeIntervalSince(add.intent.createdAt) >= decisionTiming.confirmationTimeout
            return overdue
                ? LibraryAddStatus(
                    text: "Sent to your Mac. It has not answered yet; open Wilted on your Mac.", tone: .caution,
                    symbol: "paperplane")
                : LibraryAddStatus(text: "Sent to your Mac", tone: .active, symbol: "paperplane")
        case .applied:
            return LibraryAddStatus(
                text: add.isSubscribe ? "Following on your Mac" : "Added on your Mac", tone: .positive,
                symbol: "checkmark.circle")
        case let .rejected(reason):
            return LibraryAddStatus(
                text: Self.addRejectionText(reason), tone: .failure, symbol: "exclamationmark.triangle")
        }
    }

    /// The Mac's reasons for the add intents, in words. Anything else is an opaque refusal.
    static func addRejectionText(_ reason: String?) -> String {
        switch reason {
        case "alreadyFollowed": "Your Mac already follows this podcast."
        case "alreadyAdded": "Your Mac already has this article."
        case "notAPodcastFeed": "Your Mac could not read that link as a podcast feed. Try adding it as an article."
        case "isAFeed": "That link is a podcast feed. Add it as a podcast instead."
        case "noAudio": "That feed has no audio episodes, so your Mac did not add it."
        case IntentOutcome.reasonFailed: "Your Mac could not add it. Try again in a moment."
        case IntentOutcome.reasonUnsupportedAction: updateMacText
        case IntentOutcome.reasonExpired: "Your Mac did not see this in time. Send it again."
        default: "Your Mac declined it."
        }
    }

    // MARK: - Acting

    /// Reads which add actions the Mac applies. A failed read keeps what was known and flags the failure.
    func loadAddCapability() async {
        #if DEBUG
        if let mac = LibraryAddUITestSeam.mac {
            macAddActions = mac == .old ? [] : ["subscribe", "addArticle"]
            macAddCheckFailed = false
            return
        }
        #endif
        do {
            let stats = try await transport.readStats()
            macAddActions = Set(stats?.supportedIntentActions ?? [])
            macAddCheckFailed = false
        } catch {
            macAddCheckFailed = true
        }
    }

    /// Sends one add to the Mac, but only when the Mac says it applies that action. A second press while
    /// the same add waits sends nothing. A refusal leaves the reason in `addNotice` and nothing in `adds`.
    func addToMac(_ request: LibraryAddRequest, title: String) async {
        addNotice = nil
        guard !accountQuarantined else {
            addNotice = "Sync is paused until the account change is reviewed."
            return
        }
        guard let intent = try? request.intent(deviceID: deviceID, createdAt: now()) else {
            addNotice = Self.invalidAddLinkText
            return
        }
        if !canAdd(request) || macAddActions == nil || macAddCheckFailed { await loadAddCapability() }
        guard macAddActions?.contains(request.actionName) == true else {
            addNotice = macAddCheckFailed ? Self.macCheckFailedText : Self.updateMacText
            return
        }
        guard !adds.contains(where: { $0.isAwaitingAnswer && $0.intent.action == intent.action }) else { return }
        let add = PendingAdd(intent: intent, title: title)
        adds.append(add)
        await sendAdd(add)
    }

    /// Drops the adds that have an answer; the ones still waiting stay.
    func clearFinishedAdds() { adds.removeAll(where: \.isFinished) }

    func dismissAdd(_ id: String) { adds.removeAll { $0.id == id && $0.isFinished } }

    func discardAddsAfterAccountChange() {
        adds = []
        addNotice = nil
        macAddActions = nil
        macAddCheckFailed = false
    }

    // MARK: - Settling

    /// Matches the Mac's outcomes to the adds waiting on them (by intent id, this device's only) and
    /// retries any add the transport has not yet accepted. An applied add asks the next round to read
    /// the Larder, so the new item shows up without waiting for the slow cadence.
    func resolveAdds(outcomes read: [IntentOutcome]) async {
        guard !adds.isEmpty else { return }
        for add in adds where !add.isSent { await sendAdd(add) }
        let answers = Dictionary(
            read.filter { $0.deviceID == deviceID }.map { ($0.intentID, $0) }, uniquingKeysWith: { first, _ in first })
        var applied = false
        for index in adds.indices where adds[index].isAwaitingAnswer {
            guard let outcome = answers[adds[index].id] else { continue }
            adds[index].phase = outcome.isApplied ? .applied : .rejected(outcome.reason ?? "")
            applied = applied || outcome.isApplied
        }
        if applied { tickState.forceFull = true }
    }

    private func sendAdd(_ add: PendingAdd) async {
        guard (try? await transport.send(intent: add.intent)) != nil,
              let index = adds.firstIndex(where: { $0.id == add.id }) else { return }
        adds[index].isSent = true
        #if DEBUG
        if LibraryAddUITestSeam.mac == .rejectsNoAudio,
           let refusal = try? IntentOutcome.rejected(for: add.intent, reason: "noAudio", at: now()) {
            await resolveAdds(outcomes: [refusal])
        }
        #endif
    }
}

extension LibraryAppModel {
    /// A session wired to Apple's catalogue; tests pass their own closures and a zero debounce.
    func makeAddSession(
        search: LibraryAddSession.Search? = nil,
        lookup: LibraryAddSession.Lookup? = nil,
        linkDebounce: Duration = .milliseconds(400),
        searchDebounce: Duration = PodcastCatalogLookupClient.searchDebounce
    ) -> LibraryAddSession {
        let catalogue = PodcastCatalogLookupClient()
        var search = search ?? { term in try await catalogue.search(term: term) }
        var lookup = lookup ?? { id in try await catalogue.lookup(collectionID: id) }
        #if DEBUG
        // The pixel fixture never reaches Apple: canned answers, so a capture cannot depend on the network.
        if LibraryAddUITestSeam.mac != nil {
            search = { _ in LibraryAddUITestSeam.shows }
            lookup = { _ in throw PodcastCatalogLookupError.resultNotFound }
        }
        #endif
        return LibraryAddSession(
            model: self, search: search, lookup: lookup, linkDebounce: linkDebounce, searchDebounce: searchDebounce)
    }
}

/// The Add sheet's logic: one field, classified as you type. A link is classified by its address (an
/// Apple Podcasts show resolves through the catalogue, any other link is the listener's to name), and
/// anything else searches Apple's catalogue directly. `AddQuery` owns the state and drops stale answers;
/// this class owns the debounce and the task, and hands a chosen row to the model as an add for the Mac.
///
/// The field's text lives in `LibraryAppModel.addDraft`, so a half-typed query survives closing the sheet.
@MainActor
final class LibraryAddSession: ObservableObject {
    typealias Search = @Sendable (String) async throws -> [PodcastCatalogShow]
    typealias Lookup = @Sendable (Int) async throws -> PodcastCatalogShow

    /// What the listener says a link they pasted is, when the phone cannot tell.
    enum LinkChoice: Equatable, Sendable { case article, podcastFeed }

    /// One result with its one decision.
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case show(feed: URL, following: Bool)
            /// A link the phone cannot classify: Article or Podcast feed is the listener's call.
            case link(URL)
        }

        let id: String
        let title: String
        let detail: String
        let kind: Kind
        /// Set while an add for this row waits on the Mac or has been applied; a refusal clears it so the
        /// row offers its action again. The request's own words live in the requests list, not here.
        var requestPhase: PendingAdd.Phase?
    }

    @Published private(set) var query = AddQuery()
    /// The show an Apple Podcasts link resolved to.
    @Published private(set) var resolvedShow: PodcastCatalogShow?

    private let model: LibraryAppModel
    private let search: Search
    private let lookup: Lookup
    private let linkDebounce: Duration
    private let searchDebounce: Duration
    private var task: Task<Void, Never>?

    init(model: LibraryAppModel, search: @escaping Search, lookup: @escaping Lookup, linkDebounce: Duration, searchDebounce: Duration) {
        self.model = model
        self.search = search
        self.lookup = lookup
        self.linkDebounce = linkDebounce
        self.searchDebounce = searchDebounce
    }

    /// The single field.
    var text: String {
        get { model.addDraft }
        set {
            model.addDraft = newValue
            restart(immediately: false)
        }
    }

    var isWorking: Bool {
        switch query.state {
        case .classifying, .searching: true
        default: false
        }
    }

    /// Words for the sheet's current state; nil when the result list speaks for itself.
    var statusMessage: String? {
        switch query.state {
        case .idle: "Search for a podcast, or paste a link to a feed, a show or an article."
        case .classifying: "Checking that address\u{2026}"
        case .searching: "Searching\u{2026}"
        case let .results(results): results.isEmpty ? "No podcasts found. Try other words, or paste a link." : nil
        case .article, .podcastFeed: nil
        case let .unsupported(reason): reason
        case .unreachable: "Wilted could not finish that. Check the connection, then try again."
        case .cancelled: "Cancelled. Change the text to start again."
        }
    }

    var rows: [Row] {
        switch query.state {
        case let .results(results):
            return results.map { showRow($0.show, detail: $0.show.author ?? $0.show.feedURL.host ?? "") }
        case .podcastFeed:
            return resolvedShow.map { [showRow($0, detail: $0.feedURL.host ?? "Podcast")] } ?? []
        case let .article(url):
            return [Row(id: "link", title: Self.display(url), detail: "Not sure what this link is. Choose one.", kind: .link(url))]
        default:
            return []
        }
    }

    /// Opens with a clean notice, a fresh read of what the Mac applies, and a restored draft re-evaluated.
    func start() {
        model.addNotice = nil
        Task { await model.loadAddCapability() }
        restart(immediately: true)
    }

    /// Return in the field: answer now rather than after the quiet time.
    func submit() { restart(immediately: true) }

    func cancel() {
        task?.cancel()
        task = nil
        query.cancel()
    }

    /// Hands a row to the model as an add for the Mac. A link needs the listener's `choice`; a send the Mac
    /// refuses keeps the text so nothing typed is lost.
    func send(_ row: Row, as choice: LinkChoice? = nil) async {
        switch row.kind {
        case let .show(feed, following):
            guard !following, row.requestPhase == nil else { return }
            await model.addToMac(.subscribe(feed), title: row.title)
        case let .link(url):
            guard let choice else { return }
            await model.addToMac(choice == .article ? .article(url) : .subscribe(url), title: row.title)
            guard model.addNotice == nil else { return }
            task?.cancel()
            task = nil
            model.addDraft = ""
            resolvedShow = nil
            query = AddQuery()
        }
    }

    /// Lets a test wait for the in-flight classification or search.
    func settle() async { await task?.value }

    // MARK: Private

    private func showRow(_ show: PodcastCatalogShow, detail: String) -> Row {
        let following = model.isFollowing(show.feedURL)
        let entryID = try? ItemID.derivePodcastFeed(from: show.feedURL)
        let add = model.adds.last { $0.isSubscribe && entryID != nil && $0.intent.action.entryID == entryID }
        let phase = add.map(\.phase).flatMap { phase -> PendingAdd.Phase? in
            if case .rejected = phase { nil } else { phase }
        }
        return Row(
            id: "show-\(show.collectionID)", title: show.title, detail: detail,
            kind: .show(feed: show.feedURL, following: following), requestPhase: phase)
    }

    /// An address as a person reads it: host and path, without scheme or trailing slash.
    private static func display(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        let path = url.path == "/" ? "" : url.path
        return host + path
    }

    private func restart(immediately: Bool) {
        task?.cancel()
        task = nil
        resolvedShow = nil
        let effect = query.begin(model.addDraft)
        let delay: Duration
        switch effect {
        case .none: return
        case .classify: delay = immediately ? .zero : linkDebounce
        case .search: delay = immediately ? .zero : searchDebounce
        }
        task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            await self.run(effect)
        }
    }

    private func run(_ effect: AddQuery.Effect) async {
        let answer: AddQuery.Answer?
        switch effect {
        case .none:
            answer = nil
        case let .classify(url, generation):
            answer = await classify(url, generation: generation)
        case .search:
            answer = await AddQuery.run(effect, classify: { _ in .article }, search: search)
        }
        guard let answer, !Task.isCancelled else { return }
        query.apply(answer, isFollowed: { [model] in model.isFollowing($0.feedURL) })
    }

    /// An Apple Podcasts show page resolves through the catalogue; every other link stays `.article`,
    /// which here means "a link whose kind the listener names".
    private func classify(_ url: URL, generation: Int) async -> AddQuery.Answer {
        func answer(_ outcome: AddQuery.Answer.Outcome) -> AddQuery.Answer { .init(generation: generation, outcome: outcome) }
        guard url.host?.lowercased() == "podcasts.apple.com" else { return answer(.classified(.article)) }
        guard let id = PodcastCatalogLookupClient.collectionID(fromApplePodcastURL: url) else {
            return answer(.classified(.unsupported(Self.lookupFailureText(.invalidCollectionID))))
        }
        do {
            let show = try await lookup(id)
            guard generation == query.generation else { return answer(.cancelled) }
            resolvedShow = show
            return answer(.classified(.podcastFeed))
        } catch let error as PodcastCatalogLookupError where error != .cancelled {
            return answer(.classified(.unsupported(Self.lookupFailureText(error))))
        } catch is CancellationError {
            return answer(.cancelled)
        } catch {
            return answer(error as? PodcastCatalogLookupError == .cancelled ? .cancelled : .failed)
        }
    }

    static func lookupFailureText(_ error: PodcastCatalogLookupError) -> String {
        switch error {
        case .invalidCollectionID:
            "That Apple Podcasts address is not a supported show link."
        case .resultNotFound:
            "Apple Podcasts has no show at that link, or it has no public feed. Check the link or paste the feed address."
        case .timedOut:
            "Apple Podcasts took too long to answer. Retry when online."
        case .invalidResponse, .responseTooLarge, .unsafeRedirect:
            "Apple Podcasts gave an answer Wilted could not use. Retry later or paste the feed address."
        case .cancelled:
            "Cancelled. Change the text to start again."
        }
    }
}

#if DEBUG
/// DEBUG-only: what the Add sheet's Mac does inside the fixture's pixel scenario, chosen by
/// `--wilted-library-add-mac=ready|old|rejects-no-audio`. The fixture's in-memory Mac neither publishes
/// the actions it applies nor answers intents, so the captures need this stand-in; it is compiled out of
/// release builds and inert outside `--wilted-library-root-scenario=pixel`.
@MainActor
enum LibraryAddUITestSeam {
    enum Mac: String {
        /// Advertises both add actions and never answers: an add stays "Sent to your Mac".
        case ready
        /// Advertises nothing, like a Mac that predates the Add flow.
        case old
        /// Advertises both and refuses every add because the feed has no audio.
        case rejectsNoAudio = "rejects-no-audio"
    }

    static let argumentPrefix = "--wilted-library-add-mac="

    static var mac: Mac? {
        guard LibraryUITestFixture.scenario() == .pixel else { return nil }
        let raw = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(argumentPrefix) }?
            .dropFirst(argumentPrefix.count)
        return raw.flatMap { Mac(rawValue: String($0)) } ?? .ready
    }

    nonisolated static let shows: [PodcastCatalogShow] = [
        PodcastCatalogShow(
            collectionID: 9_001, title: "The Slow Garden", feedURL: URL(string: "https://feeds.example.com/slow-garden.xml")!,
            author: "Field Notes Audio"),
        PodcastCatalogShow(
            collectionID: 9_002, title: "Evening Compost", feedURL: URL(string: "https://feeds.example.com/evening-compost.xml")!,
            author: "Greenhouse Radio"),
        PodcastCatalogShow(
            collectionID: 9_003, title: "Seeds and Stories", feedURL: URL(string: "https://feeds.example.com/seeds.xml")!,
            author: "Open Plot")
    ]
}
#endif
