import Foundation
import BridgeCore

/// Ends a long recognition segment at a short pause. Continuous speech then gives segments of
/// about 4–8 s instead of waiting for the service's 0.5 s silence commit, which keeps the
/// composed route close to the speaker. Input is 24 kHz mono PCM16.
struct SegmentCutter: Sendable {
    var minimumSeconds = 4.0
    var maximumSeconds = 8.0
    var pauseSeconds = 0.15
    var serviceCommitSeconds = 0.45
    /// Commit at the end of speech too. For a service without its own turn detection.
    var commitsOnSilence = false
    // Whole sample counts at 24 kHz, so repeated packets add up exactly.
    private var segmentSamples = 0, quietSamples = 0
    private var speechLevel: Double = 0
    /// True when this packet should end the current segment.
    mutating func commitAfter(_ pcm: Data) -> Bool {
        let count = pcm.count / 2
        guard count > 0 else { return false }
        let rms = pcm.withUnsafeBytes { raw -> Double in
            var sum = 0.0
            for i in 0..<count { let v = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32_768; sum += v * v }
            return (sum / Double(count)).squareRoot()
        }
        if rms > max(0.003, speechLevel * 0.2) {
            speechLevel = speechLevel == 0 ? rms : speechLevel * 0.95 + rms * 0.05
            quietSamples = 0; segmentSamples += count
        } else {
            quietSamples += count
            if segmentSamples > 0 { segmentSamples += count }
        }
        func samples(_ seconds: Double) -> Int { Int((seconds * 24_000).rounded()) }
        // After `serviceCommitSeconds` of silence the speech ends. Scribe commits by itself;
        // with `commitsOnSilence` the caller commits.
        if quietSamples >= samples(serviceCommitSeconds) {
            defer { segmentSamples = 0 }
            return commitsOnSilence && segmentSamples > 0
        }
        guard segmentSamples >= samples(maximumSeconds) || (segmentSamples >= samples(minimumSeconds) && quietSamples >= samples(pauseSeconds)) else { return false }
        segmentSamples = 0
        return true
    }
}

protocol ProviderWebSocket: Sendable {
    func send(_ text: String) async throws
    /// Sends one binary frame, for services such as Fish Audio that accept only binary messages.
    func send(data: Data) async throws
    func receive() async throws -> Data
    func cancel()
}
extension ProviderWebSocket {
    func send(data: Data) async throws { throw SocketTransportError.connectionFailed }
}
final class URLProviderWebSocket: ProviderWebSocket, @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config, delegate: SocketRedirectPolicy(), delegateQueue: nil)
        socket = session.webSocketTask(with: request); socket.maximumMessageSize = 65_536; socket.resume()
    }
    #if BABELFIN_TRANSPORT_CHECKS
    var messageLimitForChecks: Int { socket.maximumMessageSize }
    #endif
    func send(_ text: String) async throws {
        do { try await socket.send(.string(text)) }
        catch { throw SocketTransportError.connectionFailed }
    }
    func send(data: Data) async throws {
        do { try await socket.send(.data(data)) }
        catch { throw SocketTransportError.connectionFailed }
    }
    func receive() async throws -> Data {
        do {
            switch try await socket.receive() {
            case .data(let data): return data
            case .string(let text): return Data(text.utf8)
            @unknown default: throw SocketTransportError.connectionFailed
            }
        } catch { throw SocketTransportError.connectionFailed }
    }
    func cancel() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}

/// The Delay shared between the main actor and the upload task.
final class LivePacing: @unchecked Sendable {
    private let lock = NSLock()
    private var value = TranslationPacing.balanced
    func set(_ pacing: TranslationPacing) { lock.lock(); value = pacing; lock.unlock() }
    func get() -> TranslationPacing { lock.lock(); defer { lock.unlock() }; return value }
}

