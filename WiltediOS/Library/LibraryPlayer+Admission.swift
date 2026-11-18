import Foundation

/// Production audio can discard the retained decoder when its item is invalidated.
protocol LibraryAudioUnloading: AnyObject {
    func clearAudio()
}

extension LibraryPlayer {
    func cancelAdmission() {
        admissionEpoch &+= 1
        admissionTask?.cancel()
        admissionTask = nil
    }

    /// System callbacks stay nonblocking; only an admitted current target can resume or hold.
    @discardableResult
    func handle(_ command: LibraryRemoteCommand) -> Bool {
        guard let item else { return false }
        cancelAdmission()
        var needsAdmission = false
        switch command {
        case .play, .beginSeeking: needsAdmission = true
        case .togglePlayPause: needsAdmission = !isPlaying
        case .skipForward, .skipBackward, .seek:
            needsAdmission = remoteSeekState?.wasPlaying == true
        case let .endSeeking(direction):
            if authorizePlayback == nil { return performAdmitted(command) }
            guard let state = remoteSeekState, state.direction == direction else { return false }
            let resume = state.wasPlaying
            _ = cancelRemoteSeeking()
            if resume { return handle(LibraryRemoteCommand.play) }
            return true
        default: break
        }
        guard needsAdmission, let authorizePlayback else { return performAdmitted(command) }
        let epoch = admissionEpoch
        var resumes = false
        switch command {
        case .play, .togglePlayPause: resumes = status == .paused
        default: break
        }
        admissionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.admissionEpoch == epoch, self.item == item else { return }
            // Alongside the file check, so a resume waits for the slower of the two, not both.
            let moved = resumes ? self.resumePosition.map { ask in Task { @MainActor in await ask(item) } } : nil
            let admitted = await authorizePlayback(item)
            let target = await moved?.value ?? nil
            guard !Task.isCancelled, self.admissionEpoch == epoch, self.item == item else { return }
            self.admissionTask = nil
            guard admitted else { self.invalidateLoadedItem(); return }
            if let target { self.adoptPausedPosition(target) }
            _ = self.performAdmitted(command)
        }
        return true
    }

    /// Moves the paused item to where another device left it, just before a resume. Not a
    /// transport command: it cancels no admission, so the admitted play that follows still runs.
    func adoptPausedPosition(_ seconds: TimeInterval) {
        guard item != nil, status == .paused, remoteSeekState == nil else { return }
        let target = min(max(0, seconds), duration)
        engine.currentTime = target
        position = target
        publishNowPlaying()
    }

    @discardableResult
    func performAdmitted(_ command: LibraryRemoteCommand) -> Bool {
        guard item != nil else { return false }
        switch command {
        case .play: playAdmitted()
        case .pause: pause()
        case .togglePlayPause: if isPlaying { pause() } else { _ = playAdmitted() }
        case let .skipForward(seconds): seekAdmitted(to: position + seconds)
        case let .skipBackward(seconds): seekAdmitted(to: position - seconds)
        case let .seek(seconds): seekAdmitted(to: seconds)
        case let .setRate(newRate): setRate(newRate)
        case let .beginSeeking(direction): return beginRemoteSeeking(direction)
        case let .endSeeking(direction): return endRemoteSeeking(direction)
        }
        return true
    }

}
