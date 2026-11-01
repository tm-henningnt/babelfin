import Foundation
import BridgeCore

/// Current file transcription is text-only. Speaker labels belong to another provider/model contract.
/// https://developers.openai.com/api/docs/guides/speech-to-text
@MainActor final class OpenAIRecordingTranscriber: SpeechToolsTranscriber {
    let requiredServices: Set<ProviderService> = [.openAI]
    private let transport: any ProviderHTTPTransport
    private var operation: ProviderCancellation?
    nonisolated private static let responseBytes = 2 * 1_024 * 1_024

    init(transport: any ProviderHTTPTransport = URLProviderHTTPTransport()) { self.transport = transport }

    func transcribe(source: RecordingSource, sourceLanguage: String?, diarize: Bool,
                    credentials: ProviderCredentials) async throws -> RecordingTranscript {
        guard operation == nil else { throw ProviderNetworkError.busy }
        // gpt-transcribe has no documented diarized_json or speaker-label contract.
        guard !diarize else { throw ProviderNetworkError.invalidRequest }
        if let sourceLanguage {
            try validateProviderToken(sourceLanguage)
            guard sourceLanguage.utf8.count <= 32 else { throw ProviderNetworkError.invalidRequest }
        }
        let key = try credentials.require(.openAI)
        try Task.checkCancellation()
        let token = ProviderCancellation(), transport = self.transport
        operation = token
        defer { operation = nil }
        do {
            return try await withTaskCancellationHandler {
                var request = try await Task.detached {
                    try Self.uploadRequest(source: source, sourceLanguage: sourceLanguage, token: token)
                }.value
                try token.check(); try Task.checkCancellation()
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let response = OpenAIRecordingBuffer(maximumBytes: Self.responseBytes)
                try await transport.stream(request, maximumBytes: Self.responseBytes, contentTypes: ["application/json"]) { bytes in
                    try token.check(); try Task.checkCancellation(); try response.append(bytes)
                }
                try token.check(); try Task.checkCancellation()
                let data = response.data()
                let result = try await Task.detached {
                    try token.check()
                    let transcript = try Self.parse(data, token: token)
                    try token.check()
                    return transcript
                }.value
                try token.check(); try Task.checkCancellation()
                return result
            } onCancel: {
                token.cancel(); transport.cancel()
            }
        } catch {
            do { try token.check() } catch { throw CancellationError() }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? SpeechToolsError { throw safe }
            if let safe = error as? ProviderNetworkError { throw safe }
            // A decoding, filesystem or transport error must not expose a path, body or credential.
            throw ProviderNetworkError.transport
        }
    }

    func cancel() {
        guard let operation else { return }
        operation.cancel(); transport.cancel()
    }

    nonisolated private static func uploadRequest(source: RecordingSource, sourceLanguage: String?,
                                                  token: ProviderCancellation) throws -> URLRequest {
        try token.check()
        let types = ["wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4", "mp4": "video/mp4",
                     "mpeg": "audio/mpeg", "mpga": "audio/mpeg", "webm": "audio/webm",
                     "flac": "audio/flac", "ogg": "audio/ogg"]
        if case .file(let url) = source, url.isFileURL, types[url.pathExtension.lowercased()] == nil { throw SpeechToolsError.unsupportedFormat }
        let audio = try source.upload(check: token.check)
        guard let mime = types[audio.fileExtension] else { throw SpeechToolsError.unsupportedFormat }
        let boundary = "Babelfin-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", "gpt-transcribe")
        if let sourceLanguage { field("languages[]", sourceLanguage) }
        // Omit response_format for the documented default JSON text/languages response.
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.\(audio.fileExtension)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(audio.bytes)
        try token.check()
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 90
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    private struct Response: Decodable {
        struct Language: Decodable { let code: String }
        let text: String
        let languages: [Language]?
    }

    nonisolated private static func parse(_ data: Data, token: ProviderCancellation) throws -> RecordingTranscript {
        guard data.count <= responseBytes else { throw ProviderNetworkError.overflow }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw SpeechToolsError.invalidResponse }
        guard response.text.utf8.count <= SpeechToolsLimits.transcriptBytes else { throw SpeechToolsError.transcriptTooLarge }
        let languages = response.languages ?? []
        guard languages.count <= 100 else { throw SpeechToolsError.invalidResponse }
        for language in languages {
            guard !language.code.isEmpty, language.code.utf8.count <= 32,
                  language.code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                    (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw SpeechToolsError.invalidResponse }
        }
        let detected = Set(languages.map(\.code))
        // The current transcript model has one source-language field. Mixed/unknown remains unknown.
        let sourceLanguage = detected.count == 1 ? detected.first : nil
        let rawChunks: [String]
        do { rawChunks = try SpeechToolsText.chunks(response.text, maximumBytes: SpeechToolsLimits.segmentBytes) }
        catch { throw SpeechToolsError.transcriptTooLarge }
        let chunks = try retainingWhitespace(rawChunks)
        var segments: [RecordingSegment] = []
        for text in chunks {
            try token.check()
            guard segments.count < SpeechToolsLimits.segments else { throw SpeechToolsError.transcriptTooLarge }
            segments.append(RecordingSegment(id: "segment-\(segments.count + 1)", sourceText: text))
        }
        let result = RecordingTranscript(sourceLanguage: sourceLanguage, segments: segments)
        try result.validate()
        return result
    }

    /// RecordingSegment requires speech in every segment. Move a boundary instead of dropping
    /// a whitespace-only tail produced by the generic chunker (for example 3,000 letters + LF).
    nonisolated private static func retainingWhitespace(_ chunks: [String]) throws -> [String] {
        var result = chunks, index = 0
        let limit = SpeechToolsLimits.segmentBytes
        while index < result.count {
            let text = result[index]
            guard text.allSatisfy(\.isWhitespace) else { index += 1; continue }
            if index > 0 {
                let previous = result[index - 1]
                if previous.utf8.count + text.utf8.count <= limit {
                    result[index - 1] += text; result.remove(at: index); continue
                }
                if let boundary = previous.lastIndex(where: { !$0.isWhitespace }) {
                    let head = String(previous[..<boundary]), tail = String(previous[boundary...]) + text
                    if !head.allSatisfy(\.isWhitespace), tail.utf8.count <= limit {
                        result[index - 1] = head; result[index] = tail; index += 1; continue
                    }
                }
            }
            if index + 1 < result.count {
                let next = result[index + 1]
                if text.utf8.count + next.utf8.count <= limit {
                    result[index + 1] = text + next; result.remove(at: index); continue
                }
                if let firstSpeech = next.firstIndex(where: { !$0.isWhitespace }) {
                    let boundary = next.index(after: firstSpeech)
                    let head = text + String(next[..<boundary]), tail = String(next[boundary...])
                    if head.utf8.count <= limit, !tail.allSatisfy(\.isWhitespace) {
                        result[index] = head; result[index + 1] = tail; index += 1; continue
                    }
                }
            }
            // Do not trim or invent speech when a whitespace run cannot fit the transcript model.
            throw SpeechToolsError.invalidResponse
        }
        return result
    }
}

private final class OpenAIRecordingBuffer: @unchecked Sendable {
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
