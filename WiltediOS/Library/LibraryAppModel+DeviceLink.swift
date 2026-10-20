import Foundation
import OSLog
import UIKit
import WiltedDomain
import WiltedLibrary

private let linkLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryDeviceLink")

/// What the wait for the Mac's answer to one media request ended with.
enum LibraryMediaAnswer: Sendable {
    /// The Mac published its `ready` or `notReady` offer. The offer is the source of truth, at any stage.
    case offer(LibraryMediaOffer)
    /// The Mac stayed silent, or stalled, past the limit for the stage it reported last.
    case macNotAnswering
    /// The Mac reported that it could not answer, in its own plain words.
    case failed(String)
}

/// The saved fact that the Mac linked this device, so a relaunch without signal still knows. It names the
/// library owner it was learned under, so a different account never inherits it.
struct LibrarySavedMacLink: Codable, Equatable, Sendable {
    let deviceID: String
    let ownerToken: String?
}

/// What the model keeps of the device handshake between rounds. A class so the model's extension can hold
/// state without stored properties of its own; touched only on the main actor.
@MainActor
final class LibraryDeviceLinkState {
    /// The newest link the Mac wrote for this device. A failed read, or a read that finds nothing, never clears it.
    var link: LibraryDeviceLink?
    /// When the phone last tried to announce itself, whether or not the try worked.
    var lastAnnounceAttempt: Date?
}

/// The phone's side of the device handshake (`DeviceLink`): it announces itself until the Mac links it,
/// reads the Mac's link every round, and follows each media request through the stages the Mac reports.
extension LibraryAppModel {
    /// The announcements share one directory record every device writes, so a phone that is still
    /// unlinked tries again only this often.
    static let announceInterval: TimeInterval = 10 * 60
    static let savedMacLinkKey = "wilted.library.macLink"

    /// "iPad" or "iPhone": the model family only, never the person's name for the device (W-INV-031).
    static var currentDeviceKind: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    // MARK: - The link

    /// True when the Larder should say it is still connecting: unlinked, and not held for an account review
    /// (which has its own banner and nothing to wait for).
    var showsMacLinkNotice: Bool { !deviceLinked && !accountQuarantined }

    private var savedMacLink: LibrarySavedMacLink? {
        preferences.data(forKey: Self.savedMacLinkKey).flatMap { try? JSONDecoder().decode(LibrarySavedMacLink.self, from: $0) }
    }

    /// At the local load: a link learned under this owner on an earlier run still counts.
    func restoreDeviceLink(owner: String?) {
        guard !deviceLinked, let saved = savedMacLink, saved.deviceID == deviceID, saved.ownerToken == owner else { return }
        deviceLinked = true
    }

    /// The round's read of the link. Only a link for this device counts; a read that failed, found nothing
    /// or found another device's link changes nothing, so a linked device never goes back to unlinked.
    func applyPolledDeviceLink(_ result: LibraryPollResult, owner: String?) {
        guard result.deviceLinkRead else { return }
        noteDeviceLink(result.deviceLink, owner: owner)
    }

    func noteDeviceLink(_ link: LibraryDeviceLink?, owner: String?) {
        guard let link, link.deviceID == deviceID else { return }
        deviceLinkState.link = link
        if !deviceLinked {
            deviceLinked = true
            linkLog.notice("The Mac linked this device.")
        }
        let saved = LibrarySavedMacLink(deviceID: deviceID, ownerToken: owner)
        if savedMacLink != saved, let data = try? JSONEncoder().encode(saved) {
            preferences.set(data, forKey: Self.savedMacLinkKey)
        }
    }

    /// The account changed: the Mac that linked this device belonged to the previous account's library.
    func discardDeviceLinkAfterAccountChange() {
        deviceLinked = false
        deviceLinkState.link = nil
        deviceLinkState.lastAnnounceAttempt = nil
        preferences.removeObject(forKey: Self.savedMacLinkKey)
    }

    // MARK: - Announcing

    /// While the Mac has not linked this device, adds it to the shared device directory so the Mac reads its
    /// requests at its next round instead of after a zone scan. Never while the account is held, unbound
    /// or under review (W-INV-021), and at most once per `announceInterval`; a failure waits for the next
    /// interval too. `linkRead` is true when this round read the link, which also proves the phone is online.
    func announceDeviceIfNeeded(linkRead: Bool) async {
        guard linkRead, !deviceLinked else { return }
        let state = deviceLinkState, current = now()
        // A clock set back counts as an interval passed, so it can never silence the announcement.
        if let last = state.lastAnnounceAttempt, current >= last, current.timeIntervalSince(last) < Self.announceInterval { return }
        guard await mediaContext(live: true) != nil else { return }
        state.lastAnnounceAttempt = current
        let kind = deviceKind
        do {
            try await transport.announceDevice(LibraryDeviceAnnouncement(deviceID: deviceID, kind: kind, announcedAt: current))
            linkLog.notice("Announced this \(kind, privacy: .public) to the Mac.")
        } catch {
            let detail = MediaFetchErrorClassifier.logDescription(error)
            linkLog.error("Could not announce this device: \(detail, privacy: .public)")
        }
    }

