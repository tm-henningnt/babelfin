import AVFoundation
import Foundation
import BridgeCore

/// Batch recognition is a separate seam from a continuously running microphone recognizer.
@MainActor protocol SpeechToolsTranscriber: AnyObject {
    var requiredServices: Set<ProviderService> { get }
    func transcribe(source: RecordingSource, sourceLanguage: String?, diarize: Bool,
                    credentials: ProviderCredentials) async throws -> RecordingTranscript
    func cancel()
}
extension SpeechToolsTranscriber {
    func transcribe(fileURL: URL, sourceLanguage: String?, diarize: Bool,
                    credentials: ProviderCredentials) async throws -> RecordingTranscript {
        try await transcribe(source: .file(fileURL), sourceLanguage: sourceLanguage, diarize: diarize, credentials: credentials)
    }
}

/// Explicit, single-operation tools. File selection, initialization and cancellation never upload.
/// Credentials are supplied in memory by the caller; this service does not read storage or Keychain.
@MainActor final class SpeechToolsService {
    var onProgress: (@MainActor @Sendable (SpeechToolsProgress) -> Void)?
    private let transport: any ProviderHTTPTransport
    private let transcriber: any SpeechToolsTranscriber
    private let translator: any TextTranslationStage
    private let elevenSynthesis: any SpeechSynthesisStage
    private let fishSynthesis: any SpeechSynthesisStage
    private let systemSynthesis: any SpeechSynthesisStage
    private let geminiSynthesis: any SpeechSynthesisStage
    private let voiceChanger: ElevenLabsVoiceChanger
    private let operationTimeout: TimeInterval
    private var operation: ProviderCancellation?
    private var expired = false

    init(transport: any ProviderHTTPTransport = URLProviderHTTPTransport(),
         transcriber: (any SpeechToolsTranscriber)? = nil, translator: (any TextTranslationStage)? = nil,
         elevenSynthesis: (any SpeechSynthesisStage)? = nil, fishSynthesis: (any SpeechSynthesisStage)? = nil,
         systemSynthesis: (any SpeechSynthesisStage)? = nil, geminiSynthesis: (any SpeechSynthesisStage)? = nil,
         operationTimeout: TimeInterval = 600) {
        self.transport = transport
        self.transcriber = transcriber ?? ElevenLabsRecordingTranscriber(transport: transport)
        self.translator = translator ?? OpenAITextTranslationStage(transport: transport)
        self.elevenSynthesis = elevenSynthesis ?? ElevenLabsSpeechSynthesisStage(transport: transport)
        self.fishSynthesis = fishSynthesis ?? FishSpeechSynthesisStage(transport: transport)
        self.systemSynthesis = systemSynthesis ?? AppleSpeechSynthesisStage()
        self.geminiSynthesis = geminiSynthesis ?? GeminiSpeechSynthesisStage(transport: transport)
        self.voiceChanger = ElevenLabsVoiceChanger(transport: transport)
        self.operationTimeout = operationTimeout.isFinite ? min(3_600, max(0.01, operationTimeout)) : 600
    }

    func transcribe(fileURL: URL, sourceLanguage: String? = nil, diarize: Bool = true,
                    credentials: ProviderCredentials) async throws -> RecordingTranscript {
        try await transcribe(source: .file(fileURL), sourceLanguage: sourceLanguage, diarize: diarize, credentials: credentials)
    }
    func transcribe(source: RecordingSource, sourceLanguage: String? = nil, diarize: Bool = true,
                    credentials: ProviderCredentials) async throws -> RecordingTranscript {
        for service in transcriber.requiredServices { _ = try credentials.require(service) }
        return try await perform { token in
            self.onProgress?(.init(stage: .transcription, completed: 0, total: 1)); try token.check()
            let result = try await self.transcriber.transcribe(source: source, sourceLanguage: sourceLanguage,
                                                               diarize: diarize, credentials: credentials)
            try token.check(); try result.validate()
            self.onProgress?(.init(stage: .transcription, completed: 1, total: 1))
            return result
        }
    }

