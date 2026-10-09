import Foundation
import MediaPlayer

enum LibrarySeekDirection: Equatable, Sendable { case forward, backward }

/// A lock-screen or headset control the player understands.
enum LibraryRemoteCommand: Equatable, Sendable {
    case play, pause, togglePlayPause
    case skipForward(TimeInterval)
    case skipBackward(TimeInterval)
    case seek(to: TimeInterval)
    /// The speed chosen on a system rate control (CarPlay's speed button, Control Center).
    case setRate(Double)
    case beginSeeking(LibrarySeekDirection), endSeeking(LibrarySeekDirection)
}

@MainActor protocol LibraryRemoteCommands: AnyObject {
    /// The handler returns whether the command did anything.
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool)
    func uninstall()
    /// The lengths the lock-screen skip buttons advertise. Optional: doubles need not care.
    func setSkipIntervals(back: TimeInterval, forward: TimeInterval)
}

extension LibraryRemoteCommands {
    func setSkipIntervals(back: TimeInterval, forward: TimeInterval) {}
}

/// One owned hold; its token rejects a superseded task after a direction change.
struct LibraryRemoteSeekState {
    let direction: LibrarySeekDirection
    let wasPlaying: Bool
    var ownerHoldID: UUID?
    let token = UUID()
    var task: Task<Void, Never>?
}

extension LibraryPlayer {
    var isRemoteSeeking: Bool { remoteSeekState != nil }

    func beginRemoteSeeking(_ direction: LibrarySeekDirection, ownerHoldID: UUID? = nil) -> Bool {
        if ownerHoldID == nil { ownedSeekRequest = nil }
        if remoteSeekState?.direction == direction, remoteSeekState?.ownerHoldID == ownerHoldID { return true }
        let wasPlaying = remoteSeekState?.wasPlaying ?? isPlaying
        guard prepareRemoteSeeking() else { return false }
        remoteSeekState?.task?.cancel()
        remoteSeekState = LibraryRemoteSeekState(direction: direction, wasPlaying: wasPlaying, ownerHoldID: ownerHoldID)
        let token = remoteSeekState!.token
        let sleep = remoteSeekSleep, now = remoteSeekNow
        remoteSeekState?.task = Task { [weak self] in
            var previous = now()
            while !Task.isCancelled {
                do { try await sleep(.milliseconds(100)) } catch {
                    if self?.remoteSeekState?.token == token { _ = self?.cancelRemoteSeeking() }
                    return
                }
                guard !Task.isCancelled else { return }
                let current = now(), elapsed = current - previous
                previous = current
                guard let self, self.remoteSeekStep(elapsed: elapsed, token: token) else { return }
            }
        }
        publishNowPlaying()
        return true
    }

    func endRemoteSeeking(_ direction: LibrarySeekDirection) -> Bool {
        guard remoteSeekState?.direction == direction else { return false }
        return cancelRemoteSeeking(resume: true)
    }

    @discardableResult
    func cancelRemoteSeeking(resume: Bool = false) -> Bool {
        guard let state = remoteSeekState else { return true }
        remoteSeekState = nil
        state.task?.cancel()
        return restoreRemoteSeekingPlayback(resume: resume && state.wasPlaying)
    }

    /// The timer and deterministic regression clock share this exact 8x, clamped tick.
    @discardableResult
    func remoteSeekStep(elapsed: TimeInterval, token: UUID? = nil) -> Bool {
        guard let state = remoteSeekState, token == nil || token == state.token else { return false }
        guard elapsed.isFinite, elapsed > 0 else { _ = cancelRemoteSeeking(); return false }
        if !moveRemoteSeeking(by: elapsed * (state.direction == .forward ? 8 : -8)) {
            _ = cancelRemoteSeeking()
            return false
        }
        return true
    }
}

// External UI holds share the car seek loop, but release only their own load/token.
extension LibraryPlayer {
    func beginOwnedSeeking(_ direction: LibrarySeekDirection, holdID: UUID, sessionID: String) async -> Bool {
        guard let item, seekSessionID == sessionID else { return false }
        if remoteSeekState?.ownerHoldID == holdID, remoteSeekState?.direction == direction { return true }
        cancelAdmission()
        let epoch = admissionEpoch
        ownedSeekRequest = (holdID, direction, sessionID, epoch)
        // A superseding request owns the existing admitted hold while its new direction awaits admission.
        remoteSeekState?.ownerHoldID = holdID
        let admitted = await authorizePlayback?(item) ?? true
        guard ownedSeekRequest?.id == holdID, ownedSeekRequest?.sessionID == sessionID,
              seekSessionID == sessionID, self.item == item, admissionEpoch == epoch else { return false }
        guard admitted else { ownedSeekRequest = nil; invalidateLoadedItem(); return false }
        return beginRemoteSeeking(direction, ownerHoldID: holdID)
    }

    func endOwnedSeeking(_ direction: LibrarySeekDirection, holdID: UUID, sessionID: String) async -> Bool {
        guard seekSessionID == sessionID, ownedSeekRequest?.id == holdID,
              ownedSeekRequest?.direction == direction else { return false }
        guard remoteSeekState?.ownerHoldID == holdID || ownedSeekRequest?.epoch == admissionEpoch else {
            ownedSeekRequest = nil; return false
        }
        ownedSeekRequest = nil
        cancelAdmission()
        guard let state = remoteSeekState, state.ownerHoldID == holdID else { return true }
        _ = cancelRemoteSeeking()
        if state.wasPlaying {
            guard handle(.play) else { return false }
            await admissionTask?.value
            return seekSessionID == sessionID && isPlaying
        }
        return true
    }
}
