import WiltedDomain
import WiltedLibrary
import WiltedProducer

struct WiltedMacShowSettingsResetUndo {
    fileprivate let feedID: String
    fileprivate let policy: FeedAutomationPolicy
    fileprivate let isNews: Bool
    fileprivate let isAdFree: Bool
    fileprivate let removesSelfPromotion: Bool
    fileprivate let loudnessOverride: WiltedMacLoudnessOverride
    fileprivate let sendsForAdFinding: Bool
    fileprivate let startOffset: LibraryShowStartOffset?
    fileprivate let resetStartOffsetRevision: Int64?
    fileprivate let playbackSpeed: LibraryShowPlaybackSpeed?
    fileprivate let resetPlaybackSpeedRevision: Int64?
}

enum WiltedMacShowSetting: String, CaseIterable {
    case autoKeep
    case autoDownload
    case autoPrepare
    case keptLimit
    case news
    case removeAds
    case selfPromotion
    case loudness
    case adFinding
    case startOffset
    case playbackSpeed
}

extension WiltedMacFeedPolicyBoard {
    func isOverridden(_ setting: WiltedMacShowSetting, for feedID: String) -> Bool {
        let policy = policy(for: feedID)
        return switch setting {
        case .autoKeep:
            policy.autoKeep != .useGlobal
        case .autoDownload:
            !isArticleFeed(feedID) && policy.autoDownload != .useGlobal
        case .autoPrepare:
            policy.autoPrepare != .useGlobal
        case .keptLimit:
            policy.keptLimit != .useGlobal
        case .news:
            isArticleFeed(feedID) && isNews(feedID)
        case .removeAds:
            !isArticleFeed(feedID) && isAdFree(feedID)
        case .selfPromotion:
            !isArticleFeed(feedID) && removesSelfPromotion(feedID)
        case .loudness:
            !isArticleFeed(feedID) && loudnessOverride(feedID) != .inherit
        case .adFinding:
            !isArticleFeed(feedID) && sendsForAdFinding(feedID)
        case .startOffset:
            !isArticleFeed(feedID) && isStartOffsetCustomized(feedID)
        case .playbackSpeed:
            !isArticleFeed(feedID) && isShowPlaybackSpeedCustomized(feedID)
        }
    }

    func explicitOverrideCount(for feedID: String) -> Int {
        WiltedMacShowSetting.allCases.filter { isOverridden($0, for: feedID) }.count
    }

    func customizedSettingNames(for feedID: String) -> [String] {
        WiltedMacShowSetting.allCases.filter { isOverridden($0, for: feedID) }.map { setting in
            return switch setting {
            case .autoKeep: "Auto keep"
            case .autoDownload: "Auto download"
            case .autoPrepare: "Auto prepare"
            case .keptLimit: "Kept limit"
            case .news: "Headlines only"
            case .removeAds: "Remove ads"
            case .selfPromotion: "Remove the show's own promotion"
            case .loudness: "Even out loudness"
            case .adFinding: "Send this show for ad finding"
            case .startOffset: "Start new episodes at"
            case .playbackSpeed: "Playback speed"
            }
        }
    }

    func reset(_ setting: WiltedMacShowSetting, for feedID: String) {
        guard isLoaded(feedID) else { return }
        switch setting {
        case .autoKeep:
            update(feedID, autoKeep: .useGlobal)
        case .autoDownload:
            update(feedID, autoDownload: .useGlobal)
        case .autoPrepare:
            update(feedID, autoPrepare: .useGlobal)
        case .keptLimit:
            update(feedID, keptLimit: .useGlobal)
        case .news:
            _ = setNews(false, for: feedID)
        case .removeAds:
            if isAdFree(feedID), model.automationSettings.removeAds {
                resetAdFinding(for: feedID)
            }
            _ = setAdFree(false, for: feedID)
        case .selfPromotion:
            _ = setRemoveSelfPromotion(false, for: feedID)
        case .loudness:
            _ = setLoudnessOverride(.inherit, for: feedID)
        case .adFinding:
            if isOverridden(.adFinding, for: feedID) { resetAdFinding(for: feedID) }
        case .startOffset:
            if isStartOffsetCustomized(feedID) { scheduleStartOffsetEdit(0, for: feedID, reset: true) }
        case .playbackSpeed:
            if isShowPlaybackSpeedCustomized(feedID) { scheduleShowPlaybackSpeedEdit(nil, for: feedID, reset: true) }
        }
    }

    /// Keeps the picker and Reset action on the same safe return-to-default path.
    func setRemoveAdsOverride(_ isCustomOff: Bool, for feedID: String) {
        guard isLoaded(feedID) else { return }
        if isCustomOff {
            _ = setAdFree(true, for: feedID)
        } else {
            reset(.removeAds, for: feedID)
        }
    }

