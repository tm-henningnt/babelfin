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
    func cancel()
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

/// A separate session per request prevents cookies/cache or redirects from moving credentials.
/// The delegate admits at most 240kB (five seconds of PCM), including the current sink callback.
/// Fast synthesis waits for that sink instead of treating ordinary backpressure as overflow.
/// URLSession owns the currently delivered Data; it is sliced into the bounded application queue.
final class URLProviderHTTPTransport: ProviderHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [UUID: HTTPStreamOperation] = [:]
    private let configuration: URLSessionConfiguration?
    init(configuration: URLSessionConfiguration? = nil) { self.configuration = configuration?.copy() as? URLSessionConfiguration }
    func stream(_ request: URLRequest, maximumBytes: Int, contentTypes: Set<String>,
                onChunk: @escaping @Sendable (Data) async throws -> Void) async throws {
        let id = UUID(), operation = HTTPStreamOperation(maximumBytes: maximumBytes, contentTypes: contentTypes, configuration: configuration)
        register(operation, id: id)
        defer { remove(id) }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            operation.start(request)
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

private final class HTTPStreamOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Packet: Sendable { let id: UUID; let data: Data }
    let stream: AsyncThrowingStream<Packet, Error>
    private let continuation: AsyncThrowingStream<Packet, Error>.Continuation
    private let condition = NSCondition()
    private let maximumBytes: Int
    private let contentTypes: Set<String>
    private let configuration: URLSessionConfiguration?
    private var tickets: [UUID: Int] = [:]
    private var queued = 0, received = 0, completedPackets = 0
    private var ended = false
    private var terminalFailure: ProviderNetworkError?
    private var acceptedResponse = false
    private var session: URLSession?
    init(maximumBytes: Int, contentTypes: Set<String>, configuration: URLSessionConfiguration?) {
        self.maximumBytes = maximumBytes; self.contentTypes = contentTypes; self.configuration = configuration
        var captured: AsyncThrowingStream<Packet, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { captured = $0 }
        continuation = captured
    }
    func start(_ request: URLRequest) {
        condition.lock(); defer { condition.unlock() }
        guard !ended else { return }
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }
    func complete(_ packet: Packet) {
        condition.lock()
        if let count = tickets.removeValue(forKey: packet.id) {
            queued -= count; completedPackets += 1
            condition.broadcast()
        }
        condition.unlock()
    }
    func checkFailure() throws {
        condition.lock(); let error = terminalFailure; condition.unlock()
        if let error { throw error }
    }
    func cancel() {
        condition.lock(); terminalFailure = terminalFailure ?? .cancelled; condition.broadcast(); condition.unlock()
        end(ProviderNetworkError.cancelled)
    }
    private func end(_ error: ProviderNetworkError? = nil) {
        condition.lock()
        guard !ended else { condition.unlock(); return }
        ended = true; terminalFailure = error; let oldSession = session; session = nil
        condition.broadcast()
        condition.unlock()
        if let error { continuation.finish(throwing: error); oldSession?.invalidateAndCancel() }
        else { continuation.finish(); oldSession?.finishTasksAndInvalidate() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); end(ProviderNetworkError.invalidResponse)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); end(ProviderNetworkError.invalidResponse); return }
        guard (200...299).contains(http.statusCode) else { completionHandler(.cancel); end(ProviderNetworkError.http(http.statusCode)); return }
        let type = (http.mimeType ?? "").lowercased()
        guard contentTypes.contains(type), response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel); end(ProviderNetworkError.invalidResponse); return
        }
        condition.lock(); acceptedResponse = true; condition.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        guard !ended, acceptedResponse else { condition.unlock(); return }
        guard data.count <= maximumBytes - received else {
            condition.unlock(); end(ProviderNetworkError.overflow); return
        }
        received += data.count
        for offset in stride(from: 0, to: data.count, by: 4_800) {
            let count = min(4_800, data.count - offset)
            var progress = completedPackets
            var deadline = Date(timeIntervalSinceNow: 5)
            let needsCapacity = count > 240_000 - queued || tickets.count >= 64
            if needsCapacity { dataTask.suspend() }
            // This callback runs on this request's dedicated serial delegate queue,
            // never the main actor or the async sink executor. Waiting here prevents
            // more delegate data from being admitted while playback drains. Suspending
            // the task also slows network reads; already-dispatched callbacks still
            // pass this admission gate. Cancel broadcasts independently, so it cannot
            // depend on another delegate event.
            while !ended, count > 240_000 - queued || tickets.count >= 64 {
                let signalled = condition.wait(until: deadline)
                if completedPackets != progress {
                    progress = completedPackets; deadline = Date(timeIntervalSinceNow: 5)
                } else if !signalled, !ended {
                    condition.unlock(); end(ProviderNetworkError.timedOut); return
                }
            }
            guard !ended else { condition.unlock(); return }
            if needsCapacity { dataTask.resume() }
            let bytes = data.subdata(in: offset..<(offset + count))
            let packet = Packet(id: UUID(), data: bytes)
            tickets[packet.id] = bytes.count; queued += bytes.count
            switch continuation.yield(packet) {
            case .enqueued: break
            default: condition.unlock(); end(ProviderNetworkError.overflow); return
            }
        }
        condition.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { end(ProviderNetworkError.transport) }
        else { end() }
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
