import Foundation

/// One labelling request: the prompt text and the model settings. Nothing else about the
/// show, feed, episode, device, or user travels with it.
public struct LabellerRequest: Sendable {
    /// The whole-episode prompt built by ``EpisodeLabeller``.
    public var prompt: String
    /// The provider model identifier.
    public var modelID: String
    /// The reasoning effort level, sent as `reasoning_effort`.
    public var reasoningLevel: String

    public init(prompt: String, modelID: String, reasoningLevel: String) {
        self.prompt = prompt
        self.modelID = modelID
        self.reasoningLevel = reasoningLevel
    }
}

/// Token counts for one call, when the provider reports them.
public struct LabellerUsage: Equatable, Sendable, Codable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var reasoningTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
    }
}

/// A completed labelling call.
public struct LabellerResponse: Equatable, Sendable {
    /// The full answer text, joined from the stream.
    public var text: String
    /// The usage the provider reported, if any.
    public var usage: LabellerUsage
    /// Always 1: one call makes exactly one HTTP request, with no internal retry.
    public let requestCount: Int

    public init(text: String, usage: LabellerUsage) {
        self.text = text
        self.usage = usage
        requestCount = 1
    }
}

/// Streaming progress: bytes received so far and characters of answer text so far.
public struct LabellerProgress: Equatable, Sendable {
    public var bytesReceived: Int
    public var answerCharacters: Int

    public init(bytesReceived: Int, answerCharacters: Int) {
        self.bytesReceived = bytesReceived
        self.answerCharacters = answerCharacters
    }
}

/// The one place that talks to the ad-labeller provider. One call is one streaming
/// chat-completions request with no internal retry. Nothing here logs, and the key is
/// used only to build the Authorization header.
public struct LabellerClient: Sendable {
    /// The provider endpoint. Fixed; not configurable from preferences.
    public static let endpoint = URL(string: "https://opencode.ai/inference/go/openai/v1/chat/completions")!
    static let userAgent = "wilted-ad-labeller/1"
    /// The default request time limit.
    public static let defaultTimeLimit: Duration = .seconds(900)
    /// The largest error body kept for failure mapping.
    static let maximumErrorBodyBytes = 65_536
    /// A reply larger than this is refused rather than buffered without limit.
    static let maximumResponseBytes = 8 * 1_024 * 1_024

    private let keyStore: any LabellerKeyStoring
    private let configuration: URLSessionConfiguration
    private let timeLimit: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - keyStore: where the provider key is kept.
    ///   - configuration: copied, then stripped of cookie storage, URL cache, and cache reuse.
    ///   - timeLimit: how long one call may take overall.
    ///   - sleep: the timer the limit is measured with, injectable so a test can fire it at once.
    public init(
        keyStore: any LabellerKeyStoring,
        configuration: URLSessionConfiguration = .ephemeral,
        timeLimit: Duration = LabellerClient.defaultTimeLimit,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.keyStore = keyStore
        let copied = configuration.copy() as! URLSessionConfiguration
        copied.httpCookieStorage = nil
        copied.httpShouldSetCookies = false
        copied.urlCache = nil
        copied.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = copied
        self.timeLimit = timeLimit
        self.sleep = sleep
    }

