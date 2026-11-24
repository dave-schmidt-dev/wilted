import Foundation
import WiltedLibrary

extension LibraryAppModel {
    static let saveHeadlineAction = "setHeadlineSaved"
    static let muteHeadlinePublisherAction = "setHeadlinePublisherMuted"

    /// The offline catalog is shown only for the locally bound account and outside account review.
    var headlineProjection: LibraryHeadlineProjection? {
        guard !accountQuarantined, headlinePhoneState.isBoundToLocalOwner else { return nil }
        return headlinePhoneState.projection
    }

    var headlineStories: [LibraryHeadlineStory] {
        guard let headlineProjection else { return [] }
        var stories: [String: LibraryHeadlineStory] = [:]
        for story in recentHeadlineStories { stories[story.id] = story }
        for story in headlineProjection.saved { stories[story.id] = story }
        for story in headlineCommandStories where stories[story.id] == nil { stories[story.id] = story }
        let commandStoryIDs = Set(headlinePhoneState.commands.compactMap(\.storyID))
        return stories.values.sorted {
            let leftHasCommand = commandStoryIDs.contains($0.id)
            let rightHasCommand = commandStoryIDs.contains($1.id)
            if leftHasCommand != rightHasCommand { return leftHasCommand }
            if $0.recentAnchorAt != $1.recentAnchorAt { return $0.recentAnchorAt > $1.recentAnchorAt }
            return $0.id < $1.id
        }
    }

    /// Preserves the action's original card until the Mac confirms or rejects it, including after Recent expires.
    var headlineCommandStories: [LibraryHeadlineStory] {
        guard let headlineProjection else { return [] }
        let canonicalIDs = Set(recentHeadlineStories.map(\.id) + headlineProjection.saved.map(\.id))
        var stories: [String: LibraryHeadlineStory] = [:]
        for command in headlinePhoneState.commands {
            guard case let .save(story, _, _) = command.action, !canonicalIDs.contains(story.id) else { continue }
            if stories[story.id] == nil { stories[story.id] = story }
        }
        return stories.values.sorted {
            if $0.recentAnchorAt != $1.recentAnchorAt { return $0.recentAnchorAt > $1.recentAnchorAt }
            return $0.id < $1.id
        }
    }

    var recentHeadlineStories: [LibraryHeadlineStory] {
        guard let headlineProjection else { return [] }
        return headlineProjection.recent.filter { $0.isRecent(at: now()) }
    }

    /// Resolves the exact Mac-catalog story named by the active or last spoken headline.
    func canonicalHeadlineStory(for bulletin: Bulletin) -> LibraryHeadlineStory? {
        guard let storyID = bulletin.headlineStoryID, let projection = headlineProjection else { return nil }
        return projection.recent.first(where: { $0.id == storyID })
            ?? projection.saved.first(where: { $0.id == storyID })
    }

    var mutedHeadlinePublishers: [LibraryHeadlinePublisher] {
        headlineProjection?.publishers.filter(\.isMuted).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
    }

    func saveHeadline(_ storyID: String, isSaved: Bool) {
        guard let story = recentHeadlineStories.first(where: { $0.id == storyID })
                ?? headlineProjection?.saved.first(where: { $0.id == storyID }),
              !accountQuarantined, story.isSaved != isSaved,
              !headlinePhoneState.commands.contains(where: { $0.storyID == storyID && $0.delivery != .failed && $0.delivery != .conflict }) else {
            return
        }
        let action = LibraryStoryCommandOutboxV1.Action.save(
            story: story, isSaved: isSaved, basedOnRevision: story.savedRevision)
        enqueueHeadlineAction(action)
    }

    func setHeadlinePublisherMuted(_ publisherID: String, isMuted: Bool) {
        guard let publisher = headlineProjection?.publishers.first(where: { $0.id == publisherID }),
              !accountQuarantined, publisher.isMuted != isMuted,
              !headlinePhoneState.commands.contains(where: { $0.publisherID == publisherID && $0.delivery != .failed && $0.delivery != .conflict }) else {
            return
        }
        enqueueHeadlineAction(.mute(
            publisherID: publisherID, isMuted: isMuted, basedOnRevision: publisher.revision))
    }

