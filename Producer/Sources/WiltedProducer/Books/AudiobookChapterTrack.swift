import Foundation

/// Adds a QuickTime chapter track to a finished MPEG-4 audio file.
///
/// `AVAssetWriter` refuses a text or metadata input for an m4a, and a boxed-metadata chapter
/// track in an mp4 or mov is not read back as chapters (`availableChapterLocales` stays empty;
/// checked on macOS 27). What AVFoundation does read is a text track that the audio track
/// names with a `tref`/`chap` reference, the layout ffmpeg writes for m4b files. The writer
/// puts `moov` last, so the samples go in a new `mdat` where `moov` was and `moov` is
/// rewritten after them; the audio offsets do not move.
enum AudiobookChapterTrack {
    static func embed(_ marks: [AudiobookChapterMark], in url: URL) throws {
        guard !marks.isEmpty else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard let moov = try trailingMovieBox(handle, end: end) else {
            throw AudiobookJoinerError.writerFailed("the file has no trailing movie box to hold chapters")
        }
        try handle.seek(toOffset: moov.start)
        var movie = try handle.read(upToCount: Int(moov.size)) ?? Data()
        guard let mvhd = child("mvhd", in: movie, from: 8), let trak = child("trak", in: movie, from: 8),
              let tkhd = child("tkhd", in: movie, from: trak.start + 8, to: trak.end) else {
            throw AudiobookJoinerError.writerFailed("the file's movie box is incomplete")
        }
        let version = movie[mvhd.start + 8]
        let scaleAt = mvhd.start + (version == 1 ? 28 : 20)
        let timescale = UInt32(movie.bigEndian(at: scaleAt, count: 4))
        let units = movie.bigEndian(at: scaleAt + 4, count: version == 1 ? 8 : 4)
        let nextID = UInt32(movie.bigEndian(at: mvhd.end - 4, count: 4))
        let milliseconds = Int(Double(units) / Double(max(timescale, 1)) * 1000)
        let samples = chapterSamples(marks, durationMilliseconds: milliseconds)
        guard !samples.isEmpty else { return }
        movie.replaceSubrange(mvhd.end - 4..<mvhd.end, with: Data.bigEndian(nextID + 1, bytes: 4))

        let reference = Data.box("tref", Data.box("chap", Data.bigEndian(nextID, bytes: 4)))
        movie.insert(contentsOf: reference, at: tkhd.end)
        movie.replaceSubrange(trak.start..<trak.start + 4, with: Data.bigEndian(UInt32(trak.end - trak.start + reference.count), bytes: 4))
        movie.append(textTrack(
            samples, id: nextID, movieUnits: units, milliseconds: milliseconds, firstSampleOffset: moov.start + 8
        ))
        movie.replaceSubrange(0..<4, with: Data.bigEndian(UInt32(movie.count), bytes: 4))

        try handle.truncate(atOffset: moov.start)
        try handle.seek(toOffset: moov.start)
        try handle.write(contentsOf: Data.box("mdat", samples.reduce(Data()) { $0 + $1.data }))
        try handle.write(contentsOf: movie)
    }

    private struct Sample { let data: Data; let delta: UInt32 }

    /// One text sample per chapter: a 16-bit length, the title, and the QuickTime `encd` UTF-8 marker.
    private static func chapterSamples(_ marks: [AudiobookChapterMark], durationMilliseconds: Int) -> [Sample] {
        var starts: [(title: String, ms: Int)] = []
        for (index, mark) in marks.sorted(by: { $0.startSeconds < $1.startSeconds }).enumerated() {
            let ms = index == 0 ? 0 : Int(mark.startSeconds * 1000)
            guard ms < durationMilliseconds, starts.last.map({ ms > $0.ms }) ?? true else { continue }
            starts.append((mark.title, ms))
        }
        return starts.enumerated().map { index, entry in
            var title = entry.title
            while title.utf8.count > 255 { title.removeLast() }
            var data = Data.bigEndian(UInt32(title.utf8.count), bytes: 2)
            data.append(contentsOf: title.utf8)
            data.append(Data.box("encd", Data.bigEndian(0x100, bytes: 4)))
            let next = index + 1 < starts.count ? starts[index + 1].ms : durationMilliseconds
            return Sample(data: data, delta: UInt32(next - entry.ms))
        }
    }