    // MARK: - Waiting for the Mac

    /// Waits for the Mac's answer to the request `intentID` until a `ready` (or `notReady`) offer for `entryID`
    /// appears, the Mac reports that it failed, or it goes quiet for longer than its stage allows. An `available`
    /// offer is the Mac's standing statement that the audio is prepared, not an answer, so it keeps waiting.
    ///
    /// The limits depend on the stage the Mac last reported (`LibraryDeviceLink`), each counted from when
    /// the phone first saw that stage: silence, `offerTimeout`; `received`, `queuedTimeout` (the Mac uploads
    /// one request at a time, so a request can wait a long time in line); `sending`, `sendingTimeout`;
    /// `answered`, `answeredTimeout` for the offer to show, then one direct read. `failed` ends the wait at once.
    /// The offer wins at every stage, including when the Mac has not reported one at all.
    ///
    /// While the sync tick runs, its rounds read the offers and the link and this only looks at what they
    /// found, so a request costs no reads of its own, except a single read of each at half of
    /// `offerTimeout`, in case the rounds missed the answer. Without a tick (the app is not in front) it reads
    /// both itself every `pollInterval`. A failing read is retried rather than ending the request.
    func awaitAnswer(
        for entryID: ItemID, intentID: String, runID: UUID, context: LibraryMediaContext
    ) async throws -> LibraryMediaAnswer {
        let timing = mediaTiming, clock = ContinuousClock()
        let start = clock.now
        let halfway = start.advanced(by: timing.offerTimeout / 2)
        let requestedAt = now()
        let requestedSince = media[entryID]?.startedAt ?? requestedAt
        var stage: LibraryMediaRequestStatus.Stage?
        var stageSince = start
        var rechecked = false
        while true {
            try Task.checkCancellation()
            guard isCurrent(entryID, runID), await mediaContextIsCurrent(context, entryID: entryID, live: true) else {
                throw LibraryTransportError.superseded
            }
            let ticking = tickState.tick != nil
            if ticking, let readAt = tickState.offersReadAt, readAt >= requestedAt,
               let offer = tickState.offers[entryID], offer.state != .available { return .offer(offer) }
            let recheck = ticking && !rechecked && clock.now >= halfway
            if !ticking || recheck {
                rechecked = rechecked || recheck
                if let offer = try await readOffer(for: entryID, context: context) { return .offer(offer) }
                noteDeviceLink(try? await transport.fetchDeviceLink(), owner: context.ownerToken)
            }
            if let status = deviceLinkState.link?.status(intentID: intentID), Self.rank(status.stage) > Self.rank(stage) {
                stage = status.stage
                stageSince = clock.now
                switch status.stage {
                case .failed: return .failed(Self.failureText(status.detail))
                case .answered: break // the offer follows; the row keeps what it said
                case .received: setMedia(.requested(since: requestedSince, stage: .queued), entryID, runID)
                case .sending: setMedia(.requested(since: requestedSince, stage: .sending), entryID, runID)
                }
            }
            let waited = clock.now - stageSince
            switch stage {
            case nil where waited >= timing.offerTimeout: return .macNotAnswering
            case .received? where waited >= timing.queuedTimeout: return .macNotAnswering
            case .sending? where waited >= timing.sendingTimeout: return .macNotAnswering
            case .answered? where waited >= timing.answeredTimeout:
                if let offer = try await readOffer(for: entryID, context: context) { return .offer(offer) }
                return .macNotAnswering
            default: break
            }
            // Looking at the tick's findings costs nothing, so that check is quick.
            try await Task.sleep(for: ticking ? min(timing.pollInterval, .seconds(1)) : timing.pollInterval)
        }
    }

    /// How far a request has got; a stage a later read reports lower is a stale read and changes nothing.
    private static func rank(_ stage: LibraryMediaRequestStatus.Stage?) -> Int {
        switch stage {
        case nil: 0
        case .received?: 1
        case .sending?: 2
        case .answered?: 3
        case .failed?: 4
        }
    }

    /// The Mac's reason in its own words, or the generic sentence when it gave none.
    static func failureText(_ detail: String?) -> String {
        let reason = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? text(for: MediaFetchFailure.other) : reason
    }
}
