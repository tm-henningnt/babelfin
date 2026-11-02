import Foundation
import BridgeCore

/// No provider response body or URL is included in user-facing errors.
enum ProviderNetworkError: LocalizedError, Sendable, TranslationFailureDiagnosing {
    case invalidRequest, invalidResponse, http(Int), transport, overflow, busy, cancelled, timedOut
    var translationFailureReason: TranslationFailureReason {
        switch self {
        case .http(let status): return .httpStatus(status)
        case .invalidRequest: return .invalidRequest
        case .invalidResponse: return .invalidResponse
        case .transport: return .transport
        case .overflow: return .overflow
        case .busy: return .busy
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The provider request is invalid."
        case .invalidResponse: return "The provider returned an unsupported response."
        case .http(let status): return "The provider rejected the request (HTTP \(status)). Check your key, account and voice access."
        case .transport: return "The provider connection failed. Check your network and try again."
        case .overflow: return "The provider stream exceeded its buffer limit. Start a new session."
        case .busy: return "A provider operation is already running."
        case .cancelled: return "The provider operation was cancelled."
        case .timedOut: return "The provider stream stopped making progress."
        }
    }
}

protocol ProviderHTTPTransport: Sendable {
    func stream(_ request: URLRequest, maximumBytes: Int, contentTypes: Set<String>,
                onChunk: @escaping @Sendable (Data) async throws -> Void) async throws
    /// The same, with the request body read from `file` as it is sent.
    func upload(_ request: URLRequest, fromFile file: URL, maximumBytes: Int, contentTypes: Set<String>,
                onChunk: @escaping @Sendable (Data) async throws -> Void) async throws
    func cancel()
}
extension ProviderHTTPTransport {
    /// For transports without file uploads, such as fixtures: the body is read into the request.
    func upload(_ request: URLRequest, fromFile file: URL, maximumBytes: Int, contentTypes: Set<String>,
                onChunk: @escaping @Sendable (Data) async throws -> Void) async throws {
        var request = request
        request.httpBody = try Data(contentsOf: file)
        try await stream(request, maximumBytes: maximumBytes, contentTypes: contentTypes, onChunk: onChunk)
    }
}

private final class HTTPAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ part: Data) { lock.lock(); data.append(part); lock.unlock() }
    func value() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
extension ProviderHTTPTransport {
    func json(_ request: URLRequest, maximumBytes: Int = 1_048_576) async throws -> [String: Any] {
        let body = HTTPAccumulator()
        try await stream(request, maximumBytes: maximumBytes, contentTypes: ["application/json"]) { body.append($0) }
        guard let object = try? JSONSerialization.jsonObject(with: body.value()) as? [String: Any] else { throw ProviderNetworkError.invalidResponse }
        return object
    }
}

