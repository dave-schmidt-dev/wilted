import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

/// The speed picker's durable save, scoped to its own status line.
extension WiltedMacModel {
    /// Persists the chosen speed for the loaded episode. The live speed is
    /// already applied and is never rolled back; only the newest save may
    /// settle the status, and it never touches any other status line.
    func savePlaybackSpeed(_ speed: Double, for itemID: ItemID) {
        guard let store else { return }
        playbackCommands.speedOperation &+= 1
        let operation = playbackCommands.speedOperation
        playbackCommands.speedSave = WiltedMacSpeedSaveStatus(
            operation: operation, itemID: itemID.rawValue, speed: speed,
            phase: .saving, message: WiltedMacPlaybackCopy.speedSaving
        )
        let override = playbackCommands.speedSaveForTesting
        Task { [weak self] in
            defer { self?.playbackCommands.settledSpeedSaves += 1 }
            do {
                if let override {
                    try await override(speed)
                } else {
                    try await store.save(playbackSpeed: PodcastPlaybackSpeed(
                        itemID: itemID, speed: speed, updatedAt: Timestamp(Date())
                    ))
                }
                guard let self, self.playbackCommands.speedOperation == operation else { return }
                self.playbackCommands.speedSave = WiltedMacSpeedSaveStatus(
                    operation: operation, itemID: itemID.rawValue, speed: speed,
                    phase: .saved, message: WiltedMacPlaybackCopy.speedSaved
                )
            } catch {
                let stored = try? await store.playbackSpeed(for: itemID)
                guard let self, self.playbackCommands.speedOperation == operation else { return }
                let restart = stored?.speed ?? Double(self.playback?.defaultRate ?? 1)
                self.playbackCommands.speedSave = WiltedMacSpeedSaveStatus(
                    operation: operation, itemID: itemID.rawValue, speed: speed, phase: .failed,
                    message: WiltedMacPlaybackCopy.speedFailed(current: speed, restart: restart)
                )
            }
        }
    }

    /// The speed-save line for the loaded episode only.
    var currentSpeedSaveStatus: WiltedMacSpeedSaveStatus? {
        guard let status = playbackCommands.speedSave,
              status.itemID == playback?.itemID?.rawValue else { return nil }
        return status
    }

    func retrySpeedSave() {
        guard let status = currentSpeedSaveStatus, status.phase == .failed,
              let itemID = try? ItemID(rawValue: status.itemID) else { return }
        savePlaybackSpeed(playbackRate, for: itemID)
    }
}
#endif
