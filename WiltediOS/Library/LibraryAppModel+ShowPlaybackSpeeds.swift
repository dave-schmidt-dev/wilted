import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let showPlaybackSpeedLog = Logger(subsystem: "com.zerodelta.wilted", category: "ShowPlaybackSpeeds")

extension LibraryAppModel {
    static let showPlaybackSpeedConflictReason = "showPlaybackSpeedConflict"

    func restoreShowPlaybackSpeedOutbox() {
        switch showPlaybackSpeedOutbox.load() {
        case .empty: return
        case .unreadable: showPlaybackSpeedOutboxWritable = false
        case let .saved(saved):
            showPlaybackSpeedOwnerToken = saved.ownerToken
            showPlaybackSpeedRestoredOwner = saved.ownerToken
            showPlaybackSpeeds = saved.speeds
            var commands = Dictionary(saved.commands.map { ($0.feedID, $0) }, uniquingKeysWith: { _, latest in latest })
            var recoveredReservation = false
            for feedID in commands.keys.sorted() {
                guard var command = commands[feedID], command.sentAt == nil,
                      command.reservedAt != nil, command.appliedRevision == nil else { continue }
                command.reservedAt = nil
                commands[feedID] = command
                recoveredReservation = true
            }
            showPlaybackSpeedCommands = commands
            if recoveredReservation { _ = persistShowPlaybackSpeedOutbox() }
        }
    }

    func verifyShowPlaybackSpeedOwner(_ owner: String?) {
        guard let owner, !owner.isEmpty else { return }
        guard !showPlaybackSpeedOwnerVerified else {
            guard showPlaybackSpeedOwnerToken != owner else { return }
            clearShowPlaybackSpeedState(owner: owner)
            return
        }
        showPlaybackSpeedOwnerVerified = true
        if let restored = showPlaybackSpeedRestoredOwner, restored != owner {
            showPlaybackSpeedLog.error("Dropped show speed commands saved for another library owner.")
            clearShowPlaybackSpeedState(owner: owner)
        } else {
            showPlaybackSpeedOwnerToken = owner
            persistShowPlaybackSpeedOutbox()
        }
    }

    func discardShowPlaybackSpeedsAfterAccountChange() {
        clearShowPlaybackSpeedState(owner: nil)
        showPlaybackSpeedOwnerVerified = true
    }

    private func clearShowPlaybackSpeedState(owner: String?) {
        showPlaybackSpeedOwnerToken = owner
        showPlaybackSpeedRestoredOwner = owner
        showPlaybackSpeeds = [:]
        showPlaybackSpeedCommands = [:]
        showPlaybackSpeedNotices = [:]
        macSupportsShowPlaybackSpeeds = nil
        persistShowPlaybackSpeedOutbox()
    }

