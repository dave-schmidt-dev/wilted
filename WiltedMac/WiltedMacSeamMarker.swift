/// A short, quiet marker played at a prepared podcast seam where an advertisement was removed.
///
/// The marker is mixed at playback time rather than baked into prepared audio. Baking would
/// require a gap in the kept map, which `PreparationTimeline` rejects as non-contiguous, and
/// turning it off would require re-preparing the whole library.
import AVFoundation
import Foundation
import os

enum WiltedMacSeamMarkerTone {
    static let frequency = 432.0
    static let duration = 0.28
    static let peakAmplitude = 0.18
    static let fadeIn = 0.04
    static let fadeOut = 0.16

    /// Returns a self-contained 16-bit mono PCM WAV for the seam marker.
    static func wavData(sampleRate: Int = 44_100) -> Data {
        precondition(sampleRate > 0)
        let sampleCount = Int(duration * Double(sampleRate))
        let byteCount = sampleCount * MemoryLayout<Int16>.size
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + byteCount), to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * MemoryLayout<Int16>.size), to: &data)
        append(UInt16(MemoryLayout<Int16>.size), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(UInt32(byteCount), to: &data)

        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let fadeInGain = raisedCosine(progress: time / fadeIn)
            let fadeOutGain = raisedCosine(progress: (duration - time) / fadeOut)
            let amplitude = peakAmplitude * min(fadeInGain, fadeOutGain)
            let sample = Int16(clamping: Int((sin(2 * .pi * frequency * time) * amplitude
                * Double(Int16.max)).rounded()))
            append(UInt16(bitPattern: sample), to: &data)
        }
        return data
    }

    private static func raisedCosine(progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 0.5 - 0.5 * cos(.pi * clamped)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

enum WiltedMacSeamMarkerSchedule {
    static let rewindAllowance: TimeInterval = 0.5
    static let fireTolerance: TimeInterval = 0.3

    /// The seam already marked for this episode, or nil when the mark belongs to
    /// another episode or the listener has gone back more than `rewindAllowance` before it.
    static func effectiveLastMarked(
        _ last: (episodeID: String, seconds: TimeInterval)?, episodeID: String, position: TimeInterval
    ) -> TimeInterval? {
        guard let last, last.episodeID == episodeID,
              position >= last.seconds - rewindAllowance else { return nil }
        return last.seconds
    }

    static func shouldFire(seam: TimeInterval, livePosition: TimeInterval, isPlaying: Bool) -> Bool {
        isPlaying && abs(livePosition - seam) <= fireTolerance
    }

    static func next(
        seams: [TimeInterval], position: TimeInterval, rate: Double,
        isPlaying: Bool, enabled: Bool, lastMarked: TimeInterval?
    ) -> (seam: TimeInterval, delay: TimeInterval)? {
        guard enabled, isPlaying, rate > 0 else { return nil }
        guard let seam = seams.sorted().first(where: {
            $0 >= 0.5 && $0 > position + 0.05 && $0 != lastMarked
        }) else { return nil }
        return (seam, (seam - position) / rate)
    }
}

@MainActor
protocol WiltedMacSeamMarkerOutput: AnyObject {
    func play(volume: Float)
}

@MainActor
final class WiltedMacAVSeamMarkerOutput: WiltedMacSeamMarkerOutput {
    private static let log = Logger(subsystem: "com.zerodelta.wilted.mac", category: "SeamMarker")
    private var player: AVAudioPlayer?

    func play(volume: Float) {
        if player == nil {
            do {
                player = try AVAudioPlayer(data: WiltedMacSeamMarkerTone.wavData())
            } catch {
                Self.log.warning(
                    "could not create seam marker player: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard let player else { return }
        player.currentTime = 0
        player.volume = volume
        if !player.play() {
            Self.log.warning("could not play seam marker")
        }
    }
}

@MainActor
final class WiltedMacSilentSeamMarkerOutput: WiltedMacSeamMarkerOutput {
    private(set) var playCount = 0

    func play(volume: Float) {
        playCount += 1
    }
}
