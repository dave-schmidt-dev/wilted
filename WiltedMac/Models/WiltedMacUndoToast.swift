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
    let subjects: Set<String>
    /// When the toast lets go of this offer.
    let offeredUntil: Date
    /// When the undo itself stops working. A held toast never outlasts it.
    let availableUntil: Date
}

/// The undo toast's state: the reversible actions still on offer, newest last.
///
/// An action that is easy to press by mistake and can be reversed calls `offer` once its write has
/// committed. The toast then shows the newest offer for `offerSeconds` with an Undo button, and the
/// window's Edit > Undo (Command-Z) takes back the same thing. The action has already happened, so
/// an offer that runs out changes nothing: it only stops being offered.
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
    @ObservationIgnored private var actions: [UUID: @MainActor () -> Void] = [:]
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
    ///   - undo: Reverses the action. It runs at most once.
    /// - Returns: The offer's id, or nil when the undo has already stopped working.
    @discardableResult
    func offer(
        message: String, actionName: String, subjects: Set<String> = [],
        availableUntil: Date? = nil, undo: @escaping @MainActor () -> Void
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
        registrations[offer.id] = Registration(offerID: offer.id)
        register(offer)
        scheduleExpiry()
        return offer.id
    }

    /// Takes back the newest offer: the toast's Undo button.
    func undoCurrent() {
        if let current { undo(current.id) }
    }

    /// Takes back one offer. An offer that has run out or was already taken back does nothing.
    func undo(_ id: UUID) {
        guard let action = actions[id] else { return }
        forget(id)
        scheduleExpiry()
        action()
    }

    /// Stops offering every undo that would put back one of `subjects`, because it no longer can.
    func withdraw(subjects: Set<String>) {
        let gone = offers.filter { !$0.subjects.isDisjoint(with: subjects) }
        guard !gone.isEmpty else { return }
        for offer in gone { forget(offer.id) }
        scheduleExpiry()
    }

    /// Stops offering everything, for a library that is closing.
    func withdrawAll() {
        for offer in offers { forget(offer.id) }
        scheduleExpiry()
    }

    /// The pointer came to rest on the toast, or left it.
    func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
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
        guard let undoManager, let registration = registrations[offer.id] else { return }
        // Its own group, so each offer is one step of Undo whether or not the run loop groups events.
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: registration) { [weak self] registration in
            MainActor.assumeIsolated { self?.undo(registration.offerID) }
        }
        undoManager.setActionName(offer.actionName)
        undoManager.endUndoGrouping()
    }

    private func forget(_ id: UUID) {
        offers.removeAll { $0.id == id }
        actions[id] = nil
        guard let registration = registrations.removeValue(forKey: id), let undoManager else { return }
        // While the undo stack is running this very entry it removes the entry itself.
        if !undoManager.isUndoing { undoManager.removeAllActions(withTarget: registration) }
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
            let time = self.now()
            for offer in self.offers where self.expiry(of: offer) <= time { self.forget(offer.id) }
            self.scheduleExpiry()
        }
    }
}
