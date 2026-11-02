import Foundation
import BridgeCore

@MainActor final class ElevenLabsSpeechRecognizer: StreamingSpeechRecognizer {
    var onEvent: RecognitionEventHandler?
    private let makeSocket: @Sendable (URLRequest) -> any ProviderWebSocket
    private let session = RecognitionSocketSession()
    private var segmentID = UUID().uuidString, revision = 0, commits = 0
    private var sourceLanguage: String?
    private var unresolvedPartial = false, emptyCommitAcknowledged = false
    private var lastTranscriptAt: TimeInterval = 0
    private let finishTimeout: TimeInterval
    init(finishTimeout: TimeInterval = 5, transportFactory: @escaping @Sendable (URLRequest) -> any ProviderWebSocket = { URLProviderWebSocket(request: $0) }) {
        self.finishTimeout = finishTimeout; makeSocket = transportFactory
    }
    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        try session.claim()
        sourceLanguage = configuration.sourceLanguage
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        components.queryItems = [.init(name: "model_id", value: "scribe_v2_realtime"), .init(name: "audio_format", value: "pcm_24000"),
                                 .init(name: "commit_strategy", value: "vad"), .init(name: "vad_silence_threshold_secs", value: String(configuration.pacing.commitSilenceSeconds))]
        if let sourceLanguage { try validateProviderToken(sourceLanguage); components.queryItems?.append(.init(name: "language_code", value: sourceLanguage)) }
        var request = URLRequest(url: components.url!); request.timeoutInterval = 20
        request.setValue(try credentials.require(.elevenLabs), forHTTPHeaderField: "xi-api-key")
        try await session.open(makeSocket(request), startFailure: "Could not start ElevenLabs recognition. Check your key, account access and network.") { _ in
            let hello = try Self.message(try await session.receiveDuringStart())
            guard hello["message_type"] as? String == "session_started",
                  let sessionID = hello["session_id"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 256,
                  let config = hello["config"] as? [String: Any] else { throw ProviderNetworkError.invalidResponse }
            if let rate = config["sample_rate"] as? Int, rate != 24_000 { throw ProviderNetworkError.invalidResponse }
            if let format = config["audio_format"] as? String, format != "pcm_24000" { throw ProviderNetworkError.invalidResponse }
            if let model = config["model_id"] as? String, model != "scribe_v2_realtime" { throw ProviderNetworkError.invalidResponse }
        }
        // Scribe commits at the end of speech by itself; Babelfin commits only long passages.
        session.run(pacing: configuration.pacing, commitsOnSilence: false,
                    send: { socket, pcm, commit in try await socket.send(Self.audioMessage(pcm, commit: commit)) },
                    consume: { [weak self] data, token in try await self?.consume(data, token: token) },
                    report: { [weak self] message in await self?.onEvent?(.failure(message)) })
    }
    nonisolated func append(_ pcm: Data) throws { try session.upload.append(pcm) }
    func stopInput() { session.stopInput() }
    func updatePacing(_ pacing: TranslationPacing) { session.updatePacing(pacing) }
    func finish() async throws {
        let closed = try await session.finish(timeout: finishTimeout) { socket in
            guard session.upload.snapshot().completedFrames > 0 else { return }
            let before = commits
            try await session.sendFinal { try await socket.send(Self.audioMessage(Data(), commit: true)) }
            // Scribe has no commit identifier/close ACK. Allow queued automatic commits
            // and a trailing partial to drain before treating a new final as settled.
            try await session.wait(until: { [unowned self] in
                !unresolvedPartial && (emptyCommitAcknowledged || (commits > before && ProcessInfo.processInfo.systemUptime - lastTranscriptAt >= min(0.25, finishTimeout / 2)))
            }, timeout: finishTimeout)
            guard !unresolvedPartial, commits > 0 || emptyCommitAcknowledged else {
                throw BridgeError.unavailable("The final recognition transcript was not confirmed before the session closed.")
            }
        }
        if closed { await onEvent?(.closed) }
    }
    func cancel() { session.cancel() }
    private func consume(_ data: Data, token: UUID) async throws {
        let object = try Self.message(data)
        guard let type = object["message_type"] as? String else { throw ProviderNetworkError.invalidResponse }
        switch type {
        case "partial_transcript", "committed_transcript":
            guard let text = object["text"] as? String, text.utf8.count <= 32_000 else { throw ProviderNetworkError.invalidResponse }
            revision += 1
            lastTranscriptAt = ProcessInfo.processInfo.systemUptime
            let final = type == "committed_transcript"
            unresolvedPartial = !final && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if final { session.noteCommitted() } else { session.notePartial(text) }
            let segment = TranscriptSegment(id: segmentID, revision: revision, text: text, isFinal: final, language: sourceLanguage)
            // Increment only after the final callback drains: finish must not outrun the transcript consumer.
            await onEvent?(.segment(segment))
            if final { commits += 1; segmentID = UUID().uuidString; revision = 0 }
        case "insufficient_audio_activity":
            // A commit found no new speech. While closing, that settles the final transcript.
            if session.closing && !unresolvedPartial { emptyCommitAcknowledged = true }
        case "session_started", "committed_transcript_with_timestamps", "warning": break // No untrusted warning text is logged.
        case "error", "auth_error", "quota_exceeded", "throttled", "unaccepted_terms", "rate_limited", "queue_overflow", "resource_exhausted", "session_time_limit_exceeded", "input_error", "invalid_request", "chunk_size_exceeded", "transcriber_error":
            await session.fail("ElevenLabs could not continue recognition. Check account access and usage limits.", token: token)
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
