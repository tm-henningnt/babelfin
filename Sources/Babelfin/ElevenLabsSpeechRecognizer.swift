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
        // The service commits by itself after `serviceCommitSeconds` of silence.
        if quietSamples >= samples(serviceCommitSeconds) { segmentSamples = 0; return false }
        guard segmentSamples >= samples(maximumSeconds) || (segmentSamples >= samples(minimumSeconds) && quietSamples >= samples(pauseSeconds)) else { return false }
        segmentSamples = 0
        return true
    }
}

protocol ProviderWebSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> Data
    func cancel()
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

private /// The Delay shared between the main actor and the upload task.
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

@MainActor final class ElevenLabsSpeechRecognizer: StreamingSpeechRecognizer {
    var onEvent: RecognitionEventHandler?
    private let makeSocket: @Sendable (URLRequest) -> any ProviderWebSocket
    nonisolated private let upload = BoundedPCMChannel()
    private let mailbox = RecognitionMailbox()
    private var socket: (any ProviderWebSocket)?
    private var sender: Task<Void, Never>?, reader: Task<Void, Never>?, consumer: Task<Void, Never>?, watchdog: Task<Void, Never>?
    private var generation = UUID(), used = false, active = false, closing = false
    private var failure: String?
    private var segmentID = UUID().uuidString, revision = 0, commits = 0
    private var sourceLanguage: String?
    /// The Delay the sender reads for each packet. Scribe's end-of-speech pause stays as connected.
    nonisolated private let livePacing = LivePacing()
    private var unresolvedPartial = false, emptyCommitAcknowledged = false
    private var lastTranscriptAt: TimeInterval = 0
    private let finishTimeout: TimeInterval
    init(finishTimeout: TimeInterval = 5, transportFactory: @escaping @Sendable (URLRequest) -> any ProviderWebSocket = { URLProviderWebSocket(request: $0) }) {
        self.finishTimeout = finishTimeout; makeSocket = transportFactory
    }
    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        guard !used else { throw BridgeError.unavailable("Create a new recognition session before starting again.") }
        used = true; sourceLanguage = configuration.sourceLanguage; livePacing.set(configuration.pacing)
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        components.queryItems = [.init(name: "model_id", value: "scribe_v2_realtime"), .init(name: "audio_format", value: "pcm_24000"),
                                 .init(name: "commit_strategy", value: "vad"), .init(name: "vad_silence_threshold_secs", value: String(configuration.pacing.commitSilenceSeconds))]
        if let sourceLanguage { try validateProviderToken(sourceLanguage); components.queryItems?.append(.init(name: "language_code", value: sourceLanguage)) }
        var request = URLRequest(url: components.url!); request.timeoutInterval = 20
        request.setValue(try credentials.require(.elevenLabs), forHTTPHeaderField: "xi-api-key")
        let socket = makeSocket(request), token = generation; self.socket = socket
        let timeout = Task.detached { try? await Task.sleep(nanoseconds: 15_000_000_000); if !Task.isCancelled { socket.cancel() } }
        defer { timeout.cancel() }
        do {
            let data = try await withTaskCancellationHandler { try await socket.receive() } onCancel: { socket.cancel() }
            let hello = try Self.message(data)
            guard token == generation, !Task.isCancelled, hello["message_type"] as? String == "session_started",
                  let sessionID = hello["session_id"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 256,
                  let config = hello["config"] as? [String: Any] else { throw ProviderNetworkError.invalidResponse }
            if let rate = config["sample_rate"] as? Int, rate != 24_000 { throw ProviderNetworkError.invalidResponse }
            if let format = config["audio_format"] as? String, format != "pcm_24000" { throw ProviderNetworkError.invalidResponse }
            if let model = config["model_id"] as? String, model != "scribe_v2_realtime" { throw ProviderNetworkError.invalidResponse }
        } catch { cancel(); throw BridgeError.unavailable("Could not start ElevenLabs recognition. Check your key, account access and network.") }
        active = true; upload.open()
        let upload = self.upload, mailbox = self.mailbox, pacing = configuration.pacing, livePacing = self.livePacing
        sender = Task.detached { [weak self] in
            var cutter = SegmentCutter(minimumSeconds: pacing.minimumSegmentSeconds, maximumSeconds: pacing.maximumSegmentSeconds,
                                       serviceCommitSeconds: pacing.commitSilenceSeconds)
            do {
                for await packet in upload.stream {
                    let current = livePacing.get()
                    cutter.minimumSeconds = current.minimumSegmentSeconds; cutter.maximumSeconds = current.maximumSegmentSeconds
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime - packet.admittedAt <= 5 else { throw ProviderNetworkError.overflow }
                    try await socket.send(Self.audioMessage(packet.pcm, commit: cutter.commitAfter(packet.pcm)))
                    upload.complete(packet)
                }
            } catch { guard !Task.isCancelled else { return }; socket.cancel(); await self?.fail("Speech recognition upload failed.", token: token) }
        }
        reader = Task.detached { [weak self] in
            do {
                while !Task.isCancelled {
                    let data = try await socket.receive()
                    guard data.count <= 65_536 else { throw ProviderNetworkError.overflow }
                    try mailbox.append(data)
                }
            } catch {
                guard !Task.isCancelled else { return }
                socket.cancel(); mailbox.finish(ProviderNetworkError.transport)
                await self?.fail("Speech recognition connection failed.", token: token)
            }
        }
        consumer = Task { [weak self] in
            do {
                for try await entry in mailbox.stream {
                    try Task.checkCancellation()
                    try await self?.consume(entry.data, token: token)
                    mailbox.complete(entry)
                }
            } catch { guard !Task.isCancelled else { return }; await self?.fail("Speech recognition returned an invalid response.", token: token) }
        }
        watchdog = Task.detached { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                if upload.snapshot().oldestAge > 5 { socket.cancel(); await self?.fail("Speech recognition upload stalled.", token: token); return }
            }
        }
    }
    nonisolated func append(_ pcm: Data) throws { try upload.append(pcm) }
    func updatePacing(_ pacing: TranslationPacing) { livePacing.set(pacing) }
    func stopInput() {
        upload.cancel()
        sender?.cancel()
    }
    func finish() async throws {
        guard active, !closing else { if let failure { throw BridgeError.unavailable(failure) }; return }
        closing = true; upload.finish()
        let socketForDeadline = socket, closeTimeout = finishTimeout + 1
        let deadlineTask = Task.detached {
            do { try await Task.sleep(nanoseconds: UInt64(closeTimeout * 1_000_000_000)) } catch { return }
            socketForDeadline?.cancel()
        }
        defer { deadlineTask.cancel(); cancel() }
        await sender?.value
        try Task.checkCancellation()
        if let failure { throw BridgeError.unavailable(failure) }
        if upload.snapshot().completedFrames > 0, let socket {
            let before = commits
            do { try await socket.send(Self.audioMessage(Data(), commit: true)) }
            catch { cancel(); throw ProviderNetworkError.transport }
            let deadline = ProcessInfo.processInfo.systemUptime + finishTimeout
            while failure == nil, active, ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                // Scribe has no commit identifier/close ACK. Allow queued automatic commits
                // and a trailing partial to drain before treating a new final as settled.
                if !unresolvedPartial, emptyCommitAcknowledged || (commits > before && ProcessInfo.processInfo.systemUptime - lastTranscriptAt >= min(0.25, finishTimeout / 2)) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if let failure { throw BridgeError.unavailable(failure) }
            guard !unresolvedPartial, commits > 0 || emptyCommitAcknowledged else {
                throw BridgeError.unavailable("The final recognition transcript was not confirmed before the session closed.")
            }
        }
        cancel(); await onEvent?(.closed)
    }
    func cancel() {
        generation = UUID(); active = false
        upload.cancel(); mailbox.finish()
        sender?.cancel(); reader?.cancel(); consumer?.cancel(); watchdog?.cancel()
        socket?.cancel(); socket = nil
    }
    private func fail(_ message: String, token: UUID) async {
        guard token == generation, failure == nil else { return }
        failure = message; cancel(); await onEvent?(.failure(message))
    }
    private func consume(_ data: Data, token: UUID) async throws {
        guard token == generation else { return }
        let object = try Self.message(data)
        guard let type = object["message_type"] as? String else { throw ProviderNetworkError.invalidResponse }
        switch type {
        case "partial_transcript", "committed_transcript":
            guard let text = object["text"] as? String, text.utf8.count <= 32_000 else { throw ProviderNetworkError.invalidResponse }
            revision += 1
            lastTranscriptAt = ProcessInfo.processInfo.systemUptime
            let final = type == "committed_transcript"
            unresolvedPartial = !final && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let segment = TranscriptSegment(id: segmentID, revision: revision, text: text, isFinal: final, language: sourceLanguage)
            // Increment only after the final callback drains: finish must not outrun the transcript consumer.
            await onEvent?(.segment(segment))
            if final { commits += 1; segmentID = UUID().uuidString; revision = 0 }
        case "insufficient_audio_activity":
            // A commit found no new speech. While closing, that settles the final transcript.
            if closing && !unresolvedPartial { emptyCommitAcknowledged = true }
        case "session_started", "committed_transcript_with_timestamps", "warning": break // No untrusted warning text is logged.
        case "error", "auth_error", "quota_exceeded", "throttled", "unaccepted_terms", "rate_limited", "queue_overflow", "resource_exhausted", "session_time_limit_exceeded", "input_error", "invalid_request", "chunk_size_exceeded", "transcriber_error":
            await fail("ElevenLabs could not continue recognition. Check account access and usage limits.", token: token)
        default: break // Forward-compatible controls cannot create transcript/audio events.
        }
    }
    nonisolated private static func message(_ data: Data) throws -> [String: Any] {
        guard data.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderNetworkError.invalidResponse }
        return object
    }
    nonisolated private static func audioMessage(_ data: Data, commit: Bool = false) throws -> String {
        let object: [String: Any] = ["message_type": "input_audio_chunk", "audio_base_64": data.base64EncodedString(), "sample_rate": 24_000, "commit": commit]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
