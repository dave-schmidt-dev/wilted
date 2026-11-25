import Darwin
import Foundation

/// A direct HTTPS transfer pinned to one DNS result that has passed the public-address policy.
struct PinnedArticleTransferRequest: Sendable {
    let url: URL
    let host: String
    let port: Int
    let address: String
    let maximumBytes: Int
}

protocol ArticleAddressResolving: Sendable {
    func addresses(for host: String) async throws -> [String]
}

protocol PinnedArticleTransferring: Sendable {
    func transfer(_ request: PinnedArticleTransferRequest) async throws -> Data
}

enum PublicHTTPSArticleError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case unsafeAddress
    case resolutionFailed
    case responseTooLarge
    case redirectLimit
    case invalidResponse
    case transferFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "This story link is not a supported HTTPS address."
        case .unsafeAddress: "This story link points to a private or reserved network address."
        case .resolutionFailed: "Wilted could not safely resolve the story address."
        case .responseTooLarge: "This story page is larger than Wilted can safely read."
        case .redirectLimit: "This story link redirected too many times."
        case .invalidResponse, .transferFailed: "Wilted could not safely fetch this story."
        }
    }
}

/// Fetches an article without allowing a redirect or DNS rebinding to reach a private address.
/// cURL is invoked without a shell and receives one already-validated IP through `--resolve`.
public struct PublicHTTPSArticleTransport: ArticleLoading, Sendable {
    public static let maximumRedirects = 5
    private static let maximumHeaderBytes = 64 * 1_024
    fileprivate static let curlURL = URL(fileURLWithPath: "/usr/bin/curl")

    private let resolver: any ArticleAddressResolving
    private let transferClient: any PinnedArticleTransferring

    public init() {
        resolver = SystemArticleAddressResolver()
        transferClient = CurlPinnedArticleTransfer()
    }

    init(resolver: any ArticleAddressResolving, transferClient: any PinnedArticleTransferring) {
        self.resolver = resolver
        self.transferClient = transferClient
    }

    public func load(
        _ url: URL,
        maximumBytes: Int,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> Data {
        try await load(url, maximumBytes: maximumBytes,
                       acceptedContentTypes: ["text/html", "application/xhtml+xml", "text/plain"],
                       requiresContentType: false, onProgress: onProgress)
    }

    /// Loads an application/json+chapters document with the same pinned DNS
    /// and redirect checks used for article extraction.
    func loadPodcastChapterDocument(_ url: URL, maximumBytes: Int) async throws -> Data {
        try await load(url, maximumBytes: maximumBytes,
                       acceptedContentTypes: ["application/json+chapters"],
                       requiresContentType: true, onProgress: { _ in })
    }

    private func load(
        _ url: URL,
        maximumBytes: Int,
        acceptedContentTypes: Set<String>,
        requiresContentType: Bool,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> Data {
        guard maximumBytes > 0 else { throw PublicHTTPSArticleError.responseTooLarge }
        var currentURL = url
        for redirect in 0...Self.maximumRedirects {
            try Task.checkCancellation()
            let destination = try Self.destination(for: currentURL)
            let resolved = try await resolver.addresses(for: destination.host)
            guard !resolved.isEmpty else { throw PublicHTTPSArticleError.resolutionFailed }
            guard resolved.allSatisfy(Self.isPublicAddress) else { throw PublicHTTPSArticleError.unsafeAddress }

            onProgress(nil)
            let request = PinnedArticleTransferRequest(
                url: currentURL,
                host: destination.host,
                port: destination.port,
                address: resolved[0],
                maximumBytes: maximumBytes + Self.maximumHeaderBytes
            )
            let raw: Data
            do {
                raw = try await transferClient.transfer(request)
            } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            let response = try Self.parseResponse(raw, maximumBodyBytes: maximumBytes)
            if Self.redirectStatus(response.statusCode) {
                guard redirect < Self.maximumRedirects else { throw PublicHTTPSArticleError.redirectLimit }
                guard let location = response.location,
                      let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
                    throw PublicHTTPSArticleError.invalidResponse
                }
                _ = try Self.destination(for: nextURL)
                currentURL = nextURL
                continue
            }
            guard response.statusCode == 200 else { throw PublicHTTPSArticleError.invalidResponse }
            if let encoding = response.header("content-encoding"), encoding.lowercased() != "identity" {
                throw PublicHTTPSArticleError.invalidResponse
            }
            if let rawType = response.header("content-type") {
                let contentType = rawType.split(separator: ";", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces).lowercased()
                guard let contentType, acceptedContentTypes.contains(contentType) else {
                    throw PublicHTTPSArticleError.invalidResponse
                }
            } else if requiresContentType {
                throw PublicHTTPSArticleError.invalidResponse
            }
            onProgress(1)
            return response.body
        }
        throw PublicHTTPSArticleError.redirectLimit
    }

    private struct Destination {
        let host: String
        let port: Int
    }

    private static func destination(for url: URL) throws -> Destination {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              !host.contains("%"), !host.contains("[") && !host.contains("]") else {
            throw PublicHTTPSArticleError.invalidURL
        }
        return Destination(host: host, port: 443)
    }

    static func isPublicAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let octets = withUnsafeBytes(of: &ipv4) { Array($0) }
            return isPublicIPv4(octets)
        }
        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let octets = withUnsafeBytes(of: &ipv6) { Array($0) }
            return isPublicIPv6(octets)
        }
        return false
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0], second = bytes[1], third = bytes[2]
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 0 { return false }
        if first == 192 && second == 88 && third == 99 { return false }
        if first == 192 && second == 168 { return false }
        if first == 198 && (second == 18 || second == 19 || (second == 51 && third == 100)) { return false }
        if first == 203 && second == 0 && third == 113 { return false }
        return true
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16, bytes[0] & 0xE0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] <= 0x01 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
        if bytes[0] == 0x3F && bytes[1] == 0xFF && bytes[2] & 0xF0 == 0 { return false }
        return true
    }

    private struct Response {
        let statusCode: Int
        let headers: [String: [String]]
        let body: Data
        var location: String? {
            guard let values = headers["location"], values.count == 1 else { return nil }
            return values[0]
        }
        func header(_ name: String) -> String? { headers[name]?.last }
    }

    private static func parseResponse(_ data: Data, maximumBodyBytes: Int) throws -> Response {
        let marker = Data([13, 10, 13, 10])
        var offset = 0
        while offset < data.count {
            guard let range = data.range(of: marker, in: offset..<data.count),
                  range.lowerBound - offset <= maximumHeaderBytes else {
                throw PublicHTTPSArticleError.invalidResponse
            }
            let head = data.subdata(in: offset..<range.lowerBound)
            guard let text = String(data: head, encoding: .isoLatin1) else {
                throw PublicHTTPSArticleError.invalidResponse
            }
            let lines = text.components(separatedBy: "\r\n")
            guard let first = lines.first, first.hasPrefix("HTTP/"),
                  let status = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
                throw PublicHTTPSArticleError.invalidResponse
            }
            var headers: [String: [String]] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw PublicHTTPSArticleError.invalidResponse }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !value.contains("\r"), !value.contains("\n") else {
                    throw PublicHTTPSArticleError.invalidResponse
                }
                headers[name, default: []].append(value)
            }
            offset = range.upperBound
            if (100..<200).contains(status) { continue }
            let body = data.subdata(in: offset..<data.count)
            guard body.count <= maximumBodyBytes else { throw PublicHTTPSArticleError.responseTooLarge }
            return Response(statusCode: status, headers: headers, body: body)
        }
        throw PublicHTTPSArticleError.invalidResponse
    }

    private static func redirectStatus(_ code: Int) -> Bool { [301, 302, 303, 307, 308].contains(code) }
}

