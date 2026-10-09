import Foundation
import ObjectiveC
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer

// MARK: - Activity

/// What the library publisher and the inbound poller last did on this Mac (Task 5.2).
///
/// Only local facts: a time here is this Mac's own send or read, never the phone's fetch, and a
/// count is nil whenever the publisher cannot know it (no baseline yet, or a pass that stopped
/// before it diffed). Nothing here claims the phone has converged.
struct WiltedMacLibrarySyncActivity: Equatable, Sendable {
    /// A Sync now press is running.
    var isSyncing = false
    /// Changes the last pass computed that iCloud has not acknowledged; nil when unknown.
    var unsentChanges: Int?
    /// When iCloud last acknowledged library content or an author receipt this Mac sent.
    var lastSentAt: Date?
    /// The last publish pass failed for a reason other than a pause (throttle or account).
    var sendFailed = false
    /// When this Mac last finished an inbound round: the phone's requests and positions read and applied.
    var lastCheckedAt: Date?
    /// The last inbound round failed for a reason other than a pause.
    var checkFailed = false
    /// The account review was approved this launch; cleared by the next acknowledged send.
    var accountReviewed = false
    /// At least one publish pass finished this launch.
    var hasFinishedPass = false
    /// Durable author evidence, kept distinct from this launch’s local send/read times.
    var publication: LibraryPublication?
    var publicationOwner: String?

    mutating func recordSend(acknowledged: Int, unsent: Int?, publicationCompleted: Bool = false, at date: Date) {
        hasFinishedPass = true
        sendFailed = false
        unsentChanges = unsent
        guard acknowledged > 0 || publicationCompleted else { return }
        lastSentAt = date
        accountReviewed = false
    }

    mutating func recordSendFailure(unsent: Int?) {
        hasFinishedPass = true
        sendFailed = true
        unsentChanges = unsent
    }

    mutating func recordCheck(succeeded: Bool, at date: Date) {
        checkFailed = !succeeded
        if succeeded { lastCheckedAt = date }
    }
}

// MARK: - Status