    func translate(transcript: RecordingTranscript, targetLanguage: String,
                   credentials: ProviderCredentials) async throws -> RecordingTranscript {
        try transcript.validate(); try validateProviderToken(targetLanguage)
        guard targetLanguage.utf8.count <= 32 else { throw ProviderNetworkError.invalidRequest }
        guard !transcript.segments.isEmpty else { throw SpeechToolsError.emptyText }
        _ = try credentials.require(.openAI)
        return try await perform { token in
            var output: [RecordingSegment] = [], translatedBytes = 0
            self.onProgress?(.init(stage: .translation, completed: 0, total: transcript.segments.count))
            for segment in transcript.segments {
                try token.check(); try Task.checkCancellation()
                let translated = try await self.translator.translate(text: segment.sourceText,
                    sourceLanguage: transcript.sourceLanguage, targetLanguage: targetLanguage, credentials: credentials)
                try token.check(); try Task.checkCancellation()
                translatedBytes += translated.utf8.count
                guard translatedBytes <= SpeechToolsLimits.translatedBytes else { throw SpeechToolsError.transcriptTooLarge }
                output.append(segment.translated(translated))
                self.onProgress?(.init(stage: .translation, completed: output.count, total: transcript.segments.count))
            }
            let result = RecordingTranscript(sourceLanguage: transcript.sourceLanguage, targetLanguage: targetLanguage, segments: output)
            try result.validate()
            return result
        }
    }