    /// Performs one labelling request.
    ///
    /// `onRequestStarted` fires exactly once, immediately before the HTTP request
    /// starts; the caller counts it against a daily cap, including calls that then fail.
    /// With no stored key the call throws ``LabellerFailure/keyRejected`` without
    /// starting a request. Cancelling the surrounding task cancels the HTTP request and
    /// throws `CancellationError`.
    public func send(
        _ request: LabellerRequest,
        onRequestStarted: @escaping @Sendable () -> Void,
        onProgress: @escaping @Sendable (LabellerProgress) -> Void
    ) async throws -> LabellerResponse {
        guard let key = try keyStore.read(), !key.isEmpty else { throw LabellerFailure.keyRejected }
        let body = try Self.makeRequestBody(request)
        onRequestStarted()
        let configuration = self.configuration
        let timeout = Self.timeoutInterval(for: timeLimit)
        let limit = timeLimit
        let sleeper = sleep
        return try await withThrowingTaskGroup(of: LabellerResponse.self) { group in
            group.addTask {
                try await Self.perform(request, key: key, body: body, timeout: timeout,
                                       configuration: configuration, onProgress: onProgress)
            }
            group.addTask {
                try await sleeper(limit)
                throw TimeLimitReached()
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else { throw LabellerFailure.temporary }
                return first
            } catch let failure as LabellerFailure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw LabellerFailure.temporary
            }
        }
    }

    /// Maps an HTTP failure to a ``LabellerFailure``. Pure: no I/O and no clock read
    /// beyond `now`, so it can be tested directly.
    public static func failure(status: Int, headers: [String: String], body: Data, now: Date) -> LabellerFailure {
        switch status {
        case 401, 403:
            return .keyRejected
        case 402:
            return .usageLimit
        case 429:
            let keywords = errorKeywords(in: body)
            if ["budget", "quota", "usage limit", "insufficient"].contains(where: keywords.contains) {
                return .usageLimit
            }
            return .rateLimited(retryAfter: retryAfter(headers: headers, now: now))
        case 404:
            return .modelUnavailable
        case 400:
            return errorKeywords(in: body).contains("model") ? .modelUnavailable : .temporary
        default:
            return .temporary
        }
    }

    // MARK: - Request building

    /// The request, exactly: the fixed endpoint, five headers, and the encoded body.
    /// The session header is a fresh UUID per call.
    static func makeURLRequest(_ request: LabellerRequest, key: String, body: Data, timeout: TimeInterval) -> URLRequest {
        var urlRequest = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue(UUID().uuidString, forHTTPHeaderField: "x-opencode-session")
        urlRequest.httpBody = body
        return urlRequest
    }

    /// The body: exactly the five documented top-level keys, nothing else.
    static func makeRequestBody(_ request: LabellerRequest) throws -> Data {
        try JSONEncoder().encode(RequestBody(
            model: request.modelID,
            messages: [RequestBody.Message(role: "user", content: request.prompt)],
            reasoning_effort: request.reasoningLevel,
            stream: true,
            stream_options: RequestBody.StreamOptions(include_usage: true)))
    }

    static func timeoutInterval(for limit: Duration) -> TimeInterval {
        let parts = limit.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return max(1, seconds)
    }

    /// The provider's error type and message, lowercased, from either observed body
    /// shape: `{"error":{"type","message"}}` or `{"type":"error","error":{"type","message"}}`.
    static func errorKeywords(in body: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return "" }
        var parts: [String] = []
        if let topType = object["type"] as? String { parts.append(topType) }
        if let error = object["error"] as? [String: Any] {
            if let type = error["type"] as? String { parts.append(type) }
            if let message = error["message"] as? String { parts.append(message) }
        }
        return parts.joined(separator: " ").lowercased()
    }

    /// `Retry-After` (matched case-insensitively) as whole seconds or an HTTP date
    /// relative to `now`; negative values clamp to 0; nil when absent or unreadable.
    static func retryAfter(headers: [String: String], now: Date) -> TimeInterval? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds.isFinite { return max(0, seconds) }
        if let date = httpDate(trimmed) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }

    static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz",
                       "EEEE, dd-MMM-yy HH:mm:ss zzz",
                       "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    // MARK: - Streaming

    /// Runs one request and parses the answer as it arrives.
    private static func perform(
        _ request: LabellerRequest,
        key: String,
        body: Data,
        timeout: TimeInterval,
        configuration: URLSessionConfiguration,
        onProgress: @Sendable (LabellerProgress) -> Void
    ) async throws -> LabellerResponse {
        let stream = AsyncThrowingStream<LabellerHTTPEvent, Error>(bufferingPolicy: .unbounded) { continuation in
            let operation = LabellerHTTPOperation(continuation: continuation)
            let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: nil)
            operation.start(session: session,
                            request: makeURLRequest(request, key: key, body: body, timeout: timeout))
            continuation.onTermination = { _ in operation.cancel() }
        }

        let decoder = JSONDecoder()
        var status: Int?
        var headers: [String: String] = [:]
        var contentType: String?
        var body = Data()
        var assembler = LineAssembler()
        var text = ""
        var reportedUsage: LabellerUsage?
        var sawDone = false
        var finishReason: String?
        var bytesReceived = 0

        func consume(_ line: String) {
            guard line.hasPrefix("data:") else { return }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { sawDone = true; return }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(LabellerChunk.self, from: data) else { return }
            if let content = chunk.choices?.first?.delta?.content { text += content }
            if let reason = chunk.choices?.first?.finish_reason { finishReason = reason }
            if let reported = chunk.usage { reportedUsage = makeUsage(from: reported) }
        }

        for try await event in stream {
            switch event {
            case .response(let code, let fields, let type):
                status = code
                headers = fields
                contentType = type
            case .data(let data):
                guard let code = status else { continue }
                bytesReceived += data.count
                if bytesReceived > maximumResponseBytes { throw LabellerFailure.unusableAnswer }
                if code == 200 {
                    if (contentType ?? "").lowercased().contains("application/json") {
                        body.append(data)
                    } else {
                        for line in assembler.lines(in: data) { consume(line) }
                    }
                } else if body.count < maximumErrorBodyBytes {
                    body.append(data)
                }
                onProgress(LabellerProgress(bytesReceived: bytesReceived, answerCharacters: text.count))
            }
        }
        try Task.checkCancellation()
        guard let code = status else { throw LabellerFailure.temporary }
        if code != 200 {
            throw failure(status: code, headers: headers, body: body, now: Date())
        }
        if (contentType ?? "").lowercased().contains("application/json") {
            guard let whole = try? decoder.decode(LabellerChunk.self, from: body) else {
                throw LabellerFailure.unusableAnswer
            }
            let content = whole.choices?.first?.message?.content ?? ""
            if content.isEmpty { throw LabellerFailure.unusableAnswer }
            if let reason = whole.choices?.first?.finish_reason, reason != "stop" {
                throw LabellerFailure.unusableAnswer
            }
            return LabellerResponse(text: content, usage: whole.usage.map { makeUsage(from: $0) } ?? LabellerUsage())
        }
        if let remainder = assembler.flush() { consume(remainder) }
        if !sawDone { throw LabellerFailure.temporary }
        if text.isEmpty { throw LabellerFailure.unusableAnswer }
        if let finishReason, finishReason != "stop" { throw LabellerFailure.unusableAnswer }
        return LabellerResponse(text: text, usage: reportedUsage ?? LabellerUsage())
    }

    private static func makeUsage(from payload: LabellerChunk.Usage) -> LabellerUsage {
        LabellerUsage(
            promptTokens: payload.prompt_tokens,
            completionTokens: payload.completion_tokens,
            reasoningTokens: payload.completion_tokens_details?.reasoning_tokens
                ?? payload.opencode?.tokens?.reasoning)
    }

    /// Raised by the timer child when the request time limit fires.
    private struct TimeLimitReached: Error {}

    /// The request body: exactly these top-level keys, nothing else.
    private struct RequestBody: Encodable {
        var model: String
        var messages: [Message]
        var reasoning_effort: String
        var stream: Bool
        var stream_options: StreamOptions

        struct Message: Encodable {
            var role: String
            var content: String
        }

        struct StreamOptions: Encodable {
            var include_usage: Bool
        }
    }
}