final class RecognitionMailbox: @unchecked Sendable {
    struct Entry: Sendable { let id: UUID; let data: Data }
    let stream: AsyncThrowingStream<Entry, Error>
    private let continuation: AsyncThrowingStream<Entry, Error>.Continuation
    private let lock = NSLock()
    private var entries: [UUID: Int] = [:]
    private var bytes = 0, closed = false
    init() {
        var captured: AsyncThrowingStream<Entry, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { captured = $0 }; continuation = captured
    }
    func append(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, data.count <= 65_536 - bytes, entries.count < 64 else { throw ProviderNetworkError.overflow }
        let entry = Entry(id: UUID(), data: data); entries[entry.id] = data.count; bytes += data.count
        switch continuation.yield(entry) { case .enqueued: break; default: throw ProviderNetworkError.overflow }
    }
    func complete(_ entry: Entry) { lock.lock(); if let count = entries.removeValue(forKey: entry.id) { bytes -= count }; lock.unlock() }
    func finish(_ error: Error? = nil) { lock.lock(); closed = true; lock.unlock(); continuation.finish(throwing: error) }
}


/// The socket, audio upload and tasks that every streaming recognizer runs. The recognizer
/// supplies the handshake, the audio frames, the transcript parser and the final settle step.
/// A failure cancels the session once and is reported once.
@MainActor final class RecognitionSocketSession {
    nonisolated let upload = BoundedPCMChannel()
    private let mailbox = RecognitionMailbox()
    /// The Delay the sender reads for each packet. A pause the service fixes at connect stays.
    private let livePacing = LivePacing()
    private var socket: (any ProviderWebSocket)?
    private var sender: Task<Void, Never>?, reader: Task<Void, Never>?, consumer: Task<Void, Never>?, watchdog: Task<Void, Never>?
    private(set) var generation = UUID(), active = false, closing = false
    private(set) var failure: String?
    private var used = false
    private var report: (@MainActor (String) async -> Void)?

    /// A session runs once.
    func claim() throws {
        guard !used else { throw BridgeError.unavailable("Create a new recognition session before starting again.") }
        used = true
    }

    /// Runs `handshake` on the new socket. The socket closes if the service does not confirm the session within 15 s.
    func open(_ socket: any ProviderWebSocket, startFailure: String, handshake: (any ProviderWebSocket) async throws -> Void) async throws {
        self.socket = socket
        let timeout = Task.detached { try? await Task.sleep(nanoseconds: 15_000_000_000); if !Task.isCancelled { socket.cancel() } }
        defer { timeout.cancel() }
        do { try await handshake(socket) } catch { cancel(); throw BridgeError.unavailable(startFailure) }
    }

    /// Receives one handshake message. A cancelled start closes the socket.
    func receiveDuringStart() async throws -> Data {
        guard let socket else { throw ProviderNetworkError.transport }
        let token = generation
        let data = try await withTaskCancellationHandler { try await socket.receive() } onCancel: { socket.cancel() }
        guard token == generation, !Task.isCancelled else { throw ProviderNetworkError.invalidResponse }
        return data
    }

