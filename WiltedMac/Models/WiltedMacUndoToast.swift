import AppKit
import Foundation
import Observation

/// One reversible action the undo toast is offering.
struct WiltedMacUndoOffer: Identifiable, Equatable, Sendable {
    let id: UUID
    /// What happened, as the toast says it: "Marked Quiet Machines completed."
    let message: String
    /// The Edit menu's words after "Undo": "Mark Completed".
    let actionName: String
    /// The rows Undo would put back, so the offer can be withdrawn when one of them is gone.
    var subjects: Set<String>
    /// When the toast lets go of this offer.
    let offeredUntil: Date
    /// When the undo itself stops working. A held toast never outlasts it.
    let availableUntil: Date
}

/// What running an undo came to.
enum WiltedMacUndoResult: Sendable {
    /// The undo was carried out, or can never be: the offer is spent.
    case done
    /// The undo could not start just now (something else was still saving). The offer stays open for
    /// as long as its window lasts, so the owner can press Undo again.
    case retry
}

/// The undo toast's state: the reversible actions still on offer, newest last.
///
/// An action that is easy to press by mistake and can be reversed calls `offer` once its write has
/// committed. The toast then shows the newest offer for `offerSeconds` with an Undo button, and the
/// window's Edit > Undo (Command-Z) takes back the same thing. The action has already happened, so
/// an offer that runs out changes nothing: it only stops being offered, and an Undo pressed after
/// its window has closed does nothing either. A caller that must finish something once its offer
/// ends for good (expired, or withdrawn) passes `onClose`; it does not run after an undo.
///
/// Each offer keeps its own five seconds. A second action while a toast is showing is stacked on
/// the first rather than replacing it, so two quick mistakes can both be taken back, newest first.
/// The toast waits for as long as the pointer rests on it or VoiceOver is running, up to the
/// moment the undo itself would stop working.
@MainActor @Observable
final class WiltedMacUndoToastCenter {
    /// How long the toast offers one undo.
    static let offerSeconds: TimeInterval = 5
    /// The longest a held toast waits when the caller names no limit of its own.
    static let holdSeconds: TimeInterval = 10

    /// Every offer still open, oldest first.
    private(set) var offers: [WiltedMacUndoOffer] = []
    /// True while the pointer rests on the toast.
    private(set) var isHeld = false

    /// The offer the toast shows and Undo acts on.
    var current: WiltedMacUndoOffer? { offers.last }
    /// How many earlier offers wait behind the one showing.
    var earlierCount: Int { max(0, offers.count - 1) }

    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async throws -> Void
    @ObservationIgnored private let prefersLongOffer: @MainActor () -> Bool
    @ObservationIgnored private var actions: [UUID: @MainActor () -> WiltedMacUndoResult] = [:]
    @ObservationIgnored private var closers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var narrowers: [UUID: @MainActor (Set<String>) -> Void] = [:]
    /// Offers whose undo is running right now, so a withdrawal inside it is not a close.
    @ObservationIgnored private var undoing: Set<UUID> = []
    /// Offers whose entry on the window's undo stack was used up by a Command-Z and not yet replaced.
    @ObservationIgnored private var spentStackEntries: Set<UUID> = []
    @ObservationIgnored private var registrations: [UUID: Registration] = [:]
    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// - Parameters:
    ///   - now: The wall clock; tests pass a clock they move by hand.
    ///   - sleep: Waits that many seconds on the same clock.
    ///   - prefersLongOffer: True when five seconds is too short to reach Undo, as with VoiceOver.
    init(
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        prefersLongOffer: @escaping @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    ) {
        self.now = now
        self.sleep = sleep
        self.prefersLongOffer = prefersLongOffer
    }

