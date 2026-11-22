import Foundation

/// Sends one labelling request to an OpenAI-compatible chat completions endpoint (OpenRouter or OpenAI).
///
/// Safety rules match ``LabellerClient``:
/// - Fixed endpoint in code (not configurable from preferences)
/// - Every redirect refused
/// - 8 MB reply cap
/// - Key never logged, placed in any record, or included in any error description
/// - Provider message text never kept or logged
/// - Daily request cap counted in the existing ``LabellerRequestCounter`` across all providers together
public struct OpenAIStyleLabellerSender: LabellerSending, Sendable {
    public enum Target: String, Sendable, CaseIterable {
        case openRouter
        case openAI

        public var endpoint: URL {
            switch self {
            case .openRouter:
                return OpenAIStyleLabellerSender.openRouterEndpoint
            case .openAI:
                return OpenAIStyleLabellerSender.openAIEndpoint
            }
        }

        public var provider: AdLabellerProvider {
            switch self {
            case .openRouter:
                return .openRouterKey
            case .openAI:
                return .openAIKey
            }
        }
    }

    /// Fixed endpoints in code.
    public static let openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    public static let openAIEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let userAgent = "wilted-ad-labeller/1"
    public static let defaultTimeLimit: Duration = .seconds(900)
    static let maximumErrorBodyBytes = 65_536
    public static let maximumResponseBytes = 8 * 1_024 * 1_024

    public let target: Target
    private let keyStore: any LabellerKeyStoring
    private let configuration: URLSessionConfiguration
    private let timeLimit: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        target: Target,
        keyStore: any LabellerKeyStoring,
        configuration: URLSessionConfiguration = .ephemeral,
        timeLimit: Duration = defaultTimeLimit,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.target = target
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

    // MARK: - LabellerSending

    public func send(
        _ request: LabellerRequest,
        onRequestStarted: @escaping @Sendable () -> Void,
        onProgress: @escaping @Sendable (LabellerProgress) -> Void
    ) async throws -> LabellerResponse {
        guard let key = try keyStore.read(), !key.isEmpty else { throw LabellerFailure.keyRejected }
        let body = try Self.makeRequestBody(request, target: target)
        onRequestStarted()
        let configuration = self.configuration
        let timeout = Self.timeoutInterval(for: timeLimit)
        let limit = timeLimit
        let sleeper = sleep
        let target = self.target
        return try await withThrowingTaskGroup(of: LabellerResponse.self) { group in
            group.addTask {
                try await Self.perform(
                    request,
                    target: target,
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

    // MARK: - Thinking level pure mapping functions

    /// Pure function passing thinking level to OpenAI's `reasoning_effort`.
    public static func openAIReasoningEffort(level: String) -> String {
        level
    }

    public struct OpenRouterReasoning: Codable, Equatable, Sendable {
        public let effort: String
        public init(effort: String) {
            self.effort = effort
        }
    }

    /// Pure function passing thinking level to OpenRouter's `reasoning` object with `effort`.
    public static func openRouterReasoning(level: String) -> OpenRouterReasoning {
        OpenRouterReasoning(effort: level)
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
        target: Target,
        key: String,
        body: Data,
        timeout: TimeInterval
    ) -> URLRequest {
        var urlRequest = URLRequest(url: target.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = body
        return urlRequest
    }

    static func makeRequestBody(_ request: LabellerRequest, target: Target) throws -> Data {
        switch target {
        case .openAI:
            let body = OpenAIRequestBody(
                model: request.modelID,
                messages: [OpenAIRequestBody.Message(role: "user", content: request.prompt)],
                reasoning_effort: request.purpose == .providerCheck
                    ? nil
                    : openAIReasoningEffort(level: request.reasoningLevel),
                max_completion_tokens: request.purpose == .providerCheck ? 1 : nil,
                stream: true,
                stream_options: OpenAIRequestBody.StreamOptions(include_usage: true)
            )
            return try JSONEncoder().encode(body)
        case .openRouter:
            let body = OpenRouterRequestBody(
                model: request.modelID,
                messages: [OpenRouterRequestBody.Message(role: "user", content: request.prompt)],
                reasoning: request.purpose == .providerCheck
                    ? nil
                    : openRouterReasoning(level: request.reasoningLevel),
                max_tokens: request.purpose == .providerCheck ? 1 : nil,
                stream: true,
                stream_options: OpenRouterRequestBody.StreamOptions(include_usage: true)
            )
            return try JSONEncoder().encode(body)
        }
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
        target: Target,
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
                            request: makeURLRequest(request, target: target, key: key, body: body, timeout: timeout))
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
                  let chunk = try? decoder.decode(Chunk.self, from: data) else { return }
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
            onProgress(LabellerProgress(bytesReceived: bytesReceived, answerCharacters: text.count,
                                        failure: Self.failureDetail(status: code, body: body)))
            throw failure(status: code, headers: headers, body: body, now: Date())
        }
        if (contentType ?? "").lowercased().contains("application/json") {
            guard let whole = try? decoder.decode(Chunk.self, from: body) else {
                throw LabellerFailure.unusableAnswer
            }
            let content = whole.choices?.first?.message?.content ?? ""
            try request.validateReply(content, reason: whole.choices?.first?.finish_reason,
                                      complete: ["stop"], tokenLimit: "length")
            return LabellerResponse(text: content, usage: whole.usage.map { makeUsage(from: $0) } ?? LabellerUsage())
        }
        if let remainder = assembler.flush() { consume(remainder) }
        if !sawDone { throw LabellerFailure.temporary }
        try request.validateReply(text, reason: finishReason, complete: ["stop"], tokenLimit: "length")
        return LabellerResponse(text: text, usage: reportedUsage ?? LabellerUsage())
    }

    private static func makeUsage(from payload: Chunk.Usage) -> LabellerUsage {
        LabellerUsage(
            promptTokens: payload.prompt_tokens,
            completionTokens: payload.completion_tokens,
            reasoningTokens: payload.completion_tokens_details?.reasoning_tokens)
    }

    private struct TimeLimitReached: Error {}

    private struct OpenAIRequestBody: Encodable {
        var model: String
        var messages: [Message]
        var reasoning_effort: String?
        var max_completion_tokens: Int?
        var stream: Bool
        var stream_options: StreamOptions

        struct Message: Encodable { var role: String; var content: String }
        struct StreamOptions: Encodable { var include_usage: Bool }
    }

    private struct OpenRouterRequestBody: Encodable {
        var model: String
        var messages: [Message]
        var reasoning: OpenRouterReasoning?
        var max_tokens: Int?
        var stream: Bool
        var stream_options: StreamOptions

        struct Message: Encodable { var role: String; var content: String }
        struct StreamOptions: Encodable { var include_usage: Bool }
    }

    private struct Chunk: Decodable {
        var choices: [Choice]?
        var usage: Usage?
        struct Choice: Decodable { var delta: Delta?; var message: Message?; var finish_reason: String? }
        struct Delta: Decodable { var content: String? }
        struct Message: Decodable { var content: String? }
        struct Usage: Decodable {
            var prompt_tokens: Int?
            var completion_tokens: Int?
            var completion_tokens_details: CompletionTokensDetails?
            struct CompletionTokensDetails: Decodable { var reasoning_tokens: Int? }
        }
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