    /// Starts the upload and the transcript reader.
    /// - `send` sends one packet; `commit` is true when the packet ends a passage.
    /// - `consume` parses one service message.
    /// - `closeExpected` is true when the service may close the socket without a failure.
    /// - `report` receives the failure message.
    func run(pacing: TranslationPacing, commitsOnSilence: Bool,
             send: @escaping @Sendable (any ProviderWebSocket, Data, Bool) async throws -> Void,
             consume: @escaping @MainActor (Data, UUID) async throws -> Void,
             closeExpected: @escaping @MainActor () -> Bool = { false },
             report: @escaping @MainActor (String) async -> Void) {
        guard let socket else { return }
        self.report = report
        active = true; upload.open()
        let upload = self.upload, mailbox = self.mailbox, token = generation, livePacing = self.livePacing
        livePacing.set(pacing)
        sender = Task.detached { [weak self] in
            var cutter = SegmentCutter(minimumSeconds: pacing.minimumSegmentSeconds, maximumSeconds: pacing.maximumSegmentSeconds,
                                       serviceCommitSeconds: pacing.commitSilenceSeconds, commitsOnSilence: commitsOnSilence)
            do {
                for await packet in upload.stream {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime - packet.admittedAt <= 5 else { throw ProviderNetworkError.overflow }
                    let current = livePacing.get()
                    cutter.minimumSeconds = current.minimumSegmentSeconds; cutter.maximumSeconds = current.maximumSegmentSeconds
                    try await send(socket, packet.pcm, cutter.commitAfter(packet.pcm))
                    upload.complete(packet)
                }
            } catch { guard !Task.isCancelled else { return }; socket.cancel(); await self?.fail("Speech recognition upload failed.", token: token) }
        }
        reader = Task.detached {
            do {
                while !Task.isCancelled {
                    let data = try await socket.receive()
                    guard data.count <= 65_536 else { throw ProviderNetworkError.overflow }
                    try mailbox.append(data)
                }
            } catch {
                guard !Task.isCancelled else { return }
                socket.cancel(); mailbox.finish(ProviderNetworkError.transport)
            }
        }
        // The consumer handles the messages that arrived before a close, then reports the close.
        consumer = Task { [weak self] in
            do {
                for try await entry in mailbox.stream {
                    try Task.checkCancellation()
                    guard token == self?.generation else { return }
                    try await consume(entry.data, token)
                    mailbox.complete(entry)
                }
            } catch ProviderNetworkError.transport {
                guard !Task.isCancelled, !closeExpected() else { return }
                await self?.fail("Speech recognition connection failed.", token: token)
            } catch { guard !Task.isCancelled else { return }; await self?.fail("Speech recognition returned an invalid response.", token: token) }
        }
        watchdog = Task.detached { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                if upload.snapshot().oldestAge > 5 { socket.cancel(); await self?.fail("Speech recognition upload stalled.", token: token); return }
            }
        }
    }

    func stopInput() { upload.cancel(); sender?.cancel() }
    func updatePacing(_ pacing: TranslationPacing) { livePacing.set(pacing) }

    /// Ends the upload, sends the remaining audio and runs `settle` to confirm the last transcript.
    /// The socket closes if this takes longer than `timeout` + 1 s.
    /// Returns false when the session was not running.
    func finish(timeout: TimeInterval, settle: (any ProviderWebSocket) async throws -> Void) async throws -> Bool {
        guard active, !closing else { try throwFailure(); return false }
        closing = true; upload.finish()
        let socketForDeadline = socket, closeTimeout = timeout + 1
        let deadlineTask = Task.detached {
            do { try await Task.sleep(nanoseconds: UInt64(closeTimeout * 1_000_000_000)) } catch { return }
            socketForDeadline?.cancel()
        }
        defer { deadlineTask.cancel(); cancel() }
        await sender?.value
        try Task.checkCancellation()
        try throwFailure()
        if let socket { try await settle(socket); try throwFailure() }
        cancel()
        return true
    }

    /// Sends the final message of a passage while finishing. A send error ends the session.
    func sendFinal(_ send: () async throws -> Void) async throws {
        do { try await send() } catch { cancel(); throw ProviderNetworkError.transport }
    }

    /// Waits until `settled` is true, the session fails or `timeout` passes.
    func wait(until settled: () -> Bool, timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while failure == nil, active, !settled(), ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try throwFailure()
    }

    func cancel() {
        generation = UUID(); active = false
        upload.cancel(); mailbox.finish()
        sender?.cancel(); reader?.cancel(); consumer?.cancel(); watchdog?.cancel()
        socket?.cancel(); socket = nil
    }

    func fail(_ message: String, token: UUID) async {
        guard token == generation, failure == nil else { return }
        failure = message; cancel(); await report?(message)
    }

    private func throwFailure() throws { if let failure { throw BridgeError.unavailable(failure) } }
}
