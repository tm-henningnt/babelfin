import Foundation
import BridgeCore

/// OpenAI live transcription (gpt-live-transcribe) as the recognizer of a composed route.
/// The service has no turn detection, so Babelfin commits each passage: at the end of speech,
/// or at a short pause after 4–8 s of continuous speech. Transcripts of different passages can
/// complete out of order; final segments are delivered in commit order.
/// https://developers.openai.com/api/docs/guides/realtime-transcription
@MainActor final class OpenAILiveRecognizer: StreamingSpeechRecognizer {
    var onEvent: RecognitionEventHandler?
    private let makeSocket: @Sendable (URLRequest) -> any ProviderWebSocket
    private let session = RecognitionSocketSession()
    private var sourceLanguage: String?
    /// Items in the order they appeared, with their partial text, revision and final text.
    private var order: [String] = []
    /// The members of `order`, for a constant-time check per event.
    private var ordered: Set<String> = []
    private var partials: [String: (text: String, revision: Int)] = [:]
    private var finals: [String: String] = [:]
    private let finishTimeout: TimeInterval
    static let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    init(finishTimeout: TimeInterval = 5, transportFactory: @escaping @Sendable (URLRequest) -> any ProviderWebSocket = { URLProviderWebSocket(request: $0) }) {
        self.finishTimeout = finishTimeout; makeSocket = transportFactory
    }

    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        try session.claim()
        sourceLanguage = configuration.sourceLanguage
        if let sourceLanguage { try validateProviderToken(sourceLanguage) }
        var request = URLRequest(url: Self.endpoint); request.timeoutInterval = 20
        request.setValue("Bearer \(try credentials.require(.openAI))", forHTTPHeaderField: "Authorization")
        let update = try Self.sessionUpdate(language: sourceLanguage, pacing: configuration.pacing)
        try await session.open(makeSocket(request), startFailure: "Could not start OpenAI recognition. Check your key, its Realtime permission and network.") { socket in
            try await socket.send(update)
            // The session is ready when the service confirms the transcription configuration.
            while true {
                let type = try Self.message(try await session.receiveDuringStart())["type"] as? String
                guard type != "error" else { throw ProviderNetworkError.invalidResponse }
                if type == "session.updated" { break }
            }
        }
        session.run(pacing: configuration.pacing, commitsOnSilence: true,
                    send: { socket, pcm, commit in
                        try await socket.send(Self.append(pcm))
                        if commit { try await socket.send(Self.commit) }
                    },
                    consume: { [weak self] data, token in try await self?.consume(data, token: token) },
                    report: { [weak self] message in await self?.onEvent?(.failure(message)) })
    }
    nonisolated func append(_ pcm: Data) throws { try session.upload.append(pcm) }
    func stopInput() { session.stopInput() }
    func updatePacing(_ pacing: TranslationPacing) { session.updatePacing(pacing) }

    func finish() async throws {
        let closed = try await session.finish(timeout: finishTimeout) { socket in
            guard session.upload.snapshot().completedFrames > 0 else { return }
            // Commit the last passage. An empty buffer is answered with an error that consume ignores.
            try await session.sendFinal { try await socket.send(Self.commit) }
            // Wait for the last commit to be acknowledged and every passage to complete.
            try await Task.sleep(nanoseconds: 300_000_000)
            try await session.wait(until: { [unowned self] in order.isEmpty }, timeout: finishTimeout - 0.3)
            guard order.isEmpty else { throw BridgeError.unavailable("The final recognition transcript was not confirmed before the session closed.") }
        }
        if closed { await onEvent?(.closed) }
    }
    func cancel() { session.cancel() }

    private func consume(_ data: Data, token: UUID) async throws {
        let object = try Self.message(data)
        guard let type = object["type"] as? String else { throw ProviderNetworkError.invalidResponse }
        /// The event's item, added to the commit order on first sight.
        func recordItem() throws -> String {
            guard let id = object["item_id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { throw ProviderNetworkError.invalidResponse }
            if !ordered.contains(id) && finals[id] == nil { order.append(id); ordered.insert(id) }
            return id
        }
        switch type {
        case "input_audio_buffer.committed":
            _ = try recordItem()
        case "conversation.item.input_audio_transcription.delta":
            let id = try recordItem()
            guard let delta = object["delta"] as? String, finals[id] == nil else { return }
            var partial = partials[id] ?? ("", 0)
            partial.text += delta; partial.revision += 1
            guard partial.text.utf8.count <= 32_000 else { throw ProviderNetworkError.invalidResponse }
            partials[id] = partial
            await onEvent?(.segment(TranscriptSegment(id: "openai-" + id, revision: partial.revision, text: partial.text,
                                                      isFinal: false, language: sourceLanguage)))
        case "conversation.item.input_audio_transcription.completed":
            let id = try recordItem()
            guard let text = object["transcript"] as? String, text.utf8.count <= 32_000 else { throw ProviderNetworkError.invalidResponse }
            finals[id] = text
            await releaseFinals(token: token)
        case "conversation.item.input_audio_transcription.failed":
            // A passage that could not be transcribed must not hold back later passages.
            finals[try recordItem()] = ""
            await releaseFinals(token: token)
        case "error":
            // A commit with no new audio is harmless; anything else ends recognition.
            let code = (object["error"] as? [String: Any])?["code"] as? String
            if code == "input_audio_buffer_commit_empty" { return }
            await session.fail("OpenAI could not continue recognition. Check the key's Realtime permission and usage limits.", token: token)
        default: break // Session and buffer notices carry no transcript.
        }
    }
    /// Delivers completed passages in commit order.
    private func releaseFinals(token: UUID) async {
        while token == session.generation, let first = order.first, let text = finals[first] {
            order.removeFirst(); ordered.remove(first); finals[first] = nil
            let revision = (partials.removeValue(forKey: first)?.revision ?? 0) + 1
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            await onEvent?(.segment(TranscriptSegment(id: "openai-" + first, revision: revision, text: text, isFinal: true, language: sourceLanguage)))
        }
    }

    nonisolated static func sessionUpdate(language: String?, pacing: TranslationPacing) throws -> String {
        var transcription: [String: Any] = ["model": "gpt-live-transcribe", "delay": pacing == .context ? "medium" : "low"]
        if let language { transcription["languages"] = [language] }
        let session: [String: Any] = ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24_000], "transcription": transcription, "turn_detection": NSNull()]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["type": "session.update", "session": session]), as: UTF8.self)
    }
    nonisolated private static let commit = #"{"type":"input_audio_buffer.commit"}"#
    nonisolated private static func append(_ pcm: Data) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]), as: UTF8.self)
    }
    nonisolated private static func message(_ data: Data) throws -> [String: Any] {
        guard data.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderNetworkError.invalidResponse }
        return object
    }
}