    func notes(text: String, credentials: ProviderCredentials) async throws -> MeetingNotes {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechToolsError.emptyText }
        guard text.utf8.count <= SpeechToolsLimits.notesBytes else { throw SpeechToolsError.notesTooLarge }
        let credential = try credentials.require(.openAI)
        let chunks = try SpeechToolsText.chunks(text, maximumBytes: SpeechToolsLimits.notesChunkBytes)
        return try await perform { token in
            var results: [String] = [], covered = 0, resultBytes = 0
            self.onProgress?(.init(stage: .notes, completed: 0, total: chunks.count))
            for (index, chunk) in chunks.enumerated() {
                try token.check(); try Task.checkCancellation()
                // The same structured notes as a recording; instructions are code-controlled and the text is data.
                let part = chunks.count == 1 ? "" : " This is part \(index + 1) of \(chunks.count) of the meeting; do not claim it covers the whole meeting."
                let instructions = MeetingPrompts.notes(language: nil, glossary: GlossaryStore.terms, timed: false)
                    + " The text may hold both original speech and its translation; count them once." + part
                let request = try providerJSONRequest(URL(string: "https://api.openai.com/v1/responses")!, body: [
                    "model": MeetingTextStage.model, "store": false, "reasoning": ["effort": "low"], "max_output_tokens": 4_000,
                    "instructions": instructions, "input": [["role": "user", "content": chunk]]
                ], header: "Authorization", credential: "Bearer \(credential)")
                let response = try await self.transport.json(request, maximumBytes: 262_144)
                try token.check(); try Task.checkCancellation()
                let note = try Self.notesText(response)
                resultBytes += note.utf8.count
                guard resultBytes <= SpeechToolsLimits.notesBytes else { throw ProviderNetworkError.overflow }
                results.append(chunks.count == 1 ? note : "# Part \(index + 1) of \(chunks.count)\n\(note)")
                covered += chunk.count
                self.onProgress?(.init(stage: .notes, completed: results.count, total: chunks.count))
            }
            return MeetingNotes(text: results.joined(separator: "\n\n"), sourceCharacters: text.count,
                                coveredCharacters: covered, chunkCount: chunks.count)
        }
    }

    /// Translates a short text, for example before Voice clip speaks it. Needs an OpenAI key.
    func translate(text: String, to language: String, credentials: ProviderCredentials) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechToolsError.emptyText }
        guard text.count <= SpeechToolsLimits.voiceCharacters, text.utf8.count <= 8_000 else { throw SpeechToolsError.clipTooLong }
        try validateProviderToken(language)
        _ = try credentials.require(.openAI)
        return try await perform { token in
            let result = try await self.translator.translate(text: text, sourceLanguage: nil, targetLanguage: language, credentials: credentials)
            try token.check(); try Task.checkCancellation()
            return result
        }
    }

    /// Returns a complete WAV for an explicit save/preview action; never plays or writes a file.
    func voiceClip(text: String, language: String, voiceID: String?, route: TranslationRoute,
                   direction: SpeechDirection = .standard, credentials: ProviderCredentials) async throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechToolsError.emptyText }
        guard text.count <= SpeechToolsLimits.voiceCharacters, text.utf8.count <= 8_000 else { throw SpeechToolsError.clipTooLong }
        try validateProviderToken(language)
        let stage = try synthesisStage(for: route, voiceID: voiceID, credentials: credentials)
        return try await perform { token in
            self.onProgress?(.init(stage: .voiceClip, completed: 0, total: 1)); try token.check()
            let audio = SpeechToolsBuffer(maximumBytes: SpeechToolsLimits.voicePCMBytes)
            try await stage.synthesize(text: text, language: language, voiceID: voiceID, direction: direction, credentials: credentials) { bytes in
                try token.check(); try Task.checkCancellation(); try audio.append(bytes)
            }
            try token.check(); try Task.checkCancellation()
            let result = try SpeechToolsWAV.encode(pcm: audio.data())
            self.onProgress?(.init(stage: .voiceClip, completed: 1, total: 1))
            return result
        }
    }

    /// Speaks each translated segment at its original time and returns one WAV. With
    /// `includeOriginal`, the original recording plays under the dub and ducks as in live translation.
    func dub(transcript: RecordingTranscript, source: RecordingSource, includeOriginal: Bool, originalLevel: Float,
             voiceID: String?, route: TranslationRoute, direction: SpeechDirection,
             credentials: ProviderCredentials) async throws -> Data {
        try transcript.validate()
        guard let language = transcript.targetLanguage else { throw SpeechToolsError.emptyText }
        try validateProviderToken(language)
        let segments = transcript.segments.filter { !($0.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !segments.isEmpty else { throw SpeechToolsError.emptyText }
        guard segments.allSatisfy({ $0.startSeconds != nil }) else { throw SpeechToolsError.dubUntimed }
        guard (segments.compactMap(\.endSeconds).max() ?? 0) <= SpeechToolsLimits.dubSeconds else { throw SpeechToolsError.dubTooLong }
        let stage = try synthesisStage(for: route, voiceID: voiceID, credentials: credentials)
        let ordered = segments.sorted { ($0.startSeconds ?? 0) < ($1.startSeconds ?? 0) }
        return try await perform { token in
            var passages: [Data] = []
            self.onProgress?(.init(stage: .dub, completed: 0, total: ordered.count))
            for segment in ordered {
                try token.check(); try Task.checkCancellation()
                let audio = SpeechToolsBuffer(maximumBytes: SpeechToolsLimits.voicePCMBytes)
                try await stage.synthesize(text: segment.translatedText ?? "", language: language, voiceID: voiceID,
                                           direction: direction, credentials: credentials) { bytes in
                    try token.check(); try Task.checkCancellation(); try audio.append(bytes)
                }
                passages.append(audio.data())
                self.onProgress?(.init(stage: .dub, completed: passages.count, total: ordered.count))
            }
            try token.check()
            let slots = zip(ordered, passages).map { DubTimeline.Slot(start: $0.startSeconds ?? 0, duration: Double($1.count) / 2 / 24_000) }
            let original = includeOriginal ? try RecordingAudioDecoder.pcm24k(source, maximumSeconds: SpeechToolsLimits.dubSeconds) : nil
            let pcm = try DubRenderer.render(passages: passages, placements: DubTimeline.place(slots),
                                             original: original, originalLevel: originalLevel)
            return try SpeechToolsWAV.encode(pcm: pcm, maximumBytes: SpeechToolsLimits.dubPCMBytes)
        }
    }

    /// Speaks a microphone recording again with an ElevenLabs voice and returns a WAV.
    func revoice(wav: Data, voiceID: String, delivery: SpeechDirection.Delivery,
                 credentials: ProviderCredentials) async throws -> Data {
        guard wav.count <= SpeechToolsLimits.voicePCMBytes + 44 else { throw SpeechToolsError.revoiceTooLong }
        _ = try credentials.require(.elevenLabs)
        return try await perform { token in
            self.onProgress?(.init(stage: .voiceClip, completed: 0, total: 1)); try token.check()
            let audio = SpeechToolsBuffer(maximumBytes: SpeechToolsLimits.voicePCMBytes)
            try await self.voiceChanger.revoice(wav: wav, voiceID: voiceID, delivery: delivery, credentials: credentials) { bytes in
                try token.check(); try Task.checkCancellation(); try audio.append(bytes)
            }
            try token.check()
            self.onProgress?(.init(stage: .voiceClip, completed: 1, total: 1))
            return try SpeechToolsWAV.encode(pcm: audio.data())
        }
    }

    func cancel() {
        guard operation != nil else { return }
        operation?.cancel(); transport.cancel(); transcriber.cancel(); translator.cancel()
        elevenSynthesis.cancel(); fishSynthesis.cancel(); systemSynthesis.cancel(); geminiSynthesis.cancel(); voiceChanger.cancel()
    }

    /// The speech stage for a voice tool. ElevenLabs, Fish and Gemini need their key; ElevenLabs also
    /// needs a voice. On this Mac uses the system voices and sends nothing.
    private func synthesisStage(for route: TranslationRoute, voiceID: String?,
                                credentials: ProviderCredentials) throws -> any SpeechSynthesisStage {
        if route == .appleLocal { return systemSynthesis }
        if route == .fish { _ = try credentials.require(.fish); return fishSynthesis }
        if route == .gemini { _ = try credentials.require(.gemini); return geminiSynthesis }
        guard route == .elevenLabs else { throw SpeechToolsError.unsupportedVoiceProvider }
        guard voiceID != nil else { throw BridgeError.unavailable("Choose an ElevenLabs voice in Settings.") }
        _ = try credentials.require(.elevenLabs); return elevenSynthesis
    }

    private func perform<Value: Sendable>(_ body: @MainActor (ProviderCancellation) async throws -> Value) async throws -> Value {
        guard operation == nil else { throw ProviderNetworkError.busy }
        try Task.checkCancellation()
        let token = ProviderCancellation(); operation = token; expired = false
        let timeout = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.operationTimeout * 1_000_000_000)) }
            catch { return }
            guard self.operation === token else { return }
            self.expired = true; self.cancel()
        }
        defer { timeout.cancel(); operation = nil }
        do {
            let value = try await withTaskCancellationHandler {
                let value = try await body(token)
                try token.check(); try Task.checkCancellation()
                return value
            } onCancel: { token.cancel() }
            return value
        } catch {
            if expired { throw ProviderNetworkError.timedOut }
            do { try token.check() } catch { throw CancellationError() }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? SpeechToolsError { throw safe }
            if let safe = error as? ProviderNetworkError { throw safe }
            // No file path, response body, transport error description, or credential can escape.
            throw ProviderNetworkError.transport
        }
    }

    private static func notesText(_ response: [String: Any]) throws -> String {
        guard response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else {
            throw ProviderNetworkError.invalidResponse
        }
        let messages = output.filter { $0["type"] as? String == "message" }
        guard !messages.isEmpty, messages.allSatisfy({ $0["status"] as? String != "incomplete" }) else { throw ProviderNetworkError.invalidResponse }
        let content = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        guard !content.contains(where: { $0["type"] as? String == "refusal" }) else { throw ProviderNetworkError.invalidResponse }
        let text = content.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16_000 else { throw ProviderNetworkError.invalidResponse }
        return text
    }
}