/// The Sync card's one status line for the library publisher, resolved from the account binding,
/// the shared throttle and the local activity. Account states come first because nothing is sent
/// while they hold; a throttle comes next because it pauses every call.
struct WiltedMacLibrarySyncStatus: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case unavailable, transportUnavailable, awaitingAccount, reviewRequired, approvedAwaitingAccount
        case noAccount, accountUnavailable, accountFailed, throttled, working, sendFailed, checkFailed
        case pending, sent, idle, waiting
    }

    static let reviewTitle = "Review this library"
    static let reviewExplanation = WiltedScreenCopy.macAccountReviewDetail
    static let approveReview = "Use reviewed account"
    static let keepHeld = "Keep held"
    /// Says whose times the card shows, so a send is never read as the phone's fetch.
    static let scopeNote = "These times are this Mac's own sends and reads. The phone shows its own last fetch."

    let phase: Phase
    let headline: String
    let tone: WiltedStatusTone
    let canSyncNow: Bool
    /// Why the library is held, shown in the review dialog; nil when there is nothing to review.
    let reviewContext: String?

    private init(
        _ phase: Phase, _ headline: String, tone: WiltedStatusTone = .neutral, canSyncNow: Bool = false,
        reviewContext: String? = nil
    ) {
        self.phase = phase
        self.headline = headline
        self.tone = tone
        self.canSyncNow = canSyncNow
        self.reviewContext = reviewContext
    }

    /// - Parameter account: nil when the publisher is selected but not running.
    static func resolve(
        account: WiltedMacLibraryAccountStatus?, throttle: TransportGateState?,
        activity: WiltedMacLibrarySyncActivity, now: Date = Date()
    ) -> Self {
        guard let account else {
            return Self(.unavailable, "Library sync is not running on this Mac", tone: .caution)
        }
        if let held = accountHold(account) { return held }
        if throttle != nil {
            return Self(.throttled, "iCloud paused requests. Sync now is available after the retry time",
                        tone: .caution)
        }
        if activity.isSyncing {
            let headline = activity.unsentChanges.flatMap { $0 > 0 ? "Sending \(changes($0))…" : nil }
                ?? "Syncing this Mac's library…"
            return Self(.working, headline, tone: .active)
        }
        if activity.sendFailed {
            let kept = activity.unsentChanges.flatMap { $0 > 0 ? "\(changes($0)) kept for retry" : nil }
                ?? "Library changes are kept for retry"
            return Self(.sendFailed, "Send failed. \(kept).", tone: .failure, canSyncNow: true)
        }
        if activity.checkFailed {
            return Self(.checkFailed, "Reading phone changes failed. The next sync round retries.",
                        tone: .failure, canSyncNow: true)
        }
        let reviewed = activity.accountReviewed ? "Account reviewed. " : ""
        if let unsent = activity.unsentChanges, unsent > 0 {
            return Self(.pending, "\(reviewed)\(changes(unsent)) waiting to send", canSyncNow: true)
        }
        if let sent = activity.lastSentAt {
            return Self(.sent, "Local changes sent at \(time(sent, now: now)). Phone fetch is separate.",
                        tone: .positive, canSyncNow: true)
        }
        if activity.hasFinishedPass {
            return Self(.idle, "\(reviewed)Nothing waiting to send from this Mac", canSyncNow: true)
        }
        return Self(.waiting, "\(reviewed)Waiting for the first sync round", canSyncNow: true)
    }

    private static func accountHold(_ account: WiltedMacLibraryAccountStatus) -> Self? {
        switch account {
        case .unmanaged, .active:
            return nil
        case .awaitingAccount:
            return Self(.awaitingAccount, "Checking the iCloud account before sending", tone: .active)
        case let .reviewRequired(reason):
            return reason == .unboundLibrary
                ? Self(.reviewRequired, "Review account before sending this library", tone: .caution,
                       reviewContext: "This existing library has no account binding.")
                : Self(.reviewRequired, "Account changed. Library changes are held for review", tone: .caution,
                       reviewContext: "This library belongs to the previous account. Sending is paused.")
        case .approvedAwaitingAccount:
            return Self(.approvedAwaitingAccount,
                        "Account reviewed. Sending starts when iCloud reports a signed-in account", tone: .caution)
        case .noAccount:
            return Self(.noAccount, "No iCloud account is signed in. Library changes stay on this Mac",
                        tone: .caution)
        case .accountUnavailable:
            return Self(.accountUnavailable, "The iCloud account could not be checked. Library changes stay on this Mac",
                        tone: .caution)
        case .failed:
            return Self(.accountFailed, "This library's account record could not be read. Nothing is sent",
                        tone: .failure)
        case .transportUnavailable:
            return Self(.transportUnavailable, "iCloud library sync could not start. Nothing is sent",
                        tone: .failure)
        }
    }

    private static func changes(_ count: Int) -> String {
        count == 1 ? "1 library change" : "\(count) library changes"
    }

    private static func time(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A row value for one of this Mac's own success times.
    static func timeLabel(_ date: Date?, now: Date = Date()) -> String {
        date.map { time($0, now: now) } ?? "Not yet this launch"
    }
}

// MARK: - UI fixture

/// Scripted, no-network library-publisher states for UI tests and walkthrough captures. Pass
/// `--wilted-ui-fixture-library-sync <scenario>` together with another fixture argument (the
/// fixture launch is what keeps the real publisher off). It sets the same model state the live
/// publisher sets and answers Sync now and account review the way the live owner does.
enum WiltedMacLibrarySyncFixtureScenario: String, CaseIterable, Sendable {
    case pending, working, failure, sent, throttled, unbound, switched
    case approvedAwaitingAccount = "approved-awaiting-account"
    case noAccount = "no-account"
    case accountUnavailable = "account-unavailable"
    case transportUnavailable = "transport-unavailable"

    static let argument = "--wilted-ui-fixture-library-sync"

    static func scenario(in arguments: [String]) -> Self? {
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
        return Self(rawValue: arguments[index + 1])
    }

    /// The fixed send time a scripted Sync now reports: 10:15 today.
    static func sentAt(now: Date = Date()) -> Date {
        Calendar.current.date(bySettingHour: 10, minute: 15, second: 0, of: now) ?? now
    }

    var account: WiltedMacLibraryAccountStatus {
        switch self {
        case .unbound: .reviewRequired(.unboundLibrary)
        case .switched: .reviewRequired(.switchAccounts)
        case .approvedAwaitingAccount: .approvedAwaitingAccount
        case .noAccount: .noAccount
        case .accountUnavailable: .accountUnavailable
        case .transportUnavailable: .transportUnavailable
        case .pending, .working, .failure, .sent, .throttled: .active
        }
    }

    var activity: WiltedMacLibrarySyncActivity {
        var activity = WiltedMacLibrarySyncActivity(unsentChanges: 2, hasFinishedPass: true)
        switch self {
        case .working: activity.isSyncing = true
        case .sent: activity.recordSend(acknowledged: 2, unsent: 0, at: Self.sentAt())
        default: break
        }
        return activity
    }
}