// MARK: - HTTP plumbing

/// One delegate callback turned into a value.
private enum LabellerHTTPEvent: Sendable {
    case response(status: Int, headers: [String: String], contentType: String?)
    case data(Data)
}

/// One server-sent-event chunk, or a whole non-streamed completion body. Every field is
/// optional so unknown fields and missing fields are tolerated.
private struct LabellerChunk: Decodable {
    var choices: [Choice]?
    var usage: Usage?
    struct Choice: Decodable {
        var delta: Delta?
        var message: Message?
        var finish_reason: String?
    }
    struct Delta: Decodable {
        var content: String?
        var reasoning_content: String?
    }
    struct Message: Decodable {
        var content: String?
    }
    struct Usage: Decodable {
        var prompt_tokens: Int?
        var completion_tokens: Int?
        var completion_tokens_details: CompletionTokensDetails?
        var opencode: Opencode?
        struct CompletionTokensDetails: Decodable {
            var reasoning_tokens: Int?
        }
        struct Opencode: Decodable {
            struct Tokens: Decodable {
                var reasoning: Int?
            }
            var tokens: Tokens?
        }
    }
}

/// Splits received bytes into newline-terminated lines, holding any partial line back.
private struct LineAssembler {
    private var pending = Data()

    mutating func lines(in chunk: Data) -> [String] {
        pending.append(chunk)
        var result: [String] = []
        while let index = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<index]
            pending.removeSubrange(pending.startIndex...index)
            if line.last == 0x0D { line = line.dropLast() }
            result.append(String(decoding: line, as: UTF8.self))
        }
        return result
    }

    /// Any unterminated remainder, as one final line.
    mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        var line = pending
        pending.removeAll()
        if line.last == 0x0D { line = line.dropLast() }
        return String(decoding: line, as: UTF8.self)
    }
}

/// Runs one HTTP request, turning delegate callbacks into a stream of events. Every
/// redirect is refused, so the Authorization header is never forwarded anywhere.
private final class LabellerHTTPOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<LabellerHTTPEvent, Error>.Continuation
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var terminalError: Error?
    private var completed = false

    init(continuation: AsyncThrowingStream<LabellerHTTPEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func start(session: URLSession, request: URLRequest) {
        lock.withLock {
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        lock.withLock { task?.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The endpoint is fixed, so every redirect is refused: the Authorization header
        // never follows one, to another host or to plain HTTP.
        lock.withLock { terminalError = LabellerFailure.temporary }
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { terminalError = LabellerFailure.temporary }
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        continuation.yield(.response(status: http.statusCode, headers: headers,
                                    contentType: http.value(forHTTPHeaderField: "Content-Type")))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion: (Result<Void, Error>, URLSession)? = lock.withLock {
            guard !completed, let retainedSession = self.session else { return nil }
            completed = true
            let result: Result<Void, Error>
            if let terminalError { result = .failure(terminalError) }
            else if let urlError = error as? URLError, urlError.code == .cancelled {
                result = .failure(CancellationError())
            } else if let error { result = .failure(error) }
            else { result = .success(()) }
            self.session = nil
            self.task = nil
            return (result, retainedSession)
        }
        guard let completion else { return }
        switch completion.0 {
        case .success: continuation.finish()
        case .failure(let error): continuation.finish(throwing: error)
        }
        completion.1.finishTasksAndInvalidate()
    }
}