    /// Offers to undo an action that has already committed.
    ///
    /// - Parameters:
    ///   - message: What happened, as a sentence.
    ///   - actionName: The Edit menu's words after "Undo".
    ///   - subjects: The rows Undo would put back.
    ///   - availableUntil: When the undo stops working; nil allows `holdSeconds`.
    ///   - onClose: Runs once if the offer ends without being taken: it ran out or was withdrawn.
    ///   - narrow: Given the subjects that left, when only some of the offer's subjects are withdrawn. The
    ///     offer then stays open for the rest; without it, any withdrawal ends the whole offer.
    ///   - undo: Reverses the action and says whether it did. Returning `.retry` keeps the offer open.
    /// - Returns: The offer's id, or nil when the undo has already stopped working (`onClose` has
    ///   not run then: the caller learns of it from the nil).
    @discardableResult
    func offer(
        message: String, actionName: String, subjects: Set<String> = [],
        availableUntil: Date? = nil, onClose: (@MainActor () -> Void)? = nil,
        narrow: (@MainActor (Set<String>) -> Void)? = nil,
        undo: @escaping @MainActor () -> WiltedMacUndoResult
    ) -> UUID? {
        let start = now()
        let limit = availableUntil ?? start.addingTimeInterval(Self.holdSeconds)
        guard limit > start else { return nil }
        let offer = WiltedMacUndoOffer(
            id: UUID(), message: message, actionName: actionName, subjects: subjects,
            offeredUntil: prefersLongOffer() ? limit : min(limit, start.addingTimeInterval(Self.offerSeconds)),
            availableUntil: limit
        )
        offers.append(offer)
        actions[offer.id] = undo
        closers[offer.id] = onClose
        narrowers[offer.id] = narrow
        registrations[offer.id] = Registration(offerID: offer.id)
        register(offer)
        scheduleExpiry()
        return offer.id
    }

    /// An undo that always completes.
    @discardableResult
    func offer(
        message: String, actionName: String, subjects: Set<String> = [],
        availableUntil: Date? = nil, undo: @escaping @MainActor () -> Void
    ) -> UUID? {
        offer(message: message, actionName: actionName, subjects: subjects, availableUntil: availableUntil) {
            undo()
            return .done
        }
    }

    /// Takes back the newest offer: the toast's Undo button.
    func undoCurrent() {
        if let current { undo(current.id) }
    }

    /// Takes back one offer. An offer that was already taken back does nothing, and neither does one
    /// whose window has closed, even if the expiry timer has not fired yet: it is closed instead.
    func undo(_ id: UUID) {
        // Command-Z pops an entry off the window's undo stack before running it, and that entry is
        // spent whatever happens next. The newest offer is always the one Command-Z takes back, so an
        // entry left over from a busy undo still reaches it, not an older offer.
        let fromUndoStack = undoManager?.isUndoing == true
        var id = id
        if fromUndoStack {
            spentStackEntries.insert(id)
            if let newest = offers.last?.id { id = newest }
        }
        defer {
            // The stack is busy until this returns, so entries that must go back on it do so right
            // after. Until then the redirect above keeps Command-Z on the newest offer.
            if fromUndoStack, !spentStackEntries.isEmpty {
                Task { @MainActor [weak self] in self?.reregisterSpentEntries() }
            }
        }
        guard let action = actions[id], let offer = offers.first(where: { $0.id == id }) else { return }
        guard expiry(of: offer) > now() else {
            forget(id, closing: true)
            scheduleExpiry()
            return
        }
        undoing.insert(id)
        let result = action()
        undoing.remove(id)
        if result == .done { forget(id, closing: false) }
        scheduleExpiry()
    }

    /// Stops offering every undo that would put back one of `subjects`, because it no longer can.
    func withdraw(subjects: Set<String>) {
        let gone = offers.filter { !$0.subjects.isDisjoint(with: subjects) }
        guard !gone.isEmpty else { return }
        for offer in gone {
            let leaving = offer.subjects.intersection(subjects)
            if let narrow = narrowers[offer.id], leaving != offer.subjects,
               let index = offers.firstIndex(where: { $0.id == offer.id }) {
                // Only some of what the offer would put back is gone: the rest stays on offer.
                offers[index].subjects.subtract(leaving)
                narrow(leaving)
            } else {
                forget(offer.id, closing: true)
            }
        }
        scheduleExpiry()
    }

    /// Stops offering everything, for a library that is closing.
    func withdrawAll() {
        for offer in offers { forget(offer.id, closing: true) }
        scheduleExpiry()
    }