    private static func textTrack(
        _ samples: [Sample], id: UInt32, movieUnits: UInt64, milliseconds: Int, firstSampleOffset: UInt64
    ) -> Data {
        let n = UInt32(samples.count)
        var tkhd = Data.bigEndian(2, bytes: 4)            // version 0; flag: in movie, not enabled
        tkhd += Data.bigEndian(0, bytes: 8) + Data.bigEndian(id, bytes: 4) + Data.bigEndian(0, bytes: 4)
        tkhd += Data.bigEndian(UInt32(movieUnits), bytes: 4) + Data(count: 16)
        for value: UInt32 in [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x4000_0000] { tkhd += Data.bigEndian(value, bytes: 4) }
        tkhd += Data(count: 8)
        var mdhd = Data.bigEndian(0, bytes: 12) + Data.bigEndian(1000, bytes: 4)
        mdhd += Data.bigEndian(UInt32(milliseconds), bytes: 4) + Data.bigEndian(0x55C4_0000, bytes: 4)
        let hdlr = Data(count: 8) + Data("text".utf8) + Data(count: 12) + Data("SubtitleHandler".utf8) + Data(count: 1)
        var stts = Data.bigEndian(0, bytes: 4) + Data.bigEndian(n, bytes: 4)
        var stsz = Data.bigEndian(0, bytes: 8) + Data.bigEndian(n, bytes: 4)
        for sample in samples {
            stts += Data.bigEndian(1, bytes: 4) + Data.bigEndian(sample.delta, bytes: 4)
            stsz += Data.bigEndian(UInt32(sample.data.count), bytes: 4)
        }
        let stsc = Data.bigEndian(0, bytes: 4) + Data.bigEndian(1, bytes: 4) + Data.bigEndian(1, bytes: 4)
            + Data.bigEndian(n, bytes: 4) + Data.bigEndian(1, bytes: 4)
        let stco = Data.bigEndian(0, bytes: 4) + Data.bigEndian(1, bytes: 4) + Data.bigEndian(UInt32(firstSampleOffset), bytes: 4)
        let stbl = Data.box("stbl", Data.box("stsd", Data(hex: Self.sampleDescription)) + Data.box("stts", stts)
            + Data.box("stsc", stsc) + Data.box("stsz", stsz) + Data.box("stco", stco))
        let minf = Data.box("minf", Data.box("gmhd", Data(hex: Self.genericHeader))
            + Data.box("dinf", Data(hex: Self.dataInformation)) + stbl)
        return Data.box("trak", Data.box("tkhd", tkhd) + Data.box("mdia", Data.box("mdhd", mdhd) + Data.box("hdlr", hdlr) + minf))
    }

    // Constant boxes copied from an ffmpeg-written m4b: a QuickTime `text` sample description, its `gmhd`, and `dinf`.
    private static let sampleDescription = "00000000000000010000003b7465787400000000000000010000000100000000000000000000000000000000000000010000000000000000000d667461620001000100"
    private static let genericHeader = "00000018676d696e000000000040800080008000000000000000002c74657874000100000000000000000000000000000001000000000000000000000000000040000000"
    private static let dataInformation = "0000001c6472656600000000000000010000000c75726c2000000001"

    private static func trailingMovieBox(_ handle: FileHandle, end: UInt64) throws -> (start: UInt64, size: UInt64)? {
        var offset: UInt64 = 0
        var moov: (start: UInt64, size: UInt64)?
        while offset + 8 <= end {
            try handle.seek(toOffset: offset)
            let head = try handle.read(upToCount: 16) ?? Data()
            guard head.count >= 8 else { break }
            var size = head.bigEndian(at: 0, count: 4)
            if size == 1, head.count >= 16 { size = head.bigEndian(at: 8, count: 8) }
            if size == 0 { size = end - offset }
            guard size >= 8 else { break }
            if String(decoding: head[4..<8], as: UTF8.self) == "moov" { moov = (offset, size) }
            offset += size
        }
        guard let moov, moov.start + moov.size == end, moov.size < 1 << 30 else { return nil }
        return moov
    }

    /// The first direct child box named `type` between `from` and `to` of `data`.
    private static func child(_ type: String, in data: Data, from: Int, to: Int? = nil) -> (start: Int, end: Int)? {
        var position = from
        let limit = to ?? data.count
        while position + 8 <= limit {
            let size = Int(data.bigEndian(at: position, count: 4))
            guard size >= 8, position + size <= limit else { return nil }
            if String(decoding: data[position + 4..<position + 8], as: UTF8.self) == type { return (position, position + size) }
            position += size
        }
        return nil
    }
}

private extension Data {
    func bigEndian(at index: Int, count: Int) -> UInt64 {
        self[startIndex + index..<startIndex + index + count].reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func bigEndian<T: BinaryInteger>(_ value: T, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: UInt64(truncatingIfNeeded: value) >> UInt64(8 * (bytes - 1 - $0))) })
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        bigEndian(UInt32(8 + payload.count), bytes: 4) + Data(type.utf8) + payload
    }

    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
