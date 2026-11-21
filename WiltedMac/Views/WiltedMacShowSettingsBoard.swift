import WiltedProducer

enum WiltedMacShowSetting: String, CaseIterable {
    case autoKeep
    case autoDownload
    case autoPrepare
    case keptLimit
    case news
    case removeAds
    case selfPromotion
    case adFinding
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
        case .adFinding:
            !isArticleFeed(feedID) && sendsForAdFinding(feedID)
        }
    }

    func explicitOverrideCount(for feedID: String) -> Int {
        WiltedMacShowSetting.allCases.filter { isOverridden($0, for: feedID) }.count
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
        case .adFinding:
            if isOverridden(.adFinding, for: feedID) { resetAdFinding(for: feedID) }
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
    func resetAllOverrides(for feedID: String) {
        guard isLoaded(feedID) else { return }

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
        if isOverridden(.removeAds, for: feedID) { reset(.removeAds, for: feedID) }
    }
}