    /// The pointer came to rest on the toast, or left it.
    func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        // An offer already past its window under the old rule is over: holding must not revive it.
        closeExpired()
        isHeld = held
        scheduleExpiry()
    }

    /// Connects the offers to the window's undo stack, so Edit > Undo and Command-Z reach them.
    ///
    /// The window's own undo manager is used rather than a Command-Z shortcut on the toast, so a
    /// text field that is being edited keeps its own Undo and the newest change is undone first.
    func attach(_ manager: UndoManager?) {
        guard manager !== undoManager else { return }
        if let undoManager {
            for registration in registrations.values { undoManager.removeAllActions(withTarget: registration) }
        }
        undoManager = manager
        for offer in offers { register(offer) }
    }

    /// What VoiceOver hears when an offer appears.
    nonisolated static func announcement(for offer: WiltedMacUndoOffer) -> String {
        "\(offer.message) Press Command-Z to undo."
    }

    // MARK: Internals

    /// The undo stack's handle on one offer. Each offer has its own, so one can leave the stack
    /// without disturbing the others or a text field's own entries.
    private final class Registration: NSObject {
        let offerID: UUID
        init(offerID: UUID) { self.offerID = offerID }
    }

    private func register(_ offer: WiltedMacUndoOffer) {
        guard let undoManager, let registration = registrations[offer.id],
              !undoManager.isUndoing, !undoManager.isRedoing else { return }
        // Each offer is its own closed step of Undo. A window's undo stack otherwise folds a whole
        // pass of the run loop into one group that stays open until the pass ends: two offers made
        // in one pass would be undone together, and an offer withdrawn in the pass it was made in
        // would leave an empty "Undo Mark Completed" behind.
        let ownsGroup = undoManager.groupingLevel == 0
        let groupsByEvent = undoManager.groupsByEvent
        if ownsGroup { undoManager.groupsByEvent = false }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: registration) { [weak self] registration in
            MainActor.assumeIsolated { self?.undo(registration.offerID) }
        }
        // Inside a group something else opened, that change keeps the name it gave the step.
        if ownsGroup { undoManager.setActionName(offer.actionName) }
        undoManager.endUndoGrouping()
        if ownsGroup { undoManager.groupsByEvent = groupsByEvent }
    }

    /// Puts the offers whose undo-stack entry was spent back on the stack, oldest first so the newest
    /// is on top again.
    private func reregisterSpentEntries() {
        let spent = spentStackEntries
        spentStackEntries = []
        for offer in offers where spent.contains(offer.id) { register(offer) }
    }

    /// Removes an offer. `closing` says it ended without being taken, so its `onClose` runs, unless
    /// the offer is in the middle of its own undo.
    private func forget(_ id: UUID, closing: Bool) {
        offers.removeAll { $0.id == id }
        spentStackEntries.remove(id)
        actions[id] = nil
        let closer = closers.removeValue(forKey: id)
        narrowers[id] = nil
        if let registration = registrations.removeValue(forKey: id), let undoManager {
            // While the undo stack is running this very entry it removes the entry itself.
            if !undoManager.isUndoing { undoManager.removeAllActions(withTarget: registration) }
        }
        if closing, !undoing.contains(id) { closer?() }
    }

    /// Closes every offer whose window has run out by the clock right now, whether or not its timer has fired.
    private func closeExpired() {
        let time = now()
        for offer in offers where expiry(of: offer) <= time { forget(offer.id, closing: true) }
    }

    private func expiry(of offer: WiltedMacUndoOffer) -> Date {
        isHeld ? offer.availableUntil : offer.offeredUntil
    }

    /// One task waits for the earliest offer to run out, then drops every offer that has.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let next = offers.map(expiry(of:)).min() else { return }
        expiryTask = Task { [weak self] in
            do {
                while let self, self.now() < next {
                    try await self.sleep(max(0, next.timeIntervalSince(self.now())))
                    try Task.checkCancellation()
                }
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.expiryTask = nil
            self.closeExpired()
            self.scheduleExpiry()
        }
    }
}
