import Foundation
import BridgeCore

protocol TranslationWebSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> Data
    func cancel()
}

final class URLTranslationWebSocket: TranslationWebSocket, @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    convenience init(apiKey: String) {
        var request = URLRequest(url: TranslationWire.endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        self.init(request: request)
    }
    #if BABELFIN_TRANSPORT_CHECKS
    convenience init(testURL: URL) {
        var request = URLRequest(url: testURL)
        request.setValue("Bearer synthetic-fixture", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        self.init(request: request)
    }
    var messageLimitForChecks: Int { socket.maximumMessageSize }
    #endif
    init(request: URLRequest) {
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        session = URLSession(configuration: settings, delegate: SocketRedirectPolicy(), delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 400_000
        socket.resume()
    }
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

/// Only numeric metadata crosses from receive to UI. No task is created per audio event.
private final class ReceivedTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var lastArrival: TimeInterval?
    private var maximumGap: TimeInterval = 0
    private var elapsed: Int?
    func record(frames count: Int, elapsed: Int?, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        frames += count
        if let lastArrival { maximumGap = max(maximumGap, now - lastArrival) }
        lastArrival = now
        if let elapsed { self.elapsed = elapsed }
    }
    func snapshot() -> (frames: Int, maximumGap: TimeInterval, elapsed: Int?) {
        lock.lock(); defer { lock.unlock() }
        return (frames, maximumGap, elapsed)
    }
}

private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: TranslationAudioHandler?
    func set(_ value: TranslationAudioHandler?) { lock.lock(); handler = value; lock.unlock() }
    func get() -> TranslationAudioHandler? { lock.lock(); defer { lock.unlock() }; return handler }
}

/// One direct speech-to-speech service's message format. A wire belongs to one session; it may
/// keep state, such as a resampler.
protocol RealtimeTranslationWire: AnyObject, Sendable {
    var service: ProviderService { get }
    func request(credential: String) -> URLRequest
    /// Messages sent right after the connection opens.
    func opening(_ configuration: TranslationConfiguration) throws -> [String]
    /// The message sent when the server reports `.created`; nil when the opening messages configure the session.
    func update(_ configuration: TranslationConfiguration) throws -> String?
    /// The session is ready only after `.created` and then `.updated`.
    var waitsForCreated: Bool { get }
    func decode(_ data: Data) throws -> [TranslationEnvelope]
    func append(_ pcm: Data) throws -> String
    /// The message that ends input gracefully, if the service has one.
    var closing: String? { get }
    /// The server answers the closing message with `.closed`.
    var confirmsClose: Bool { get }
}

final class OpenAIRealtimeWire: RealtimeTranslationWire, @unchecked Sendable {
    let service = ProviderService.openAI
    func request(credential: String) -> URLRequest {
        var request = URLRequest(url: TranslationWire.endpoint)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }
    func opening(_ configuration: TranslationConfiguration) throws -> [String] { [] }
    func update(_ configuration: TranslationConfiguration) throws -> String? { try TranslationWire.update(configuration) }
    let waitsForCreated = true
    func decode(_ data: Data) throws -> [TranslationEnvelope] { [try TranslationWire.decodeEnvelope(data)] }
    func append(_ pcm: Data) throws -> String { try TranslationWire.append(pcm) }
    let closing: String? = "{\"type\":\"session.close\"}"
    let confirmsClose = true
}

typealias OpenAITranslationProvider = RealtimeTranslationProvider

/// A direct speech-to-speech session over one WebSocket. The wire supplies the service's format;
/// upload bounds, failure classes, health checks and shutdown are shared.
@MainActor final class RealtimeTranslationProvider: TranslationProvider {
    var onEvent: TranslationEventHandler?
    var onAudio: TranslationAudioHandler? { didSet { audioSink.set(onAudio) } }
    nonisolated private let audioSink = AudioSink()
    private let wire: any RealtimeTranslationWire
    private let makeSocket: @Sendable (String) -> any TranslationWebSocket
    private let now: @Sendable () -> TimeInterval
    private var socket: (any TranslationWebSocket)?
    private var reader: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var audioConsumer: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var controlConsumer: Task<Void, Never>?
    nonisolated private let controls = TranslationControlChannel()
    nonisolated private let upload = BoundedPCMChannel()
    // Separate from the two-second render budget; includes the entire in-flight event.
    nonisolated private let received = BoundedPCMChannel(maximumFrames: 120_000, maximumPackets: 1024)
    nonisolated private let receiveTiming = ReceivedTiming()
    private var generation = UUID()
    private var started = false
    private var closing = false
    private var ready = false
    private var lastReport: TimeInterval = 0
    private var lastElapsed: Int?
    private var expiresAt: TimeInterval?
    private var warnedExpiration = false

