import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Episode artwork kept on the phone, so Now Playing and the car list can show it with no network
/// and while the phone is locked. Reading never touches the network: a miss is simply no artwork.
/// Only `fetch` downloads, and only the app (phone unlocked, online) calls it.
///
/// Files are stored shrunk to `maxPixels` as JPEG, under `LibraryFileProtection`, so they read
/// after the first unlock like the audio and positions do.
struct LibraryArtworkCache: Sendable {
    /// The longest side kept. Enough for Now Playing; small enough to decode freely in a list.
    static let maxPixels = 600
    /// Larger downloads are ignored rather than decoded.
    static let maxDownloadBytes = 8_000_000

    let directory: URL
    /// How a remote address becomes bytes. Tests replace it; production uses `URLSession`.
    var download: @Sendable (URL) async -> Data? = LibraryArtworkCache.urlSessionDownload

    /// The cache the app uses, next to the library snapshot.
    @MainActor static let shared = LibraryArtworkCache(
        directory: LibraryEnvironment.defaultDirectory().appendingPathComponent("artwork", isDirectory: true))

    /// Posted (object: the address) after an image is stored, so Now Playing and the car list can pick
    /// up artwork that arrived after they were drawn.
    static let didCache = Notification.Name("wilted.library.artworkCached")

    /// Images already read this launch, so a list rebuild never reads the disk twice.
    // NSCache is documented thread-safe; keyed by file path so two directories never share an entry.
    nonisolated(unsafe) private static let memory = NSCache<NSString, NSData>()

    /// The image only if it is already in memory: no disk, no waiting.
    func loadedData(for url: URL?) -> Data? {
        url.flatMap { Self.memory.object(forKey: fileURL(for: $0).path as NSString) as Data? }
    }

    /// The stored image for `url`, or nil when it was never fetched. Disk only, never the network.
    /// Reads the file, so call it off the main actor; `loadedData` is the main-actor-safe lookup.
    func data(for url: URL?) -> Data? {
        guard let url else { return nil }
        if let loaded = loadedData(for: url) { return loaded }
        guard let data = try? Data(contentsOf: fileURL(for: url)) else { return nil }
        Self.memory.setObject(data as NSData, forKey: fileURL(for: url).path as NSString)
        return data
    }

    func isCached(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: fileURL(for: url).path) }

    /// Downloads and stores `url` unless it is already here. Returns whether an image is cached after.
    @discardableResult
    func fetch(_ url: URL) async -> Bool {
        if isCached(url) { return true }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let raw = await download(url), raw.count <= Self.maxDownloadBytes else { return false }
        return store(raw, for: url)
    }

    /// Fetches each address in turn; failures are skipped and tried again next time.
    func prefetch(_ urls: [URL]) async {
        for url in Set(urls) where !Task.isCancelled { await fetch(url) }
    }

    /// Shrinks and writes `raw`. False when it is not a decodable image.
    @discardableResult
    func store(_ raw: Data, for url: URL) -> Bool {
        guard let encoded = Self.shrunk(raw) else { return false }
        let file = fileURL(for: url)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try encoded.write(to: file, options: [.atomic, LibraryFileProtection.writingOption]) } catch { return false }
        Self.memory.setObject(encoded as NSData, forKey: fileURL(for: url).path as NSString)
        NotificationCenter.default.post(name: Self.didCache, object: url)
        return true
    }

    /// Deletes every stored image whose address is not in `keeping`, so artwork for episodes that left
    /// the Larder does not pile up. Returns how many files went.
    @discardableResult
    func prune(keeping urls: [URL]) -> Int {
        let keep = Set(urls.map { fileURL(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for file in files where file.pathExtension == "jpg" && !keep.contains(file.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: file)) != nil {
                Self.memory.removeObject(forKey: file.path as NSString)
                removed += 1
            }
        }
        return removed
    }

    func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".jpg")
    }

    private static func shrunk(_ raw: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Streams the body and gives up past `maxDownloadBytes`, so an oversized response is never held whole.
    private static let urlSessionDownload: @Sendable (URL) async -> Data? = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        if response.expectedContentLength > Int64(maxDownloadBytes) { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxDownloadBytes { return nil }
            }
        } catch { return nil }
        return data
    }
}