    /// Retries a stale action as a new command against the latest Mac revision.
    func reapplyHeadlineCommand(_ commandID: String) {
        guard let command = headlinePhoneState.commands.first(where: { $0.id == commandID && $0.delivery == .conflict }),
              let projection = headlineProjection, !accountQuarantined else { return }
        guard let action = refreshedHeadlineAction(command.action, projection: projection) else { return }
        enqueueHeadlineAction(action, superseding: commandID)
    }

    /// Retries a terminal rejection with a new id so the Mac can publish a fresh outcome.
    func retryHeadlineCommand(_ commandID: String) {
        guard let command = headlinePhoneState.commands.first(where: { $0.id == commandID && $0.delivery == .failed }),
              let projection = headlineProjection, !accountQuarantined else { return }
        guard let action = refreshedHeadlineAction(command.action, projection: projection) else { return }
        enqueueHeadlineAction(action, superseding: commandID)
    }

    func canReapplyHeadlineCommand(_ commandID: String) -> Bool {
        guard let command = headlinePhoneState.commands.first(where: { $0.id == commandID && $0.delivery == .conflict }),
              let projection = headlineProjection, !accountQuarantined else { return false }
        return hasCurrentHeadlineTarget(command.action, projection: projection)
    }

    func canRetryHeadlineCommand(_ commandID: String) -> Bool {
        guard let command = headlinePhoneState.commands.first(where: { $0.id == commandID && $0.delivery == .failed }),
              let projection = headlineProjection, !accountQuarantined else { return false }
        return hasCurrentHeadlineTarget(command.action, projection: projection)
    }

    private func enqueueHeadlineAction(
        _ action: LibraryStoryCommandOutboxV1.Action,
        superseding commandID: String? = nil
    ) {
        guard let owner = headlinePhoneState.ownerForActions else {
            headlinePhoneState.actionNotice = "Headline actions are unavailable until your library finishes syncing."
            return
        }
        let command = LibraryStoryCommandOutboxV1.Command(
            id: UUID().uuidString, ownerToken: owner, createdAt: now(), action: action,
            delivery: .pending, detail: "Waiting to sync")
        guard headlinePhoneState.enqueue(command) else {
            headlinePhoneState.actionNotice = headlinePhoneState.writeFailed
                ? "This action could not be saved on this phone."
                : "Too many headline actions are waiting to sync."
            return
        }
        if let commandID { headlinePhoneState.removeCommand(id: commandID) }
        headlinePhoneState.actionNotice = nil
        Task { [weak self] in await self?.sendPendingHeadlineCommands() }
    }

    private func refreshedHeadlineAction(
        _ action: LibraryStoryCommandOutboxV1.Action,
        projection: LibraryHeadlineProjection
    ) -> LibraryStoryCommandOutboxV1.Action? {
        switch action {
        case let .save(story, isSaved, _):
            guard let current = recentHeadlineStories.first(where: { $0.id == story.id })
                    ?? projection.saved.first(where: { $0.id == story.id }) else {
                guard let expired = projection.expiredIdentities.first(where: {
                    $0.id == story.id && $0.publisherID == story.publisherID && $0.link == story.link
                }), let refreshed = try? LibraryHeadlineStory(
                    id: story.id, title: story.title, publisherID: story.publisherID,
                    publisherName: story.publisherName, link: story.link, publishedAt: story.publishedAt,
                    firstSeenAt: story.firstSeenAt, lastSeenAt: story.lastSeenAt,
                    savedAt: story.savedAt, savedRevision: expired.savedRevision) else {
                    headlinePhoneState.actionNotice = "This story is no longer available to save."
                    return nil
                }
                return .save(story: refreshed, isSaved: isSaved, basedOnRevision: expired.savedRevision)
            }
            return .save(story: current, isSaved: isSaved, basedOnRevision: current.savedRevision)
        case let .mute(publisherID, isMuted, _):
            guard let current = projection.publishers.first(where: { $0.id == publisherID }) else {
                headlinePhoneState.actionNotice = "This publisher is no longer available."
                return nil
            }
            return .mute(publisherID: publisherID, isMuted: isMuted, basedOnRevision: current.revision)
        }
    }