    init(wire: any RealtimeTranslationWire = OpenAIRealtimeWire(),
         transportFactory: (@Sendable (String) -> any TranslationWebSocket)? = nil,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.wire = wire
        makeSocket = transportFactory ?? { [wire] in URLTranslationWebSocket(request: wire.request(credential: $0)) }
        now = clock
    }

    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        try await start(configuration: configuration, apiKey: credentials.require(wire.service))
    }

    func start(configuration: TranslationConfiguration, apiKey: String) async throws {
        guard !started else { throw BridgeError.unavailable("Create a fresh translation session before starting again.") }
        started = true
        let token = generation
        let wire = self.wire
        let opening = try wire.opening(configuration), update = try wire.update(configuration)
        let socket = makeSocket(apiKey)
        self.socket = socket
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            socket.cancel()
        }
        defer { deadline.cancel() }
        do {
            for message in opening { try await socket.send(message) }
            var gotCreated = !wire.waitsForCreated
            while !ready {
                for envelope in try await Self.readEvents(socket, wire) where !ready {
                    guard token == generation, !closing, !Task.isCancelled else { throw CancellationError() }
                    if let expiry = envelope.timing.expiresAt { expiresAt = expiry }
                    switch envelope.event {
                    case .created where !gotCreated:
                        gotCreated = true
                        if let update { try await socket.send(update) }
                    case .updated where gotCreated: ready = true
                    case .failure, .closed: throw BridgeError.unavailable("The service rejected or closed the session.")
                    default: break
                    }
                }
            }
            guard token == generation, !closing, !Task.isCancelled else { throw CancellationError() }
        } catch {
            cancel()
            throw BridgeError.unavailable("Could not configure \(wire.service.displayName) translation. Check the API key, billing, model access, and network.")
        }
        upload.open(); received.open()
        lastReport = now()
        let upload = self.upload, received = self.received, clock = now, timing = receiveTiming, sink = audioSink, controls = self.controls
        sender = Task.detached { [weak self] in
            do {
                for await packet in upload.stream {
                    guard !Task.isCancelled else { return }
                    guard clock() - packet.admittedAt <= 5 else { throw BridgeError.uploadBacklog }
                    try await socket.send(wire.append(packet.pcm))
                    upload.complete(packet)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self?.fail("audio_send_failed", token: token)
            }
        }
        audioConsumer = Task.detached { [weak self] in
            for await packet in received.stream {
                var offset = 0
                while offset < packet.pcm.count {
                    guard !Task.isCancelled else { return }
                    guard clock() - packet.admittedAt <= 5 else {
                        await self?.fail("received_audio_stale", token: token); return
                    }
                    let end = min(offset + 4800, packet.pcm.count)
                    let piece = Data(packet.pcm[offset..<end])
                    if let handler = sink.get() {
                        do { try await handler(piece) }
                        catch {
                            guard !Task.isCancelled else { return }
                            await self?.fail("audio_playback_failed", token: token); return
                        }
                    } else {
                        await self?.deliverAudio(piece, token: token)
                    }
                    offset = end
                }
                received.complete(packet)
            }
        }
        controlConsumer = Task { [weak self] in
            for await entry in controls.stream {
                guard !Task.isCancelled else { return }
                let keepReading = await self?.acceptControl(entry.envelope, token: token) ?? false
                controls.complete(entry)
                if !keepReading { return }
            }
        }
        reader = Task.detached { [weak self] in
            do {
                while !Task.isCancelled {
                  for envelope in try await Self.readEvents(socket, wire) {
                    guard !Task.isCancelled else { return }
                    if case .audio(let pcm) = envelope.event {
                        let instant = clock()
                        do {
                            try received.append(pcm, at: instant)
                            timing.record(frames: pcm.count / 2, elapsed: envelope.timing.elapsedMilliseconds, at: instant)
                        } catch {
                            // Closing intentionally discards tail audio while continuing transcript draining.
                            let stop = await self?.receiveOverflow(oversized: pcm.count > 240_000, token: token) ?? true
                            if stop { return }
                        }
                    } else {
                        do { try controls.append(envelope) }
                        catch {
                            socket.cancel()
                            await self?.fail("control_event_backlog", token: token); return
                        }
                        if case .failure = envelope.event { socket.cancel(); controls.finish(); return }
                        if case .closed = envelope.event { controls.finish(); return }
                    }
                  }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self?.fail("translation_disconnected", token: token)
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard let self, token == self.generation else { return }
                await self.checkHealth(token: token)
            }
        }
    }
    nonisolated private static func readEvents(_ socket: any TranslationWebSocket, _ wire: any RealtimeTranslationWire) async throws -> [TranslationEnvelope] {
        let data = try await socket.receive()
        guard data.count <= 400_000 else { throw BridgeError.invalidEvent }
        return try wire.decode(data)
    }
    nonisolated func append(_ pcm: Data) throws { try upload.append(pcm) }
    private func receiveOverflow(oversized: Bool, token: UUID) async -> Bool {
        guard token == generation else { return true }
        if closing { return false }
        await fail(oversized ? "audio_burst_exceeds_five_seconds" : "received_audio_backlog", token: token)
        return true
    }
    private func acceptControl(_ envelope: TranslationEnvelope, token: UUID) async -> Bool {
        guard token == generation else { return false }
        if let expiry = envelope.timing.expiresAt { expiresAt = expiry }
        switch envelope.event {
        case .failure(let code): await fail(code, token: token); return false
        case .closed:
            await onEvent?(.closed)
            if !closing { await fail("unexpected_session_close", token: token) }
            return false
        default: await onEvent?(envelope.event)
        }
        if envelope.timing.elapsedMilliseconds != nil || envelope.timing.expiresAt != nil {
            await onEvent?(.timing(envelope.timing))
        }
        return token == generation
    }
    private func deliverAudio(_ pcm: Data, token: UUID) async {
        guard token == generation, !closing else { return }
        await onEvent?(.audio(pcm))
    }
    private func checkHealth(token: UUID) async {
        let instant = now()
        let input = upload.snapshot(at: instant), output = received.snapshot(at: instant)
        if !closing && (input.oldestAge > 5 || output.oldestAge > 5) {
            await fail(input.oldestAge > 5 ? "audio_upload_stale" : "received_audio_stale", token: token); return
        }
        if let expiresAt {
            let remaining = expiresAt - Date().timeIntervalSince1970
            if remaining <= 0 { await fail("session_expired", token: token); return }
            if remaining <= 60, !warnedExpiration {
                warnedExpiration = true
                await onEvent?(.notice("Translation session expires in less than one minute. Stop and start a fresh session when convenient."))
            }
        }
        let timing = receiveTiming.snapshot()
        if timing.elapsed != lastElapsed {
            lastElapsed = timing.elapsed
            await onEvent?(.timing(.init(elapsedMilliseconds: timing.elapsed, expiresAt: expiresAt)))
        }
        guard instant - lastReport >= 10 else { return }
        lastReport = instant
        let alignment = timing.elapsed.map(String.init) ?? "unavailable"
        await onEvent?(.notice(String(format: "Stream timing: sent %.1fs; received %.1fs; waiting %.2fs; oldest %.2fs; largest arrival gap %.2fs; alignment %@ms (not audible latency).",
                                     Double(input.completedFrames) / 24_000, Double(timing.frames) / 24_000,
                                     Double(output.frames) / 24_000, output.oldestAge, timing.maximumGap, alignment)))
    }
    func stopInput() {
        upload.cancel()
        sender?.cancel()
    }
    func finish() async {
        guard !closing, let socket else { cancel(); return }
        guard ready else { cancel(); return }
        let token = generation
        closing = true; ready = false
        upload.finish()
        received.cancel(); audioConsumer?.cancel(); audioConsumer = nil
        let deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            await self?.fail("finalization_timed_out", token: token)
        }
        await sender?.value
        if token == generation {
            do {
                if let closing = wire.closing { try await socket.send(closing) }
                if wire.confirmsClose {
                    await reader?.value
                    await controlConsumer?.value
                } else {
                    // No close confirmation: allow the last transcript events to arrive.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            } catch { await fail("finalization_failed", token: token) }
        }
        deadline.cancel()
        if token == generation { cancel() }
    }
    func cancel() {
        generation = UUID(); ready = false
        audioSink.set(nil)
        upload.cancel(); received.cancel(); controls.cancel()
        sender?.cancel(); sender = nil
        reader?.cancel(); reader = nil
        audioConsumer?.cancel(); audioConsumer = nil
        monitor?.cancel(); monitor = nil
        controlConsumer?.cancel(); controlConsumer = nil
        socket?.cancel(); socket = nil
    }
    private func fail(_ code: String, token: UUID) async {
        guard token == generation else { return }
        cancel()
        await onEvent?(.failure(code))
    }
}
