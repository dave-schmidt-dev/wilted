import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let showStartOffsetLog = Logger(subsystem: "com.zerodelta.wilted", category: "ShowStartOffsets")

extension LibraryAppModel {
    static let showStartOffsetConflictReason = LibraryShowStartOffset.conflictReason

    func restoreShowStartOffsetOutbox() {
        switch showStartOffsetOutbox.load() {
        case .empty:
            return
        case .unreadable:
            showStartOffsetOutboxWritable = false
        case let .saved(saved):
            showStartOffsetOwnerToken = saved.ownerToken
            showStartOffsetRestoredOwner = saved.ownerToken
            showStartOffsets = saved.offsets
            var commands = Dictionary(saved.commands.map { ($0.feedID, $0) }, uniquingKeysWith: { _, latest in latest })
            var recoveredReservation = false
            for feedID in commands.keys.sorted() {
                guard var command = commands[feedID], command.sentAt == nil, command.reservedAt != nil else { continue }
                command.reservedAt = nil
                commands[feedID] = command
                recoveredReservation = true
            }
            showStartOffsetCommands = commands
            if recoveredReservation { _ = persistShowStartOffsetOutbox() }
        }
    }

    /// Binds saved settings and commands to the verified mirror owner before any send.
    func verifyShowStartOffsetOwner(_ owner: String?) {
        guard let owner, !owner.isEmpty else { return }
        guard !showStartOffsetOwnerVerified else {
            guard showStartOffsetOwnerToken != owner else { return }
            clearShowStartOffsetState(owner: owner)
            return
        }
        showStartOffsetOwnerVerified = true
        if let restored = showStartOffsetRestoredOwner, restored != owner {
            showStartOffsetLog.error("Dropped show offset commands saved for another library owner.")
            clearShowStartOffsetState(owner: owner)
        } else {
            showStartOffsetOwnerToken = owner
            persistShowStartOffsetOutbox()
        }
    }

    func discardShowStartOffsetsAfterAccountChange() {
        clearShowStartOffsetState(owner: nil)
        showStartOffsetOwnerVerified = true
    }

    private func clearShowStartOffsetState(owner: String?) {
        showStartOffsetOwnerToken = owner
        showStartOffsetRestoredOwner = owner
        showStartOffsets = [:]
        showStartOffsetCommands = [:]
        showStartOffsetNotices = [:]
        macSupportsShowStartOffsets = nil
        persistShowStartOffsetOutbox()
    }