private nonisolated(unsafe) var librarySyncFixtureKey: UInt8 = 0

private final class WiltedMacLibrarySyncFixtureBox {
    let scenario: WiltedMacLibrarySyncFixtureScenario
    init(_ scenario: WiltedMacLibrarySyncFixtureScenario) { self.scenario = scenario }
}

// MARK: - Model surface

extension WiltedMacModel {
    /// The scripted library-publisher scenario of a UI fixture launch, or nil.
    var librarySyncFixture: WiltedMacLibrarySyncFixtureScenario? {
        (objc_getAssociatedObject(self, &librarySyncFixtureKey) as? WiltedMacLibrarySyncFixtureBox)?.scenario
    }

    /// Whether Settings shows the library publisher's card: it is this launch's selected engine, or a
    /// fixture scripts it. A selected publisher never falls back to the legacy "Disabled" card.
    var showsLibraryPublisherSync: Bool {
        librarySyncFixture != nil || libraryRuntimeSelection().engine == .libraryPublisher
    }

    var libraryPublicationVerified: Bool {
        guard let owner = librarySyncActivity.publicationOwner else { return false }
        return libraryAccount?.approvedPublicationOwner == owner && libraryAccountStatus == .active
    }
    var libraryPublicationSummary: String {
        WiltedPublicationAge.summary(librarySyncActivity.publication?.publishedAt, verified: libraryPublicationVerified)
    }
    var libraryPublicationDetail: String { WiltedPublicationAge.detail(librarySyncActivity.publication?.publishedAt) }
    var libraryPublicationQualifier: String? {
        WiltedPublicationAge.qualifier(verified: libraryPublicationVerified, pending: librarySyncActivity.isSyncing,
            failed: librarySyncActivity.sendFailed || librarySyncActivity.checkFailed, held: libraryAccountStatus?.needsReview == true)
    }

    var librarySyncStatus: WiltedMacLibrarySyncStatus {
        .resolve(account: libraryAccountStatus, throttle: libraryThrottle, activity: librarySyncActivity)
    }

    /// The one Sync now action: a press while a sync runs joins it instead of starting another.
    @discardableResult
    func syncLibraryNow() -> Task<Void, Never>? {
        guard librarySyncStatus.canSyncNow else { return nil }
        if librarySyncFixture != nil { return runFixtureSyncNow() }
        return librarySyncController?.syncNow()
    }

    /// Approves the held library for the reviewed account ("Use reviewed account").
    @discardableResult
    func reviewLibraryAccount() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self, self.libraryAccountStatus?.needsReview == true else { return }
            // Noted before the account opens, so the first send after it can clear the note.
            self.librarySyncActivity.accountReviewed = true
            if self.librarySyncFixture != nil {
                self.libraryAccountStatus = .active
            } else if !(await self.approveLibraryAccountReview()) {
                self.librarySyncActivity.accountReviewed = false
            }
        }
    }

    /// Records one inbound round. A pause (throttle or account) is reported by its own state.
    func recordLibraryCheck(_ error: (any Error)?) {
        if let error, WiltedMacLibrarySyncController.isPause(error) { return }
        var next = librarySyncActivity
        next.recordCheck(succeeded: error == nil, at: Date())
        if next != librarySyncActivity { librarySyncActivity = next }
    }

    func installLibrarySyncFixture(_ scenario: WiltedMacLibrarySyncFixtureScenario) {
        objc_setAssociatedObject(
            self, &librarySyncFixtureKey, WiltedMacLibrarySyncFixtureBox(scenario), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        libraryAccountStatus = scenario.account
        librarySyncActivity = scenario.activity
        if scenario == .throttled {
            libraryThrottle = TransportGateState(
                kind: .rateLimited, retryAt: Date().addingTimeInterval(120), consecutiveFailures: 1)
        }
    }

    private func runFixtureSyncNow() -> Task<Void, Never>? {
        guard let scenario = librarySyncFixture, !librarySyncActivity.isSyncing else { return nil }
        librarySyncActivity.isSyncing = true
        return Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self else { return }
            var next = self.librarySyncActivity
            next.isSyncing = false
            if scenario == .failure {
                next.recordSendFailure(unsent: next.unsentChanges)
            } else {
                next.recordSend(acknowledged: next.unsentChanges ?? 0, unsent: 0,
                                at: WiltedMacLibrarySyncFixtureScenario.sentAt())
            }
            self.librarySyncActivity = next
        }
    }
}
#endif
