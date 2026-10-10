import AVFoundation
import CryptoKit
import Foundation
import SwiftData
import WiltedDomain

/// One morning report ready to be committed: its immutable revision, its media file (already in
/// the media folder) and the display fields of its record. A report is stored as a single-volume
/// `AudiobookRecord` whose source format is `LocalLibraryStore.reportSourceFormat`, so it needs
/// no schema change and shares the audiobook ready-revision, queue and removal paths.
public struct MorningReportSave: Sendable {
    public let itemID: ItemID
    public let revision: AudioRevision
    public let mediaURL: URL
    public let title: String
    public let createdAt: Date

    public init(itemID: ItemID, revision: AudioRevision, mediaURL: URL, title: String, createdAt: Date) {
        self.itemID = itemID; self.revision = revision; self.mediaURL = mediaURL
        self.title = title; self.createdAt = createdAt
    }
}

/// What `LocalLibraryStore.saveMorningReport` did, decided inside the store's own write.
public enum MorningReportSaveOutcome: Equatable, Sendable {
    /// The report was committed; `retired` are the earlier reports it replaced.
    case saved(retired: [ItemID])
    /// A report with this ID was already saved; nothing changed and the caller's media is unreferenced.
    case alreadyExists
}

extension LocalLibraryStore {
    /// The `sourceFormat` that marks an audiobook-table row as a morning report.
    public static let reportSourceFormat = "report"

    /// A report's identity: stable for the same script on the same day, new otherwise.
    public static func reportItemID(script: String, day: String) throws -> ItemID {
        let digest = SHA256.hash(data: Data("\(day)\n\(script)".utf8)).map { String(format: "%02x", $0) }.joined()
        return try ItemID.audiobook(contentDigest: digest, layout: "report-1", volume: 0)
    }

    /// Whether a report with this ID is already saved. Callers check before writing media.
    public func hasMorningReport(_ itemID: ItemID) throws -> Bool {
        let context = ModelContext(container)
        let books = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.AudiobookRecord>())
        return books.contains { $0.id == itemID.rawValue }
    }

    /// Commits a report in one save: its ready revision and record, a place at the front of the
    /// queue, and the retirement of every earlier report that was not played to the end (its
    /// record is marked removed and it leaves the queue). A report that is already saved is left
    /// alone and retires nothing; the existence check and the commit run in this one actor-isolated
    /// call, so of two concurrent saves for the same ID exactly one returns `.saved`.
    @discardableResult
    public func saveMorningReport(_ report: MorningReportSave) throws -> MorningReportSaveOutcome {
        let context = ModelContext(container)
        let books = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.AudiobookRecord>())
        guard !books.contains(where: { $0.id == report.itemID.rawValue }) else { return .alreadyExists }
        let revisions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisions.first(where: { $0.id == report.revision.revisionID.rawValue }) {
            guard existing.itemID == report.revision.itemID.rawValue, existing.contentHash == report.revision.contentHash,
                  existing.mediaURL == report.mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(report.revision.revisionID, site: .readyRevision)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(report.revision, mediaURL: report.mediaURL))
        }
        let completed = Set(try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
            .filter { $0.completedAt != nil }.map(\.id))
        let previous = books.filter {
            $0.sourceFormat == Self.reportSourceFormat && !$0.isRemoved && !completed.contains($0.id)
        }
        for book in previous { book.isRemoved = true }
        let retired = Set(previous.map(\.id))
        let queue = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        for record in queue where retired.contains(record.episodeID) { context.delete(record) }
        // Stored positions keep the current-item offset, so shifting every row by one keeps
        // order and the current marker; the new report takes position 0.
        for record in queue where !retired.contains(record.episodeID) { record.position += 1 }
        context.insert(LocalLibrarySchemaV17Models.AudiobookRecord(
            id: report.itemID.rawValue, title: report.title, author: nil,
            durationSeconds: report.revision.durationSeconds, chapters: Data("[]".utf8),
            sourceFormat: Self.reportSourceFormat, volumeIndex: 0, volumeCount: 1, createdAt: report.createdAt
        ))
        context.insert(LocalLibrarySchemaV6Models.PodcastQueueRecord(
            try PodcastQueueEntry(episodeID: report.itemID, position: 0, addedAt: Timestamp(report.createdAt))
        ))
        try context.save()
        return .saved(retired: retired.compactMap { try? ItemID(rawValue: $0) }.sorted { $0.rawValue < $1.rawValue })
    }
}

/// Encodes a synthesized report as mono AAC at the speech rate.
public enum MorningReportAudio {
    /// Writes `samples` into a temp file whose name ends in `.m4a`, reads it back, and renames it to
    /// `destination` (which must end in `.m4a`). The temp name matters: `AVAudioFile` picks the
    /// container from the extension, and a file written under another one (as `AudioAssembler`'s
    /// `.tmp-<uuid>` names are) is not loadable by `AVURLAsset` after a rename. Returns the duration
    /// of the finished file in seconds.
    public static func write(samples: [Float], sampleRate: Int, to destination: URL) throws -> Double {
        guard !samples.isEmpty, sampleRate > 0, samples.allSatisfy(\.isFinite) else {
            throw AudioAssemblerError.invalidPCM("the speech result has no usable samples")
        }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).tmp.m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        let rate = Double(sampleRate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw AudioAssemblerError.invalidPCM("could not create the PCM format")
        }
        do {
            let file = try AVAudioFile(forWriting: temp, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            var offset = 0
            while offset < samples.count {
                if Task.isCancelled { throw AudioAssemblerError.cancelled }
                let count = min(1 << 14, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else {
                    throw AudioAssemblerError.invalidPCM("could not allocate a PCM chunk")
                }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!.advanced(by: offset), count: count) }
                try file.write(from: buffer)
                offset += count
            }
        }
        let expected = Double(samples.count) / rate
        let written = try AVAudioFile(forReading: temp)
        let duration = Double(written.length) / written.processingFormat.sampleRate
        guard duration.isFinite, abs(duration - expected) <= max(0.2, expected * 0.02) else {
            throw AudioAssemblerError.invalidAudio("the report file is \(duration) s, expected \(expected) s")
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return duration
    }
}