    @discardableResult
    func persistShowStartOffsetOutbox() -> Bool {
        guard showStartOffsetOutboxWritable else { return false }
        let saved = LibraryShowStartOffsetOutbox.Saved(
            ownerToken: showStartOffsetOwnerToken, offsets: showStartOffsets,
            commands: showStartOffsetCommands.values.sorted { $0.intent.id < $1.intent.id })
        do {
            try showStartOffsetOutbox.save(saved)
            return true
        } catch {
            showStartOffsetLog.error("Could not save the show offset outbox: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    func showStartOffsetSeconds(for feedID: ItemID) -> Double {
        if showStartOffsetCommands[feedID.rawValue]?.conflict == true {
            return showStartOffsets[feedID.rawValue]?.seconds ?? 0
        }
        return showStartOffsetCommands[feedID.rawValue]?.seconds ?? showStartOffsets[feedID.rawValue]?.seconds ?? 0
    }

    func showStartOffsetStatus(for feedID: ItemID) -> String? {
        showStartOffsetNotices[feedID.rawValue]
    }

    /// Any saved checkpoint, including zero, is a resume and suppresses a fresh-start offset.
    func hasSavedPlaybackState(for entryID: ItemID) -> Bool {
        let members = episodeGroup(entryID)?.memberIDs ?? [entryID]
        return members.contains { member in
            checkpoints[member] != nil || handoffState.ownPositions[member] != nil
                || startedEntries.contains(member) || finished[member] != nil
                || decisionContent.listening[member]?.isCompleted == true
        }
    }

    /// Saves a versioned command before transport send. A second edit waits for the first Mac result.
    func setShowStartOffset(_ seconds: Double, for feedID: ItemID) async {
        guard seconds.isFinite, (0...LibraryShowStartOffset.maximumSeconds).contains(seconds) else { return }
        guard showStartOffsetOutboxWritable else {
            showStartOffsetNotices[feedID.rawValue] = "This phone cannot save the change yet. Reopen Settings to retry."
            return
        }
        guard !accountQuarantined, showStartOffsetOwnerVerified, let owner = showStartOffsetOwnerToken else {
            showStartOffsetNotices[feedID.rawValue] = "Sync is paused until this phone verifies the library account."
            return
        }
        guard macSupportsShowStartOffsets != false else {
            showStartOffsetNotices[feedID.rawValue] = "Update Wilted on your Mac to change show start times."
            return
        }
        if showStartOffsetSendsInFlight.contains(feedID.rawValue) {
            showStartOffsetNotices[feedID.rawValue] = "Waiting for your Mac to confirm this setting."
            return
        }
        if let pending = showStartOffsetCommands[feedID.rawValue],
           (pending.reservedAt != nil || pending.sentAt != nil), !pending.conflict {
            showStartOffsetNotices[feedID.rawValue] = "Waiting for your Mac to confirm this setting."
            return
        }
        let current = showStartOffsets[feedID.rawValue]
            ?? (try? LibraryShowStartOffset(feedID: feedID, seconds: 0, revision: 0))
        guard let current else { return }
        if showStartOffsetCommands[feedID.rawValue] == nil, current.seconds == seconds { return }
        guard let intent = try? LibraryIntent.setShowStartOffset(
            feedID: feedID, seconds: seconds, basedOnRevision: current.revision,
            deviceID: deviceID, createdAt: now()) else { return }
        let previous = showStartOffsetCommands[feedID.rawValue]
        showStartOffsetCommands[feedID.rawValue] = .init(intent: intent, sentAt: nil)
        showStartOffsetNotices[feedID.rawValue] = "Saved on this phone. Waiting to send."
        guard persistShowStartOffsetOutbox() else {
            showStartOffsetCommands[feedID.rawValue] = previous
            showStartOffsetNotices[feedID.rawValue] = "This phone could not save the change. Try again."
            return
        }
        await sendShowStartOffsetCommand(feedID: feedID.rawValue, owner: owner)
    }

    func reapplyShowStartOffset(for feedID: ItemID) async {
        guard let command = showStartOffsetCommands[feedID.rawValue], command.conflict,
              let seconds = command.seconds else { return }
        await setShowStartOffset(seconds, for: feedID)
    }

    func resolveShowStartOffsetOutcomes(_ outcomes: [IntentOutcome]) {
        var changed = false
        for outcome in outcomes where outcome.deviceID == deviceID {
            guard let pair = showStartOffsetCommands.first(where: { $0.value.intent.id == outcome.intentID }) else { continue }
            var command = pair.value
            if outcome.isApplied {
                showStartOffsetCommands.removeValue(forKey: pair.key)
                showStartOffsetNotices[pair.key] = nil
            } else if outcome.reason == IntentOutcome.reasonUnsupportedAction {
                showStartOffsetCommands.removeValue(forKey: pair.key)
                macSupportsShowStartOffsets = false
                showStartOffsetNotices[pair.key] = "Update Wilted on your Mac to use show start times."
            } else if outcome.reason == IntentOutcome.reasonNotApplicable {
                showStartOffsetCommands.removeValue(forKey: pair.key)
                showStartOffsetNotices[pair.key] = "Your Mac no longer follows this show, so it did not save the start time."
            } else {
                command.conflict = true
                showStartOffsetCommands[pair.key] = command
                showStartOffsetNotices[pair.key] = outcome.reason == Self.showStartOffsetConflictReason
                    ? "Changed on your Mac. Review its value, then choose Apply again."
                    : "Your Mac did not apply this setting. Choose Apply again to retry."
            }
            changed = true
        }
        if changed { persistShowStartOffsetOutbox() }
    }

    /// Saves a Mac stats projection only while its owner and the round generation still match.
    func refreshShowStartOffsetStats(owner: String, generation: UInt64, storeIdentity: ObjectIdentifier) async {
        do {
            let stats = try await transport.readStats()
            let liveOwner = await transport.verifiedOwnerToken()
            let liveGeneration = await transport.operationGeneration()
            let state = await store.state()
            guard ObjectIdentifier(store as AnyObject) == storeIdentity,
                  liveGeneration == generation, state.ownerToken == owner,
                  liveOwner == owner, !state.reviewHold, !accountQuarantined else { return }
            showStartOffsets = stats?.showStartOffsets ?? [:]
            let actions = Set(stats?.supportedIntentActions ?? [])
            macSupportsShowStartOffsets = stats == nil ? nil : actions.contains("setShowStartOffset")
            persistShowStartOffsetOutbox()
        } catch {
            showStartOffsetLog.error("Could not refresh show start times.")
        }
    }

    private func sendShowStartOffsetCommand(feedID: String, owner: String) async {
        guard var command = showStartOffsetCommands[feedID], command.sentAt == nil,
              command.reservedAt == nil, !command.conflict, !accountQuarantined,
              !showStartOffsetSendsInFlight.contains(feedID) else { return }
        let intentID = command.intent.id
        command.reservedAt = now()
        showStartOffsetCommands[feedID] = command
        showStartOffsetSendsInFlight.insert(feedID)
        defer { showStartOffsetSendsInFlight.remove(feedID) }
        guard persistShowStartOffsetOutbox() else {
            command.reservedAt = nil
            if showStartOffsetCommands[feedID]?.intent.id == intentID {
                showStartOffsetCommands[feedID] = command
            }
            showStartOffsetNotices[feedID] = "This phone could not save the send reservation. Try again."
            return
        }
        let identity = ObjectIdentifier(store as AnyObject)
        let generation = await transport.operationGeneration()
        guard await transport.verifiedOwnerToken() == owner else {
            clearShowStartOffsetReservation(feedID: feedID, intentID: intentID)
            return
        }
        do {
            try await transport.send(intent: command.intent)
            let state = await store.state()
            guard ObjectIdentifier(store as AnyObject) == identity,
                  await transport.operationGeneration() == generation,
                  await transport.verifiedOwnerToken() == owner,
                  state.ownerToken == owner, !state.reviewHold, !accountQuarantined,
                  var current = showStartOffsetCommands[feedID], current.intent.id == intentID,
                  !current.conflict else {
                clearShowStartOffsetReservation(feedID: feedID, intentID: intentID)
                return
            }
            current.reservedAt = nil
            current.sentAt = now()
            showStartOffsetCommands[feedID] = current
            showStartOffsetNotices[feedID] = "Sent to your Mac. Waiting for confirmation."
            _ = persistShowStartOffsetOutbox()
        } catch is CancellationError {
            // A new model clears this reservation and retries the same id after a relaunch.
            showStartOffsetNotices[feedID] = "Saved on this phone. Wilted will retry after reopening."
        } catch {
            clearShowStartOffsetReservation(
                feedID: feedID, intentID: intentID,
                notice: "Saved on this phone. Wilted will try again when sync is available.")
        }
    }

    private func clearShowStartOffsetReservation(feedID: String, intentID: String, notice: String? = nil) {
        guard var command = showStartOffsetCommands[feedID], command.intent.id == intentID,
              command.reservedAt != nil else { return }
        command.reservedAt = nil
        showStartOffsetCommands[feedID] = command
        if let notice { showStartOffsetNotices[feedID] = notice }
        _ = persistShowStartOffsetOutbox()
    }

    func sendDueShowStartOffsetCommands() async {
        guard showStartOffsetOwnerVerified, let owner = showStartOffsetOwnerToken,
              !accountQuarantined, macSupportsShowStartOffsets != false else { return }
        for feedID in showStartOffsetCommands.keys.sorted() {
            await sendShowStartOffsetCommand(feedID: feedID, owner: owner)
        }
    }
}