@MainActor final class ElevenLabsRecordingTranscriber: SpeechToolsTranscriber {
    let requiredServices: Set<ProviderService> = [.elevenLabs]
    private let transport: any ProviderHTTPTransport
    private var operation: ProviderCancellation?
    private let glossary: @MainActor () -> [String]
    /// Scribe answers after it has transcribed the whole file, several minutes for a long meeting.
    init(transport: any ProviderHTTPTransport = URLProviderHTTPTransport(requestTimeout: 1_800, resourceTimeout: 1_800),
         glossary: @escaping @MainActor () -> [String] = { GlossaryStore.terms }) {
        self.transport = transport; self.glossary = glossary
    }
    func transcribe(source: RecordingSource, sourceLanguage: String?, diarize: Bool,
                    credentials: ProviderCredentials) async throws -> RecordingTranscript {
        guard operation == nil else { throw ProviderNetworkError.busy }
        let keyterms = glossary()
        if let sourceLanguage {
            try validateProviderToken(sourceLanguage)
            guard sourceLanguage.utf8.count <= 32 else { throw ProviderNetworkError.invalidRequest }
        }
        let key = try credentials.require(.elevenLabs)
        let token = ProviderCancellation(); operation = token; defer { operation = nil }
        var (request, bodyFile) = try await Task.detached {
            try Self.uploadRequest(source: source, sourceLanguage: sourceLanguage, diarize: diarize, keyterms: keyterms, token: token)
        }.value
        defer { if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) } }
        try token.check(); try Task.checkCancellation()
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let response = SpeechToolsBuffer(maximumBytes: 8 * 1_024 * 1_024)
        let collect: @Sendable (Data) async throws -> Void = { chunk in try token.check(); try response.append(chunk) }
        if let bodyFile {
            try await transport.upload(request, fromFile: bodyFile, maximumBytes: 8 * 1_024 * 1_024, contentTypes: ["application/json"], onChunk: collect)
        } else {
            try await transport.stream(request, maximumBytes: 8 * 1_024 * 1_024, contentTypes: ["application/json"], onChunk: collect)
        }
        try token.check(); try Task.checkCancellation()
        let data = response.data()
        return try await Task.detached {
            try token.check()
            let result = try SpeechToolsTranscription.parseElevenLabs(data, diarize: diarize)
            try token.check()
            return result
        }.value
    }
    func cancel() { operation?.cancel(); transport.cancel() }

    /// The private folder for upload bodies. MeetingRecorder deletes what is left in it at launch.
    nonisolated static var uploadFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Babelfin recordings", isDirectory: true) }

    /// The request and, for a file source, the multipart body in a private file that the caller deletes.
    /// A file is copied into the body in blocks, so a long meeting is never held in memory.
    nonisolated private static func uploadRequest(source: RecordingSource, sourceLanguage: String?, diarize: Bool,
                                                  keyterms: [String], token: ProviderCancellation) throws -> (URLRequest, URL?) {
        let types = ["wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4", "mp4": "video/mp4",
                     "flac": "audio/flac", "ogg": "audio/ogg", "webm": "audio/webm"]
        if case .file(let url) = source, url.isFileURL, types[url.pathExtension.lowercased()] == nil { throw SpeechToolsError.unsupportedFormat }
        let file = try source.uploadFile()
        let audio = file == nil ? try source.upload(check: token.check) : nil
        let fileExtension = file?.fileExtension ?? audio?.fileExtension ?? ""
        guard let mime = types[fileExtension] else { throw SpeechToolsError.unsupportedFormat }
        let boundary = "Babelfin-" + UUID().uuidString
        var body = Data()
        func field(_ key: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", "scribe_v2"); field("diarize", diarize ? "true" : "false")
        field("timestamps_granularity", "word"); field("tag_audio_events", "false")
        field("use_speaker_library", "false"); field("detect_speaker_roles", "false")
        field("webhook", "false"); field("use_multi_channel", "false")
        if let sourceLanguage { field("language_code", sourceLanguage) }
        // Repeated fields: Scribe rejects a JSON array (probe 2026-11-01). Keyterms add 20% to the price.
        for term in keyterms { field("keyterms", term) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.\(fileExtension)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        let trailer = Data("\r\n--\(boundary)--\r\n".utf8)
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        var bodyFile: URL?
        if let file {
            bodyFile = try writeBody(head: body, file: file.url, size: file.size, trailer: trailer, check: token.check)
        } else if let audio {
            body.append(audio.bytes); body.append(trailer); request.httpBody = body
        }
        // Scribe took 19.6 s for 20 minutes (trial 2026-11-01); a long meeting gets up to 30 minutes.
        if case .meeting = source { request.timeoutInterval = 1_800 } else { request.timeoutInterval = 90 }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return (request, bodyFile)
    }
    /// Writes head, file and trailer into a new owner-only file in `uploadFolder`.
    nonisolated private static func writeBody(head: Data, file: URL, size: Int, trailer: Data, check: () throws -> Void) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: uploadFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let body = uploadFolder.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        guard manager.createFile(atPath: body.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SpeechToolsError.invalidRecording }
        do {
            let output = try FileHandle(forWritingTo: body); defer { try? output.close() }
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            try output.write(contentsOf: head)
            var copied = 0
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try check()
                copied += chunk.count
                guard copied <= size else { throw SpeechToolsError.recordingTooLarge }
                try output.write(contentsOf: chunk)
            }
            guard copied > 0 else { throw SpeechToolsError.invalidRecording }
            try output.write(contentsOf: trailer)
            return body
        } catch {
            try? manager.removeItem(at: body)
            if let safe = error as? SpeechToolsError { throw safe }
            if error is CancellationError { throw error }
            throw SpeechToolsError.invalidRecording
        }
    }
}