/// One URLSession per transport keeps the TLS connections to a provider open between requests.
/// It has no cookie store or cache, and it refuses redirects, so credentials stay with the host
/// they were sent to. Each request admits up to 240 kB (five seconds of PCM) ahead of its sink:
/// above that the task is suspended, and it resumes when the sink has taken half of it. A request
/// whose sink makes no progress for five seconds while suspended fails with a timeout.
final class URLProviderHTTPTransport: ProviderHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [UUID: HTTPStreamOperation] = [:]
    private let router = HTTPSessionRouter()
    private let session: URLSession
    /// `requestTimeout` is the longest wait for data; `resourceTimeout` the longest whole request. Live
    /// translation keeps 20 s and 90 s; a meeting upload waits while the service transcribes.
    init(configuration: URLSessionConfiguration? = nil, requestTimeout: TimeInterval = 20, resourceTimeout: TimeInterval = 90) {
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = requestTimeout; config.timeoutIntervalForResource = resourceTimeout
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: router, delegateQueue: queue)
    }
    deinit { session.invalidateAndCancel() }
    func stream(_ request: URLRequest, maximumBytes: Int, contentTypes: Set<String>,
                onChunk: @escaping @Sendable (Data) async throws -> Void) async throws {
        try await run(request, maximumBytes: maximumBytes, contentTypes: contentTypes, onChunk: onChunk) { $0.dataTask(with: request) }
    }
    func upload(_ request: URLRequest, fromFile file: URL, maximumBytes: Int, contentTypes: Set<String>,
                onChunk: @escaping @Sendable (Data) async throws -> Void) async throws {
        try await run(request, maximumBytes: maximumBytes, contentTypes: contentTypes, onChunk: onChunk) { $0.uploadTask(with: request, fromFile: file) }
    }
    /// Requests that fail, and requests that take more than `slowSeconds`, go to the diagnostic log:
    /// method, host, duration and error kind. The path, query, headers and bodies are not logged.
    static let slowSeconds: TimeInterval = 10
    private func run(_ request: URLRequest, maximumBytes: Int, contentTypes: Set<String>, onChunk: @escaping @Sendable (Data) async throws -> Void,
                     task: @escaping @Sendable (URLSession) -> URLSessionDataTask) async throws {
        let id = UUID(), operation = HTTPStreamOperation(maximumBytes: maximumBytes, contentTypes: contentTypes)
        register(operation, id: id)
        defer { remove(id) }
        let started = ProcessInfo.processInfo.systemUptime
        let name = "\(request.httpMethod ?? "GET") \(request.url?.host ?? "unknown host")"
        do {
            try await perform(operation, onChunk: onChunk, task: task)
            if ProcessInfo.processInfo.systemUptime - started > Self.slowSeconds { DiagnosticLog.shared.write("http", "\(name) answered after \(DiagnosticLog.elapsed(since: started))") }
        } catch {
            let cancelled: Bool
            if case .cancelled? = error as? ProviderNetworkError { cancelled = true } else { cancelled = error is CancellationError }
            if !cancelled {
                let code = operation.urlErrorCode.map { " (URLError \($0))" } ?? ""
                DiagnosticLog.shared.write("http", "\(name) failed after \(DiagnosticLog.elapsed(since: started)): \(error)\(code)")
            }
            throw error
        }
    }
    private func perform(_ operation: HTTPStreamOperation, onChunk: @escaping @Sendable (Data) async throws -> Void,
                         task: @escaping @Sendable (URLSession) -> URLSessionDataTask) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            operation.start(task(session), router: router)
            do {
                for try await packet in operation.stream {
                    try Task.checkCancellation()
                    try operation.checkFailure()
                    try await onChunk(packet.data)
                    operation.complete(packet)
                }
                try Task.checkCancellation()
                try operation.checkFailure()
            } catch {
                operation.cancel()
                if Task.isCancelled { throw CancellationError() }
                if let safe = error as? ProviderNetworkError { throw safe }
                if error is CancellationError { throw error }
                throw ProviderNetworkError.transport
            }
        } onCancel: { operation.cancel() }
    }
    private func register(_ operation: HTTPStreamOperation, id: UUID) { lock.lock(); operations[id] = operation; lock.unlock() }
    private func remove(_ id: UUID) { lock.lock(); operations.removeValue(forKey: id); lock.unlock() }
    func cancel() { lock.lock(); let active = Array(operations.values); lock.unlock(); active.forEach { $0.cancel() } }
}

/// The session's delegate: hands each task's events to the operation that started it.
private final class HTTPSessionRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [Int: HTTPStreamOperation] = [:]
    func register(_ operation: HTTPStreamOperation, for task: URLSessionTask) { lock.withLock { operations[task.taskIdentifier] = operation } }
    private func operation(_ task: URLSessionTask) -> HTTPStreamOperation? { lock.withLock { operations[task.taskIdentifier] } }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); operation(task)?.refuseRedirect()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let operation = operation(dataTask) else { completionHandler(.cancel); return }
        completionHandler(operation.accept(response) ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        operation(dataTask)?.receive(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finished = lock.withLock { operations.removeValue(forKey: task.taskIdentifier) }
        finished?.completed(error: error)
    }
}

