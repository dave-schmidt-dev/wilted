import Foundation
import WiltedDomain

/// Reads bounded ID3v2.3/v2.4 CHAP frames from a downloaded episode.
/// It reads only the tag at the start of the file, never the audio body.
enum ID3PodcastChapterReader {
    static let maximumTagBytes = 4 * 1_024 * 1_024
    private static let maximumFrames = 10_000

    static func read(from url: URL) -> [PodcastChapterMark]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10), header.count == 10,
              Array(header.prefix(3)) == Array("ID3".utf8),
              header[3] == 3 || header[3] == 4 else { return nil }
        let version = header[3]
        let flags = header[5]
        // Compression and whole-tag unsynchronisation change frame boundaries;
        // decline those optional tags rather than risk a false seek time.
        guard flags & 0x80 == 0, version == 4 ? flags & 0x0C == 0 : flags & 0x40 == 0,
              let tagSize = synchsafe32(header, at: 6), tagSize > 0, tagSize <= maximumTagBytes,
              var tag = try? handle.read(upToCount: tagSize), tag.count == tagSize else { return nil }

        if version == 4, flags & 0x10 != 0 {
            guard tag.count >= 10 else { return nil }
            tag.removeLast(10)
        }
        var cursor = 0
        if flags & 0x40 != 0 {
            guard tag.count >= 4 else { return nil }
            if version == 3 {
                guard let size = bigEndian32(tag, at: 0), size <= tag.count - 4 else { return nil }
                cursor = 4 + size
            } else {
                guard let size = synchsafe32(tag, at: 0), size >= 4, size <= tag.count else { return nil }
                cursor = size
            }
        }

        var chapters: [PodcastChapterMark] = []
        var frameCount = 0
        while cursor + 10 <= tag.count, frameCount < maximumFrames {
            let idBytes = tag[cursor..<(cursor + 4)]
            if idBytes.allSatisfy({ $0 == 0 }) { break }
            guard idBytes.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) else { return nil }
            let id = String(decoding: idBytes, as: UTF8.self)
            let frameSize: Int?
            if version == 3 {
                frameSize = bigEndian32(tag, at: cursor + 4)
            } else {
                frameSize = synchsafe32(tag, at: cursor + 4)
            }
            guard let frameSize, frameSize > 0, frameSize <= tag.count - cursor - 10 else { return nil }
            let frameFlags = tag[cursor + 9]
            let bodyStart = cursor + 10
            let bodyEnd = bodyStart + frameSize
            let body = tag[bodyStart..<bodyEnd]
            if id == "CHAP" {
                guard let mark = chapter(body, version: version, formatFlags: frameFlags, ordinal: chapters.count + 1) else {
                    return nil
                }
                chapters.append(mark)
                guard chapters.count <= PodcastChapterDocument.maximumRawChapters else { return nil }
            }
            cursor = bodyEnd
            frameCount += 1
        }
        guard !chapters.isEmpty,
              zip(chapters, chapters.dropFirst()).allSatisfy({ $0.1.startSeconds >= $0.0.startSeconds }) else { return nil }
        return chapters
    }

    private static func chapter(
        _ body: Data.SubSequence,
        version: UInt8,
        formatFlags: UInt8,
        ordinal: Int
    ) -> PodcastChapterMark? {
        let bytes = Data(body)
        guard let terminator = bytes.firstIndex(of: 0), terminator > bytes.startIndex,
              terminator <= 256 else { return nil }
        let fields = bytes.index(after: terminator)
        guard bytes.distance(from: fields, to: bytes.endIndex) >= 16,
              let milliseconds = bigEndian32(bytes, at: bytes.distance(from: bytes.startIndex, to: fields)),
              milliseconds != UInt32.max else { return nil }
        let unsupportedMask: UInt8 = version == 3 ? 0xC0 : 0x0C
        guard formatFlags & unsupportedMask == 0,
              (version == 3 ? formatFlags & 0x20 == 0 : formatFlags & 0x43 == 0) else { return nil }
        let offset = bytes.distance(from: bytes.startIndex, to: fields) + 16
        let title = subframeTitle(bytes, version: version, startingAt: offset) ?? "Chapter \(ordinal)"
        let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PodcastChapterDocument.maximumTitleCharacters))
        return PodcastChapterMark(title: clean.isEmpty ? "Chapter \(ordinal)" : clean,
                                  startSeconds: Double(milliseconds) / 1_000)
    }

    private static func subframeTitle(_ body: Data.SubSequence, version: UInt8, startingAt start: Int) -> String? {
        var cursor = start
        var framesRead = 0
        while cursor + 10 <= body.count, framesRead < 256 {
            let idStart = body.index(body.startIndex, offsetBy: cursor)
            let idEnd = body.index(idStart, offsetBy: 4)
            let idBytes = body[idStart..<idEnd]
            if idBytes.allSatisfy({ $0 == 0 }) { return nil }
            let id = String(decoding: idBytes, as: UTF8.self)
            let headerOffset = cursor
            let size: Int?
            if version == 3 {
                size = bigEndian32(body, at: headerOffset + 4)
            } else {
                size = synchsafe32(body, at: headerOffset + 4)
            }
            guard let size, size > 0, size <= body.count - cursor - 10 else { return nil }
            let startOffset = body.index(body.startIndex, offsetBy: cursor + 10)
            let endOffset = body.index(startOffset, offsetBy: size)
            if id == "TIT2" || id == "TIT3" {
                let bytes = body[startOffset..<endOffset]
                guard let encoding = bytes.first else { return nil }
                return decodedText(bytes.dropFirst(), encoding: encoding)
            }
            cursor += 10 + size
            framesRead += 1
        }
        return nil
    }

    private static func decodedText(_ bytes: Data.SubSequence, encoding: UInt8) -> String? {
        let data = Data(bytes)
        let decoded: String?
        switch encoding {
        case 0: decoded = String(data: data.prefix { $0 != 0 }, encoding: .isoLatin1)
        case 1, 2: decoded = String(data: data, encoding: encoding == 1 ? .utf16 : .utf16BigEndian)
        case 3: decoded = String(data: data.prefix { $0 != 0 }, encoding: .utf8)
        default: return nil
        }
        return decoded?.trimmingCharacters(in: .controlCharacters)
    }

    private static func bigEndian32(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
    }

    private static func synchsafe32(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = Array(data[offset..<(offset + 4)])
        guard bytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        return (Int(bytes[0]) << 21) | (Int(bytes[1]) << 14) | (Int(bytes[2]) << 7) | Int(bytes[3])
    }
}