private struct SystemArticleAddressResolver: ArticleAddressResolving {
    func addresses(for host: String) async throws -> [String] {
        try await Task.detached(priority: .utility) { try Self.lookup(host) }.value
    }

    private static func lookup(_ host: String) throws -> [String] {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { getaddrinfo($0, "443", &hints, &result) }
        guard status == 0, let first = result else { throw PublicHTTPSArticleError.resolutionFailed }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let entry = current {
            let value = entry.pointee
            if value.ai_family == AF_INET || value.ai_family == AF_INET6 {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let code = getnameinfo(
                    value.ai_addr, value.ai_addrlen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST
                )
                if code == 0 {
                    let nameBytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    addresses.append(String(decoding: nameBytes, as: UTF8.self))
                }
            }
            current = value.ai_next
        }
        return Array(Set(addresses)).sorted()
    }
}

private final class CurlProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        self.process = process
        if cancelled { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process?.isRunning == true
        let active = process
        lock.unlock()
        if running { active?.terminate() }
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

private struct CurlPinnedArticleTransfer: PinnedArticleTransferring {
    func transfer(_ request: PinnedArticleTransferRequest) async throws -> Data {
        let box = CurlProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let process = Process()
                let output = Pipe()
                process.executableURL = PublicHTTPSArticleTransport.curlURL
                let ip = request.address.contains(":") ? "[\(request.address)]" : request.address
                process.arguments = [
                    "--disable", "--globoff", "--silent", "--proto", "=https", "--connect-timeout", "6",
                    "--max-time", "30", "--max-filesize", String(request.maximumBytes),
                    "--noproxy", "*", "--header", "Accept-Encoding: identity",
                    "--dump-header", "-", "--output", "-", "--resolve",
                    "\(request.host):\(request.port):\(ip)", request.url.absoluteString
                ]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try box.start(process)
                defer { box.clear() }
                var data = Data()
                while true {
                    let chunk = try output.fileHandleForReading.read(upToCount: 16 * 1_024) ?? Data()
                    if chunk.isEmpty { break }
                    guard data.count + chunk.count <= request.maximumBytes else {
                        box.cancel()
                        process.waitUntilExit()
                        throw PublicHTTPSArticleError.responseTooLarge
                    }
                    data.append(chunk)
                }
                process.waitUntilExit()
                try Task.checkCancellation()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    throw PublicHTTPSArticleError.transferFailed
                }
                return data
            }.value
        } onCancel: {
            box.cancel()
        }
    }
}
