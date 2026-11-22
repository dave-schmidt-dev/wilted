import Foundation

/// Sends one labelling request to Anthropic's Messages endpoint (https://api.anthropic.com/v1/messages).
///
/// Safety rules match ``LabellerClient``:
/// - Fixed endpoint in code (not configurable from preferences)
/// - Every redirect refused
/// - 8 MB reply cap
/// - Key never logged, placed in any record, or included in any error description
/// - Provider message text never kept or logged
/// - Daily request cap counted in the existing ``LabellerRequestCounter`` across all providers together
public struct AnthropicMessagesLabellerSender: LabellerSending, Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let anthropicVersion = "2023-06-01"
    static let userAgent = "wilted-ad-labeller/1"
    public static let defaultTimeLimit: Duration = .seconds(900)
    static let maximumErrorBodyBytes = 65_536
    public static let maximumResponseBytes = 8 * 1_024 * 1_024

    private let keyStore: any LabellerKeyStoring
    private let configuration: URLSessionConfiguration
    private let timeLimit: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        keyStore: any LabellerKeyStoring,
        configuration: URLSessionConfiguration = .ephemeral,
        timeLimit: Duration = defaultTimeLimit,
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

    // MARK: - Thinking level pure mapping

    /// The request's `output_config`: Anthropic takes the thinking level as `effort`
    /// (low, medium, high, xhigh or max), checked against its Python SDK types on 2026-11-21.
    public struct AnthropicOutputConfig: Codable, Equatable, Sendable {
        public let effort: String
        public init(effort: String) { self.effort = effort }
    }

    /// Pure function passing the thinking level to Anthropic's `output_config`. Nil for a blank level.
    public static func outputConfig(for level: String) -> AnthropicOutputConfig? {
        let cleaned = level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty, cleaned != "default" else { return nil }
        return AnthropicOutputConfig(effort: cleaned)
    }

    /// The reply length allowed, in tokens. A labelling answer is short; this leaves room for thinking.
    public static let maxTokens = 16_384

    // MARK: - LabellerSending

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
                try await Self.perform(
                    request,
                    key: key,
                    body: body,
                    timeout: timeout,
                    configuration: configuration,
                    onProgress: onProgress
                )
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

    // MARK: - Failure mapping

    public static func failure(status: Int, headers: [String: String], body: Data, now: Date) -> LabellerFailure {
        switch status {
        case 401, 403:
            return .keyRejected
        case 402:
            return .usageLimit
        case 429:
            let keywords = errorKeywords(in: body)
            if ["budget", "quota", "usage limit", "credit", "balance", "insufficient"].contains(where: keywords.contains) {
                return .usageLimit
            }
            return .rateLimited(retryAfter: retryAfter(headers: headers, now: now))
        case 404:
            return .modelUnavailable
        case 400:
            let keywords = errorKeywords(in: body)
            if ["credit", "balance", "quota", "budget", "billing"].contains(where: keywords.contains) {
                return .usageLimit
            }
            if keywords.contains("model") {
                return .modelUnavailable
            }
            return .temporary
        case 529: // Anthropic overloaded
            return .temporary
        default:
            return .temporary
        }
    }

    public static func failureDetail(status: Int, body: Data) -> LabellerFailureDetail {
        var raw: String?
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let type = error["type"] as? String {
                raw = type
            } else if let type = object["type"] as? String {
                raw = type
            }
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        let cleaned = String((raw ?? "").filter { allowed.contains($0) }.prefix(48))
        return LabellerFailureDetail(status: status, errorType: cleaned.isEmpty ? nil : cleaned)
    }

    // MARK: - Request building

    static func makeURLRequest(
        _ request: LabellerRequest,
        key: String,
        body: Data,
        timeout: TimeInterval
    ) -> URLRequest {
        var urlRequest = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = body
        return urlRequest
    }

    static func makeRequestBody(_ request: LabellerRequest) throws -> Data {
        let body = RequestBody(
            model: request.modelID,
            max_tokens: request.purpose == .providerCheck ? 1 : maxTokens,
            messages: [RequestBody.Message(role: "user", content: request.prompt)],
            output_config: request.purpose == .providerCheck ? nil : outputConfig(for: request.reasoningLevel),
            stream: true
        )
        return try JSONEncoder().encode(body)
    }

    static func timeoutInterval(for limit: Duration) -> TimeInterval {
        let parts = limit.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return max(1, seconds)
    }

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

    private static func perform(
        _ request: LabellerRequest,
        key: String,
        body: Data,
        timeout: TimeInterval,
        configuration: URLSessionConfiguration,
        onProgress: @Sendable (LabellerProgress) -> Void
    ) async throws -> LabellerResponse {
        let stream = AsyncThrowingStream<HTTPEvent, Error>(bufferingPolicy: .unbounded) { continuation in
            let operation = HTTPOperation(continuation: continuation)
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
        var promptTokens: Int?
        var completionTokens: Int?
        var sawDone = false
        var stopReason: String?
        var bytesReceived = 0

        func consume(_ line: String) {
            guard line.hasPrefix("data:") else { return }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = json["type"] as? String else { return }

            switch eventType {
            case "message_start":
                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    if let input = usage["input_tokens"] as? Int { promptTokens = input }
                    if let output = usage["output_tokens"] as? Int { completionTokens = output }
                }
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let deltaText = delta["text"] as? String {
                    text += deltaText
                }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
                if let usage = json["usage"] as? [String: Any],
                   let output = usage["output_tokens"] as? Int {
                    completionTokens = output
                }
            case "message_stop":
                sawDone = true
            default:
                break
            }
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
            onProgress(LabellerProgress(bytesReceived: bytesReceived, answerCharacters: text.count,
                                        failure: Self.failureDetail(status: code, body: body)))
            throw failure(status: code, headers: headers, body: body, now: Date())
        }
        if (contentType ?? "").lowercased().contains("application/json") {
            guard let whole = try? decoder.decode(NonStreamMessage.self, from: body) else {
                throw LabellerFailure.unusableAnswer
            }
            let joinedText = whole.content?.filter { $0.type == "text" }.compactMap { $0.text }.joined() ?? ""
            try request.validateReply(joinedText, reason: whole.stop_reason,
                                      complete: ["end_turn", "stop_sequence"], tokenLimit: "max_tokens")
            let usage = LabellerUsage(promptTokens: whole.usage?.input_tokens, completionTokens: whole.usage?.output_tokens)
            return LabellerResponse(text: joinedText, usage: usage)
        }
        if let remainder = assembler.flush() { consume(remainder) }
        if !sawDone { throw LabellerFailure.temporary }
        try request.validateReply(text, reason: stopReason, complete: ["end_turn", "stop_sequence"], tokenLimit: "max_tokens")
        let usage = LabellerUsage(promptTokens: promptTokens, completionTokens: completionTokens)
        return LabellerResponse(text: text, usage: usage)
    }

    private struct TimeLimitReached: Error {}

    private struct RequestBody: Encodable {
        var model: String
        var max_tokens: Int
        var messages: [Message]
        var output_config: AnthropicOutputConfig?
        var stream: Bool

        struct Message: Encodable { var role: String; var content: String }
    }

    private struct NonStreamMessage: Decodable {
        var content: [ContentBlock]?
        var stop_reason: String?
        var usage: Usage?

        struct ContentBlock: Decodable { var type: String?; var text: String? }
        struct Usage: Decodable { var input_tokens: Int?; var output_tokens: Int? }
    }

    private enum HTTPEvent: Sendable {
        case response(status: Int, headers: [String: String], contentType: String?)
        case data(Data)
    }

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

        mutating func flush() -> String? {
            guard !pending.isEmpty else { return nil }
            var line = pending
            pending.removeAll()
            if line.last == 0x0D { line = line.dropLast() }
            return String(decoding: line, as: UTF8.self)
        }
    }

    private final class HTTPOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncThrowingStream<HTTPEvent, Error>.Continuation
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var terminalError: Error?
        private var completed = false

        init(continuation: AsyncThrowingStream<HTTPEvent, Error>.Continuation) {
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

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            lock.withLock { terminalError = LabellerFailure.temporary }
            completionHandler(nil)
            task.cancel()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
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
}
