import Foundation
import BridgeCore

/// Fish Audio realtime recognition (transcribe-stream-1) as the recognizer of a composed route.
/// Every frame is one binary MessagePack map. Turn detection is manual: Babelfin finalizes each
/// passage at the end of speech or at a short pause after 4–8 s, as on the other routes, so
/// Fish's automatic mode cannot classify loopback or TV speech as a non-user turn.
/// https://docs.fish.audio/api-reference/endpoint/websocket/asr-realtime
@MainActor final class FishLiveRecognizer: StreamingSpeechRecognizer {
    var onEvent: RecognitionEventHandler?
    private let makeSocket: @Sendable (URLRequest) -> any ProviderWebSocket
    private let session = RecognitionSocketSession()
    private var done = false
    private var sourceLanguage: String?
    private var revisions: [Int64: Int] = [:]
    /// Fish's speaker numbers mapped to labels "1", "2", … in the order of first appearance.
    private var speakerLabels: [Int: String] = [:]
    private let finishTimeout: TimeInterval
    static let endpoint = URL(string: "wss://api.fish.audio/v1/asr/realtime")!

    init(finishTimeout: TimeInterval = 5, transportFactory: @escaping @Sendable (URLRequest) -> any ProviderWebSocket = { URLProviderWebSocket(request: $0) }) {
        self.finishTimeout = finishTimeout; makeSocket = transportFactory
    }

    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        try session.claim()
        sourceLanguage = configuration.sourceLanguage
        let config = Self.config(diarize: !configuration.speakerVoices.isEmpty)
        var request = URLRequest(url: Self.endpoint); request.timeoutInterval = 20
        request.setValue("Bearer \(try credentials.require(.fish))", forHTTPHeaderField: "Authorization")
        request.setValue("transcribe-stream-1", forHTTPHeaderField: "model")
        try await session.open(makeSocket(request), startFailure: "Could not start Fish Audio recognition. Check your key, account access and network.") { socket in
            try await socket.send(data: config)
            while true {
                let type = try Self.message(try await session.receiveDuringStart())["type"]?.string
                guard type != "error" else { throw ProviderNetworkError.invalidResponse }
                if type == "session_started" { break }
            }
        }
        session.run(pacing: configuration.pacing, commitsOnSilence: true,
                    send: { socket, pcm, commit in
                        try await socket.send(data: MessagePack.encode(.map(["type": .string("audio"), "data": .binary(pcm)])))
                        if commit { try await socket.send(data: Self.finalize) }
                    },
                    consume: { [weak self] data, token in try await self?.consume(data, token: token) },
                    // The service closes the socket after session_done; that close is expected while finishing.
                    closeExpected: { [weak self] in
                        guard let self else { return true }
                        return session.closing && done
                    },
                    report: { [weak self] message in await self?.onEvent?(.failure(message)) })
    }
    nonisolated func append(_ pcm: Data) throws { try session.upload.append(pcm) }
    func stopInput() { session.stopInput() }
    func updatePacing(_ pacing: TranslationPacing) { session.updatePacing(pacing) }

    func finish() async throws {
        let closed = try await session.finish(timeout: finishTimeout) { socket in
            // audio_done commits the open turn; the service answers with session_done.
            try await session.sendFinal { try await socket.send(data: Self.audioDone) }
            try await session.wait(until: { [unowned self] in done }, timeout: finishTimeout)
            guard done else { throw BridgeError.unavailable("The final recognition transcript was not confirmed before the session closed.") }
        }
        if closed { await onEvent?(.closed) }
    }
    func cancel() { session.cancel() }

    private func consume(_ data: Data, token: UUID) async throws {
        let message = try Self.message(data)
        guard let type = message["type"]?.string else { throw ProviderNetworkError.invalidResponse }
        switch type {
        case "draft", "committed":
            guard let turn = message["turn_index"]?.int, let text = message["text"]?.string, text.utf8.count <= 32_000 else {
                throw ProviderNetworkError.invalidResponse
            }
            let final = type == "committed"
            // A turn the service classifies as a backchannel or other speaker is not translated.
            if final, let kind = message["turn_kind"]?.string, kind != "user" { revisions[turn] = nil; return }
            let revision = (revisions[turn] ?? 0) + 1
            revisions[turn] = final ? nil : revision
            let language = message["language_code"]?.string.flatMap { $0.utf8.count <= 16 ? $0 : nil } ?? sourceLanguage
            let parts = Self.speakerParts(text)
            guard final else {
                // A draft shows the words without tags; it gets a speaker when it commits.
                let words = parts.map(\.text).joined(separator: " ")
                await onEvent?(.segment(TranscriptSegment(id: "fish-\(turn)", revision: revision, text: words, isFinal: false, language: language)))
                return
            }
            // A committed turn can hold several speakers: each part becomes its own final segment.
            for (index, part) in parts.enumerated() {
                let label = part.speaker.map(label(for:))
                await onEvent?(.segment(TranscriptSegment(id: index == 0 ? "fish-\(turn)" : "fish-\(turn).\(index)", revision: revision,
                                                          text: part.text, isFinal: true, language: language, speaker: label)))
            }
        case "session_done":
            done = true
        case "error":
            // Recoverable errors leave the session running; the others close it.
            if message["recoverable"]?.bool == true { return }
            await session.fail("Fish Audio could not continue recognition. Check account access and usage limits.", token: token)
        default: break // Speech, progress and configuration notices carry no transcript.
        }
    }

    private func label(for speaker: Int) -> String {
        if let label = speakerLabels[speaker] { return label }
        let label = String(speakerLabels.count + 1)
        speakerLabels[speaker] = label
        return label
    }
    /// Splits text at `<|speaker:N|>` tags. A part before any tag has no speaker; a part after a
    /// tag keeps that speaker. Empty parts are dropped. Without tags the text is one part.
    nonisolated static func speakerParts(_ text: String) -> [(speaker: Int?, text: String)] {
        var parts: [(speaker: Int?, text: String)] = [], speaker: Int?, rest = Substring(text)
        func add(_ words: Substring) {
            let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append((speaker, trimmed)) }
        }
        while let open = rest.range(of: "<|speaker:"), let close = rest[open.upperBound...].range(of: "|>") {
            add(rest[..<open.lowerBound])
            if let number = Int(rest[open.upperBound..<close.lowerBound]), (0...999).contains(number) { speaker = number }
            rest = rest[close.upperBound...]
        }
        add(rest)
        return parts
    }

    nonisolated static func config(diarize: Bool) -> Data {
        MessagePack.encode(.map([
            "type": .string("config"), "protocol_version": .int(1),
            "audio": .map(["format": .string("pcm_s16le"), "sample_rate": .int(24_000), "channels": .int(1)]),
            "turn_detection": .map(["mode": .string("manual")]),
            "results": .map(["drafts": .bool(true), "diarize": .bool(diarize), "tag_audio_events": .bool(false)]),
        ]))
    }
    nonisolated private static let finalize = MessagePack.encode(.map(["type": .string("finalize")]))
    nonisolated private static let audioDone = MessagePack.encode(.map(["type": .string("audio_done")]))
    nonisolated private static func message(_ data: Data) throws -> MessagePackValue {
        guard data.count <= 65_536, let value = try? MessagePack.decode(data), case .map = value else { throw ProviderNetworkError.invalidResponse }
        return value
    }
}