    private func hasCurrentHeadlineTarget(
        _ action: LibraryStoryCommandOutboxV1.Action,
        projection: LibraryHeadlineProjection
    ) -> Bool {
        switch action {
        case let .save(story, _, _):
            if let current = recentHeadlineStories.first(where: { $0.id == story.id })
                ?? projection.saved.first(where: { $0.id == story.id }) {
                return current.publisherID == story.publisherID && current.link == story.link
            }
            return projection.expiredIdentities.contains {
                $0.id == story.id && $0.publisherID == story.publisherID && $0.link == story.link
            }
        case let .mute(publisherID, _, _):
            return projection.publishers.contains { $0.id == publisherID }
        }
    }

    /// Fetches the Mac's full projection on every library refresh, even while idle or when speech is off.
    /// The captured owner and operation generation fence the async response before it reaches disk.
    func reconcileHeadlineProjection(
        outcomes: [IntentOutcome],
        expectedOwner: String?,
        generation: UInt64,
        isCurrent: () async -> Bool
    ) async {
        guard let expectedOwner, !accountQuarantined,
              headlinePhoneState.isCurrent(owner: expectedOwner, generation: generation) else { return }
        let value: LibraryHeadlineProjection?
        do {
            value = try await transport.fetchHeadlineProjection()
        } catch {
            guard await isCurrent(), headlinePhoneState.isCurrent(owner: expectedOwner, generation: generation) else { return }
            headlinePhoneState.noteRefreshFailure(true)
            return
        }
        guard await isCurrent(), headlinePhoneState.isCurrent(owner: expectedOwner, generation: generation) else { return }
        headlinePhoneState.noteRefreshFailure(false)
        if let value { headlinePhoneState.replaceProjection(value, owner: expectedOwner, generation: generation) }
        reconcileHeadlineCommands(outcomes, projection: value ?? headlinePhoneState.projection)
    }

    /// Sends only durable commands supported by the Mac's advertised action list.
    func sendPendingHeadlineCommands() async {
        guard !accountQuarantined else { return }
        let pending = headlinePhoneState.commands.filter { $0.delivery == .pending }
        guard !pending.isEmpty else { return }
        guard headlinePhoneState.beginSendingCommands() else { return }
        defer { headlinePhoneState.finishSendingCommands() }
        let needsCapabilityRead = macAddActions == nil || macAddCheckFailed
            || pending.contains { macAddActions?.contains(Self.actionName(for: $0.action)) != true }
        if needsCapabilityRead {
            await loadAddCapability()
        }
        guard !accountQuarantined else { return }
        for command in pending {
            guard !accountQuarantined,
                  headlinePhoneState.commands.contains(where: { $0.id == command.id && $0.delivery == .pending }) else { continue }
            let actionName = Self.actionName(for: command.action)
            guard macAddActions?.contains(actionName) == true else {
                var waiting = command
                waiting.detail = "Update Wilted on your Mac to use this action."
                headlinePhoneState.update(waiting)
                continue
            }
            guard commandStillMatchesCurrentProjection(command) else { continue }
            let generation = await transport.operationGeneration()
            guard let owner = await transport.verifiedOwnerToken(), owner == command.ownerToken,
                  headlinePhoneState.isCurrent(owner: owner, generation: generation) else { continue }
            do {
                try await transport.send(intent: try Self.makeIntent(command, deviceID: deviceID))
                guard !accountQuarantined,
                      await transport.operationGeneration() == generation,
                      await transport.verifiedOwnerToken() == owner,
                      headlinePhoneState.isCurrent(owner: owner, generation: generation) else { continue }
                var sent = command
                sent.delivery = .sent
                sent.detail = "Waiting for your Mac to confirm."
                headlinePhoneState.update(sent)
            } catch {
                guard await transport.operationGeneration() == generation,
                      await transport.verifiedOwnerToken() == owner,
                      headlinePhoneState.isCurrent(owner: owner, generation: generation) else { continue }
                var waiting = command
                waiting.detail = "Waiting for a connection to your Mac."
                headlinePhoneState.update(waiting)
            }
        }
    }

    private func commandStillMatchesCurrentProjection(_ command: LibraryStoryCommandOutboxV1.Command) -> Bool {
        guard let projection = headlineProjection else { return false }
        switch command.action {
        case let .save(story, _, revision):
            let current = projection.recent.first(where: { $0.id == story.id })
                ?? projection.saved.first(where: { $0.id == story.id })
            if let current,
               current.publisherID == story.publisherID, current.link == story.link,
               current.savedRevision == revision { return true }
            let expired = projection.expiredIdentities.first(where: {
                $0.id == story.id && $0.publisherID == story.publisherID && $0.link == story.link
            })
            guard let expired, expired.savedRevision == revision else {
                markConflict(command, projection: projection)
                return false
            }
            return true
        case let .mute(publisherID, _, revision):
            guard let current = projection.publishers.first(where: { $0.id == publisherID }), current.revision == revision else {
                markConflict(command, projection: projection)
                return false
            }
        }
        return true
    }