    /// Removes active overrides while keeping a previously refused show refused.
    @discardableResult
    func resetAllOverrides(for feedID: String) -> WiltedMacShowSettingsResetUndo? {
        guard isLoaded(feedID) else { return nil }
        refreshAdPreferences()
        guard explicitOverrideCount(for: feedID) > 0 else { return nil }

        let undo = WiltedMacShowSettingsResetUndo(
            feedID: feedID, policy: policy(for: feedID), isNews: isNews(feedID),
            isAdFree: isAdFree(feedID), removesSelfPromotion: removesSelfPromotion(feedID),
            loudnessOverride: loudnessOverride(feedID),
            sendsForAdFinding: sendsForAdFinding(feedID), startOffset: showStartOffsets[feedID],
            resetStartOffsetRevision: nil, playbackSpeed: showPlaybackSpeeds[feedID], resetPlaybackSpeedRevision: nil
        )

        // Revoke an opt-in before other changes can restart preparation.
        resetAdFinding(for: feedID)

        let current = policy(for: feedID)
        _ = update(
            feedID,
            autoKeep: current.autoKeep == .useGlobal ? nil : .useGlobal,
            autoDownload: isArticleFeed(feedID) || current.autoDownload == .useGlobal ? nil : .useGlobal,
            autoPrepare: current.autoPrepare == .useGlobal ? nil : .useGlobal,
            keptLimit: current.keptLimit == .useGlobal ? nil : .useGlobal
        )
        if isOverridden(.news, for: feedID) { reset(.news, for: feedID) }
        if isOverridden(.selfPromotion, for: feedID) { reset(.selfPromotion, for: feedID) }
        if isOverridden(.loudness, for: feedID) { reset(.loudness, for: feedID) }
        if isOverridden(.removeAds, for: feedID) { reset(.removeAds, for: feedID) }
        if isOverridden(.startOffset, for: feedID) { reset(.startOffset, for: feedID) }
        if isOverridden(.playbackSpeed, for: feedID) { reset(.playbackSpeed, for: feedID) }
        return WiltedMacShowSettingsResetUndo(
            feedID: undo.feedID, policy: undo.policy, isNews: undo.isNews, isAdFree: undo.isAdFree,
            removesSelfPromotion: undo.removesSelfPromotion, loudnessOverride: undo.loudnessOverride,
            sendsForAdFinding: undo.sendsForAdFinding,
            startOffset: undo.startOffset, resetStartOffsetRevision: showStartOffsetResetRevisions[feedID],
            playbackSpeed: undo.playbackSpeed,
            resetPlaybackSpeedRevision: showPlaybackSpeedResetRevisions[feedID])
    }

    /// Restores reset choices that still have their reset value, preserving any later edits.
    func undoResetAllOverrides(_ undo: WiltedMacShowSettingsResetUndo) async -> Bool {
        let feedID = undo.feedID
        guard isLoaded(feedID) else { return false }

        await settle()
        if model.store != nil {
            await showStartOffsetEditTasks[feedID]?.value
            await showPlaybackSpeedEditTasks[feedID]?.value
            await reload()
            guard loadState == .loaded, isLoaded(feedID) else { return false }
        }

        let current = policy(for: feedID)
        _ = update(
            feedID,
            autoKeep: current.autoKeep == .useGlobal ? undo.policy.autoKeep : nil,
            autoDownload: current.autoDownload == .useGlobal ? undo.policy.autoDownload : nil,
            autoPrepare: current.autoPrepare == .useGlobal ? undo.policy.autoPrepare : nil,
            keptLimit: current.keptLimit == .useGlobal ? undo.policy.keptLimit : nil
        )
        if isArticleFeed(feedID), !isNews(feedID), undo.isNews {
            _ = setNews(true, for: feedID)
        }
        if !removesSelfPromotion(feedID), undo.removesSelfPromotion {
            _ = setRemoveSelfPromotion(true, for: feedID)
        }
        if loudnessOverride(feedID) == .inherit, undo.loudnessOverride != .inherit {
            _ = setLoudnessOverride(undo.loudnessOverride, for: feedID)
        }
        if !isAdFree(feedID), undo.isAdFree {
            _ = setAdFree(true, for: feedID)
        }
        if !sendsForAdFinding(feedID), undo.sendsForAdFinding,
           !AdLabellerPreferences(preferences: model.preferences).keptBackFeedIDs.contains(feedID) {
            _ = setSendForAdFinding(true, for: feedID)
        }
        if let oldOffset = undo.startOffset,
           let resetRevision = undo.resetStartOffsetRevision ?? showStartOffsetResetRevisions[feedID],
           showStartOffsets[feedID]?.seconds == 0,
           showStartOffsets[feedID]?.revision == resetRevision {
            guard let restored = await setStartOffsetSeconds(oldOffset.seconds, for: feedID),
                  restored.seconds == oldOffset.seconds else { return false }
        }
        if let oldSpeed = undo.playbackSpeed, let resetRevision = undo.resetPlaybackSpeedRevision,
           showPlaybackSpeeds[feedID]?.speed == nil,
           showPlaybackSpeeds[feedID]?.revision == resetRevision {
            guard let restored = await setShowPlaybackSpeed(oldSpeed.speed, for: feedID),
                  restored.speed == oldSpeed.speed else { return false }
        }
        let expectedPolicy = policy(for: feedID)
        let expectedHeadlinesOnly = isNews(feedID)
        await settle()
        refreshAdPreferences()
        if let store = model.store {
            guard let id = try? ItemID(rawValue: feedID),
                  (try? await store.feedAutomationPolicy(for: id)) == expectedPolicy else { return false }
            if isArticleFeed(feedID) {
                return (try? await store.isNews(feedID: id)) == expectedHeadlinesOnly
            }
        }
        return policy(for: feedID) == expectedPolicy && isNews(feedID) == expectedHeadlinesOnly
    }
}