/// A response body with a size limit, filled from a network callback.
final class SpeechToolsBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var bytes = Data()
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
    func append(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard data.count <= maximumBytes - bytes.count else { throw ProviderNetworkError.overflow }
        bytes.append(data)
    }
    func data() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

/// Reads a local recording as mono 24 kHz PCM16 for mixing under a dub. Nothing is uploaded.
enum RecordingAudioDecoder {
    /// Writes a recording as mono 24 kHz PCM16 to `url` in blocks, so a long file never sits in
    /// memory whole. The file is created readable only by the user.
    static func writeTrack(_ source: RecordingSource, to url: URL, maximumSeconds: Double) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SpeechToolsError.invalidRecording
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let fileURL: URL
        switch source {
        case .memory(let wav):
            try handle.write(contentsOf: SpeechToolsWAV.decode(wav, maximumBytes: Int(maximumSeconds) * 48_000)); return
        case .file(let value), .meeting(let value): fileURL = value
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: fileURL) } catch { throw SpeechToolsError.invalidRecording }
        let input = file.processingFormat
        guard Double(file.length) / input.sampleRate <= maximumSeconds + 1 else { throw SpeechToolsError.recordingTooLong }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { throw SpeechToolsError.invalidRecording }
        let block = AVAudioFrameCount(input.sampleRate * 10)
        var finished = false
        while !finished {
            guard let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: block) else { throw SpeechToolsError.invalidRecording }
            do { try file.read(into: source, frameCount: block) } catch { throw SpeechToolsError.invalidRecording }
            let last = source.frameLength == 0 || file.framePosition >= file.length
            guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * 24_000 / input.sampleRate) + 4_800)
            else { throw SpeechToolsError.invalidRecording }
            var supplied = false, failure: NSError?
            let status = converter.convert(to: target, error: &failure) { _, state in
                if supplied || source.frameLength == 0 { state.pointee = last ? .endOfStream : .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return source
            }
            guard status != .error, failure == nil else { throw SpeechToolsError.invalidRecording }
            if target.frameLength > 0, let channel = target.floatChannelData?[0] {
                try handle.write(contentsOf: PCM16.encode(Array(UnsafeBufferPointer(start: channel, count: Int(target.frameLength)))))
            }
            finished = last
        }
    }

    static func pcm24k(_ source: RecordingSource, maximumSeconds: Double) throws -> Data {
        let url: URL
        switch source {
        case .memory(let wav):
            // In-app recordings are already canonical 24 kHz mono PCM16.
            return try SpeechToolsWAV.decode(wav, maximumBytes: Int(maximumSeconds) * 48_000)
        case .file(let fileURL), .meeting(let fileURL): url = fileURL
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw SpeechToolsError.invalidRecording }
        let input = file.processingFormat
        guard Double(file.length) / input.sampleRate <= maximumSeconds + 1 else { throw SpeechToolsError.dubTooLong }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output),
              let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(file.length)),
              let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(file.length) * 24_000 / input.sampleRate) + 4_800)
        else { throw SpeechToolsError.invalidRecording }
        do { try file.read(into: source) } catch { throw SpeechToolsError.invalidRecording }
        var supplied = false, failure: NSError?
        let status = converter.convert(to: target, error: &failure) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        guard status != .error, let channel = target.floatChannelData?[0] else { throw SpeechToolsError.invalidRecording }
        return PCM16.encode(Array(UnsafeBufferPointer(start: channel, count: Int(target.frameLength))))
    }
}