    private func reconcileHeadlineCommands(_ outcomes: [IntentOutcome], projection: LibraryHeadlineProjection?) {
        guard let projection else { return }
        for command in headlinePhoneState.commands where command.delivery == .sent {
            guard let outcome = outcomes.first(where: { $0.intentID == command.id && $0.deviceID == deviceID }) else { continue }
            if outcome.isApplied {
                guard Self.projection(projection, matches: command.action) else { continue }
                headlinePhoneState.removeCommand(id: command.id)
            } else if outcome.reason == IntentOutcome.reasonStaleRevision {
                markConflict(command, projection: projection)
            } else {
                var failed = command
                failed.delivery = .failed
                switch outcome.reason {
                case IntentOutcome.reasonUnsupportedAction:
                    failed.detail = "Update Wilted on your Mac to manage headlines."
                case "unknownStory":
                    failed.detail = "This story expired before your Mac received the Save."
                case "unknownPublisher":
                    failed.detail = "This publisher is no longer available on your Mac."
                default:
                    failed.detail = "Your Mac could not apply this action. Try again."
                }
                headlinePhoneState.update(failed)
            }
        }
        for command in headlinePhoneState.commands where command.delivery == .pending {
            guard !Self.revisionMatches(projection, command.action) else { continue }
            markConflict(command, projection: projection)
        }
    }

    private func markConflict(
        _ command: LibraryStoryCommandOutboxV1.Command,
        projection: LibraryHeadlineProjection? = nil
    ) {
        var conflict = command
        if let projection, !hasCurrentHeadlineTarget(command.action, projection: projection) {
            conflict.delivery = .failed
            switch command.action {
            case .save: conflict.detail = "This story is no longer in the Mac's catalog."
            case .mute: conflict.detail = "This publisher is no longer in the Mac's catalog."
            }
        } else {
            conflict.delivery = .conflict
            conflict.detail = "The Mac changed this headline. Review the current value, then reapply."
        }
        headlinePhoneState.update(conflict)
    }

    private static func actionName(for action: LibraryStoryCommandOutboxV1.Action) -> String {
        switch action {
        case .save: Self.saveHeadlineAction
        case .mute: Self.muteHeadlinePublisherAction
        }
    }

    private static func makeIntent(_ command: LibraryStoryCommandOutboxV1.Command, deviceID: String) throws -> LibraryIntent {
        switch command.action {
        case let .save(story, isSaved, revision):
            try .setHeadlineSaved(story: story, isSaved: isSaved, basedOnRevision: revision,
                                  deviceID: deviceID, createdAt: command.createdAt, id: command.id)
        case let .mute(publisherID, isMuted, revision):
            try .setHeadlinePublisherMuted(publisherID: publisherID, isMuted: isMuted,
                                           basedOnRevision: revision, deviceID: deviceID,
                                           createdAt: command.createdAt, id: command.id)
        }
    }

    private static func revisionMatches(_ projection: LibraryHeadlineProjection, _ action: LibraryStoryCommandOutboxV1.Action) -> Bool {
        switch action {
        case let .save(story, _, revision):
            let current = projection.recent.first { $0.id == story.id } ?? projection.saved.first { $0.id == story.id }
            if let current, current.publisherID == story.publisherID, current.link == story.link {
                return current.savedRevision == revision
            }
            return projection.expiredIdentities.first {
                $0.id == story.id && $0.publisherID == story.publisherID && $0.link == story.link
            }?.savedRevision == revision
        case let .mute(publisherID, _, revision):
            return projection.publishers.first { $0.id == publisherID }?.revision == revision
        }
    }

    private static func projection(_ projection: LibraryHeadlineProjection, matches action: LibraryStoryCommandOutboxV1.Action) -> Bool {
        switch action {
        case let .save(story, isSaved, _): projection.saved.contains { $0.id == story.id } == isSaved
        case let .mute(publisherID, isMuted, _): projection.publishers.first { $0.id == publisherID }?.isMuted == isMuted
        }
    }
}