private final class HTTPStreamOperation: @unchecked Sendable {
    struct Packet: Sendable { let id: UUID; let data: Data }
    static let admittedBytes = 240_000
    static let stallSeconds: TimeInterval = 5
    let stream: AsyncThrowingStream<Packet, Error>
    private let continuation: AsyncThrowingStream<Packet, Error>.Continuation
    private let lock = NSLock()
    private let maximumBytes: Int
    private let contentTypes: Set<String>
    private var tickets: [UUID: Int] = [:]
    private var queued = 0, received = 0, completedPackets = 0
    private var ended = false
    private var terminalFailure: ProviderNetworkError?
    private var acceptedResponse = false
    private var task: URLSessionDataTask?
    private var suspended = false
    private var watch: DispatchSourceTimer?
    init(maximumBytes: Int, contentTypes: Set<String>) {
        self.maximumBytes = maximumBytes; self.contentTypes = contentTypes
        // Bounded by `maximumBytes`: every byte the delegate receives is admitted once.
        (stream, continuation) = AsyncThrowingStream.makeStream(of: Packet.self, bufferingPolicy: .unbounded)
    }
    func start(_ task: URLSessionDataTask, router: HTTPSessionRouter) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { task.cancel(); return }
        self.task = task
        router.register(self, for: task)
        task.resume()
    }
    /// The sink took a packet: frees its bytes and resumes a suspended task below half the limit.
    func complete(_ packet: Packet) {
        lock.lock()
        guard let count = tickets.removeValue(forKey: packet.id) else { lock.unlock(); return }
        queued -= count; completedPackets += 1
        let drained = queued <= Self.admittedBytes / 2
        if drained { watch?.cancel(); watch = nil }
        let resume = suspended && !ended && drained
        if resume { suspended = false }
        let task = self.task
        lock.unlock()
        if resume { task?.resume() }
    }
    func checkFailure() throws {
        lock.lock(); let error = terminalFailure; lock.unlock()
        if let error { throw error }
    }
    func cancel() {
        lock.lock(); terminalFailure = terminalFailure ?? .cancelled; lock.unlock()
        end(ProviderNetworkError.cancelled)
    }
    func refuseRedirect() { end(ProviderNetworkError.invalidResponse) }
    func accept(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { end(ProviderNetworkError.invalidResponse); return false }
        guard (200...299).contains(http.statusCode) else { end(ProviderNetworkError.http(http.statusCode)); return false }
        let type = (http.mimeType ?? "").lowercased()
        guard contentTypes.contains(type), response.expectedContentLength <= Int64(maximumBytes) else {
            end(ProviderNetworkError.invalidResponse); return false
        }
        lock.withLock { acceptedResponse = true }
        return true
    }
    /// Runs on the session's serial delegate queue and never waits: a slow sink suspends the task.
    func receive(_ data: Data) {
        lock.lock()
        guard !ended, acceptedResponse else { lock.unlock(); return }
        guard data.count <= maximumBytes - received else { lock.unlock(); end(ProviderNetworkError.overflow); return }
        received += data.count
        for offset in stride(from: 0, to: data.count, by: 4_800) {
            let bytes = data.subdata(in: offset..<min(offset + 4_800, data.count))
            let packet = Packet(id: UUID(), data: bytes)
            tickets[packet.id] = bytes.count; queued += bytes.count
            continuation.yield(packet)
        }
        if queued > Self.admittedBytes, watch == nil { armWatch(progress: completedPackets) }
        let suspend = !suspended && queued > Self.admittedBytes
        if suspend { suspended = true }
        let task = self.task
        lock.unlock()
        if suspend { task?.suspend() }
    }
    /// While more than the admitted bytes wait, fails the request if the sink takes no packet within
    /// `stallSeconds`, also when the network part of the response has already ended.
    private func armWatch(progress: Int) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + Self.stallSeconds, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.queued > Self.admittedBytes / 2, self.terminalFailure == nil else { self.watch = nil; self.lock.unlock(); return }
            if self.completedPackets != progress { let now = self.completedPackets; self.armWatch(progress: now); self.lock.unlock(); return }
            self.terminalFailure = .timedOut; self.watch = nil
            self.lock.unlock()
            self.end(ProviderNetworkError.timedOut)
        }
        watch?.cancel()
        watch = timer
        timer.resume()
    }
    /// The URLError code of a failed request, for the diagnostic log.
    var urlErrorCode: Int? { lock.withLock { failureCode } }
    private var failureCode: Int?
    /// A URLSession timeout is reported as a timeout, so the message does not point at the network.
    func completed(error: Error?) {
        if let error = error as? URLError { lock.withLock { failureCode = error.code.rawValue } }
        switch error {
        case nil: end()
        case let error as URLError where error.code == .timedOut: end(ProviderNetworkError.timedOut)
        default: end(ProviderNetworkError.transport)
        }
    }
    private func end(_ error: ProviderNetworkError? = nil) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true; terminalFailure = terminalFailure ?? error
        if error != nil { watch?.cancel(); watch = nil }
        let task = self.task; self.task = nil
        lock.unlock()
        if let error { continuation.finish(throwing: error); task?.cancel() } else { continuation.finish() }
    }
}

func providerJSONRequest(_ url: URL, body: [String: Any], header: String, credential: String) throws -> URLRequest {
    var request = URLRequest(url: url); request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(credential, forHTTPHeaderField: header)
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
}
func validateProviderToken(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 128,
          value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
        throw ProviderNetworkError.invalidRequest
    }
}

/// HTTP chunk boundaries need not coincide with PCM sample boundaries.
actor ProviderPCMFramer {
    private var pending = Data()
    private var started = false
    private var produced = false
    func consume(_ bytes: Data, sink: TranslationAudioHandler) async throws {
        pending.append(bytes)
        if !started {
            guard pending.count >= 4 else { return }
            let prefix = String(data: pending.prefix(4), encoding: .ascii)
            guard prefix != "RIFF", prefix != "OggS", prefix != "fLaC", !pending.starts(with: [0x49,0x44,0x33]) else { throw ProviderNetworkError.invalidResponse }
            started = true
        }
        while pending.count >= 2 {
            let count = min(4_800, pending.count - pending.count % 2)
            let chunk = Data(pending.prefix(count)); pending.removeFirst(count)
            try Task.checkCancellation(); try await sink(chunk); produced = true
        }
    }
    func finish(sink: TranslationAudioHandler) async throws {
        if !started, pending.count == 2 { try await sink(pending); pending.removeAll(); produced = true }
        guard pending.isEmpty, produced else { throw ProviderNetworkError.invalidResponse }
    }
}