    @discardableResult
    func persistShowPlaybackSpeedOutbox() -> Bool {
        guard showPlaybackSpeedOutboxWritable else { return false }
        let saved = LibraryShowPlaybackSpeedOutbox.Saved(
            ownerToken: showPlaybackSpeedOwnerToken,
            speeds: showPlaybackSpeeds,
            commands: showPlaybackSpeedCommands.values.sorted { $0.intent.id < $1.intent.id })
        do {
            try showPlaybackSpeedOutbox.save(saved)
            return true
        } catch {
            showPlaybackSpeedLog.error("Could not save the show speed outbox: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// Returns the phone's effective show rate, preserving an applied edit while stats lag.
    func showPlaybackSpeed(for feedID: ItemID) -> Double? {
        if let command = showPlaybackSpeedCommands[feedID.rawValue], !command.conflict {
            return command.speed
        }
        return showPlaybackSpeeds[feedID.rawValue]?.speed
    }

    func showPlaybackSpeedStatus(for feedID: ItemID) -> String? {
        showPlaybackSpeedNotices[feedID.rawValue]
    }

    /// Saves the local choice before sending. A second edit waits for the Mac's answer.
    func setShowPlaybackSpeed(_ speed: Double?, for feedID: ItemID) async {
        guard speed.map(PlaybackSpeeds.contains) ?? true else { return }
        guard showPlaybackSpeedOutboxWritable else {
            showPlaybackSpeedNotices[feedID.rawValue] = "This phone cannot save the change yet. Reopen Settings to retry."
            return
        }
        guard !accountQuarantined, showPlaybackSpeedOwnerVerified, let owner = showPlaybackSpeedOwnerToken else {
            showPlaybackSpeedNotices[feedID.rawValue] = "Sync is paused until this phone verifies the library account."
            return
        }
        guard macSupportsShowPlaybackSpeeds != false else {
            showPlaybackSpeedNotices[feedID.rawValue] = "Update Wilted on your Mac to change show playback speed."
            return
        }
        if showPlaybackSpeedSendsInFlight.contains(feedID.rawValue) {
            showPlaybackSpeedNotices[feedID.rawValue] = "Waiting for your Mac to confirm this setting."
            return
        }
        if let pending = showPlaybackSpeedCommands[feedID.rawValue],
           (pending.reservedAt != nil || pending.sentAt != nil || pending.appliedRevision != nil), !pending.conflict {
            showPlaybackSpeedNotices[feedID.rawValue] = "Waiting for your Mac to confirm this setting."
            return
        }
        let current = showPlaybackSpeeds[feedID.rawValue]
            ?? (try? LibraryShowPlaybackSpeed(feedID: feedID, speed: nil, revision: 0))
        guard let current else { return }
        let previous = showPlaybackSpeedCommands[feedID.rawValue]
        if previous == nil, current.speed == speed { return }
        if previous?.conflict == true,
           let authoritative = showPlaybackSpeeds[feedID.rawValue], authoritative.speed == speed {
            showPlaybackSpeedCommands[feedID.rawValue] = nil
            showPlaybackSpeedNotices[feedID.rawValue] = "That speed is already saved on your Mac."
            _ = persistShowPlaybackSpeedOutbox()
            return
        }
        guard let intent = try? LibraryIntent.setShowPlaybackSpeed(
            feedID: feedID, speed: speed, basedOnRevision: current.revision,
            deviceID: deviceID, createdAt: now()) else { return }
        showPlaybackSpeedCommands[feedID.rawValue] = .init(intent: intent, sentAt: nil)
        showPlaybackSpeedNotices[feedID.rawValue] = "Saved on this phone. Waiting to send."
        guard persistShowPlaybackSpeedOutbox() else {
            showPlaybackSpeedCommands[feedID.rawValue] = previous
            showPlaybackSpeedNotices[feedID.rawValue] = "This phone could not save the change. Try again."
            return
        }
        await sendShowPlaybackSpeedCommand(feedID: feedID.rawValue, owner: owner)
    }

    func reapplyShowPlaybackSpeed(for feedID: ItemID) async {
        guard let command = showPlaybackSpeedCommands[feedID.rawValue], command.conflict else { return }
        let generation = await transport.operationGeneration()
        let identity = ObjectIdentifier(store as AnyObject)
        guard let owner = showPlaybackSpeedOwnerToken else { return }
        guard await refreshShowPlaybackSpeedStats(owner: owner, generation: generation, storeIdentity: identity),
              macSupportsShowPlaybackSpeeds == true else {
            showPlaybackSpeedNotices[feedID.rawValue] = "Could not refresh your Mac’s show settings. Try Apply again."
            return
        }
        guard let desired = showPlaybackSpeedCommands[feedID.rawValue]?.speed else {
            // A reset is represented by nil, so keep it distinct from a missing command.
            guard showPlaybackSpeedCommands[feedID.rawValue] != nil else { return }
            await setShowPlaybackSpeed(nil, for: feedID)
            return
        }
        await setShowPlaybackSpeed(desired, for: feedID)
    }

    func resolveShowPlaybackSpeedOutcomes(_ outcomes: [IntentOutcome]) {
        var changed = false
        for outcome in outcomes where outcome.deviceID == deviceID {
            guard let pair = showPlaybackSpeedCommands.first(where: { $0.value.intent.id == outcome.intentID }) else { continue }
            var command = pair.value
            if outcome.isApplied {
                guard let basedOnRevision = command.basedOnRevision else {
                    command.conflict = true
                    command.reservedAt = nil
                    showPlaybackSpeedCommands[pair.key] = command
                    showPlaybackSpeedNotices[pair.key] = "Your Mac confirmed an unreadable setting. Refresh show settings before retrying."
                    changed = true
                    continue
                }
                let (expectedRevision, overflow) = basedOnRevision.addingReportingOverflow(1)
                guard !overflow else {
                    command.conflict = true
                    command.reservedAt = nil
                    showPlaybackSpeedCommands[pair.key] = command
                    showPlaybackSpeedNotices[pair.key] = "Your Mac confirmed an unreadable setting. Refresh show settings before retrying."
                    changed = true
                    continue
                }
                if let current = showPlaybackSpeeds[pair.key], current.revision >= expectedRevision {
                    showPlaybackSpeedCommands.removeValue(forKey: pair.key)
                    showPlaybackSpeedNotices[pair.key] = nil
                } else {
                    command.appliedRevision = expectedRevision
                    command.reservedAt = nil
                    showPlaybackSpeedCommands[pair.key] = command
                    showPlaybackSpeedNotices[pair.key] = "Saved on your Mac. Updating this phone's settings."
                }
            } else if outcome.reason == IntentOutcome.reasonUnsupportedAction {
                showPlaybackSpeedCommands.removeValue(forKey: pair.key)
                macSupportsShowPlaybackSpeeds = false
                showPlaybackSpeedNotices[pair.key] = "Update Wilted on your Mac to use show playback speed."
            } else if outcome.reason == IntentOutcome.reasonNotApplicable {
                showPlaybackSpeedCommands.removeValue(forKey: pair.key)
                showPlaybackSpeedNotices[pair.key] = "Your Mac no longer follows this show, so it did not save the speed."
            } else {
                command.conflict = true
                command.reservedAt = nil
                showPlaybackSpeedCommands[pair.key] = command
                showPlaybackSpeedNotices[pair.key] = outcome.reason == Self.showPlaybackSpeedConflictReason
                    ? "Changed on your Mac. Review its value, then choose Apply again."
                    : "Your Mac did not apply this setting. Choose Apply again to retry."
            }
            changed = true
        }
        if changed { persistShowPlaybackSpeedOutbox() }
    }

    @discardableResult
    func refreshShowPlaybackSpeedStats(owner: String, generation: UInt64, storeIdentity: ObjectIdentifier) async -> Bool {
        do {
            let stats = try await transport.readStats()
            let liveOwner = await transport.verifiedOwnerToken()
            let liveGeneration = await transport.operationGeneration()
            let state = await store.state()
            guard ObjectIdentifier(store as AnyObject) == storeIdentity,
                  liveGeneration == generation, state.ownerToken == owner,
                  liveOwner == owner, !state.reviewHold, !accountQuarantined else { return false }
            showPlaybackSpeeds = stats?.showPlaybackSpeeds ?? [:]
            let actions = Set(stats?.supportedIntentActions ?? [])
            macSupportsShowPlaybackSpeeds = stats == nil ? nil : actions.contains("setShowPlaybackSpeed")
            for (feedID, command) in showPlaybackSpeedCommands {
                guard let appliedRevision = command.appliedRevision,
                      let authoritative = showPlaybackSpeeds[feedID], authoritative.revision >= appliedRevision else { continue }
                showPlaybackSpeedCommands.removeValue(forKey: feedID)
                showPlaybackSpeedNotices[feedID] = nil
            }
            persistShowPlaybackSpeedOutbox()
            return true
        } catch {
            showPlaybackSpeedLog.error("Could not refresh show playback speeds.")
            return false
        }
    }

    private func sendShowPlaybackSpeedCommand(feedID: String, owner: String) async {
        guard var command = showPlaybackSpeedCommands[feedID], command.sentAt == nil,
              command.appliedRevision == nil, command.reservedAt == nil, !command.conflict,
              !accountQuarantined, !showPlaybackSpeedSendsInFlight.contains(feedID) else { return }
        let intentID = command.intent.id
        command.reservedAt = now()
        showPlaybackSpeedCommands[feedID] = command
        showPlaybackSpeedSendsInFlight.insert(feedID)
        defer { showPlaybackSpeedSendsInFlight.remove(feedID) }
        guard persistShowPlaybackSpeedOutbox() else {
            command.reservedAt = nil
            if showPlaybackSpeedCommands[feedID]?.intent.id == intentID { showPlaybackSpeedCommands[feedID] = command }
            showPlaybackSpeedNotices[feedID] = "This phone could not save the send reservation. Try again."
            return
        }
        let identity = ObjectIdentifier(store as AnyObject)
        let generation = await transport.operationGeneration()
        guard await transport.verifiedOwnerToken() == owner else {
            clearShowPlaybackSpeedReservation(feedID: feedID, intentID: intentID)
            return
        }
        do {
            try await transport.send(intent: command.intent)
            let state = await store.state()
            guard ObjectIdentifier(store as AnyObject) == identity,
                  await transport.operationGeneration() == generation,
                  await transport.verifiedOwnerToken() == owner,
                  state.ownerToken == owner, !state.reviewHold, !accountQuarantined,
                  var current = showPlaybackSpeedCommands[feedID], current.intent.id == intentID,
                  !current.conflict else {
                clearShowPlaybackSpeedReservation(feedID: feedID, intentID: intentID)
                return
            }
            current.reservedAt = nil
            current.sentAt = now()
            showPlaybackSpeedCommands[feedID] = current
            showPlaybackSpeedNotices[feedID] = "Sent to your Mac. Waiting for confirmation."
            _ = persistShowPlaybackSpeedOutbox()
        } catch {
            clearShowPlaybackSpeedReservation(
                feedID: feedID, intentID: intentID,
                notice: "Saved on this phone. Wilted will try again when sync is available.")
        }
    }

    private func clearShowPlaybackSpeedReservation(feedID: String, intentID: String, notice: String? = nil) {
        guard var command = showPlaybackSpeedCommands[feedID], command.intent.id == intentID,
              command.reservedAt != nil else { return }
        command.reservedAt = nil
        showPlaybackSpeedCommands[feedID] = command
        if let notice { showPlaybackSpeedNotices[feedID] = notice }
        _ = persistShowPlaybackSpeedOutbox()
    }

    func sendDueShowPlaybackSpeedCommands() async {
        guard showPlaybackSpeedOwnerVerified, let owner = showPlaybackSpeedOwnerToken,
              !accountQuarantined, macSupportsShowPlaybackSpeeds != false else { return }
        for feedID in showPlaybackSpeedCommands.keys.sorted() {
            await sendShowPlaybackSpeedCommand(feedID: feedID, owner: owner)
        }
    }
}
