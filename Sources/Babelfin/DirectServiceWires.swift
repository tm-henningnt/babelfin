import Foundation
import BridgeCore

/// Gemini Live Translate over the Live API WebSocket. The key travels in a header, never in the
/// URL. Input is 16 kHz PCM16, so Babelfin's 24 kHz capture is resampled; output is 24 kHz.
/// https://ai.google.dev/gemini-api/docs/live-api/live-translate
final class GeminiRealtimeWire: RealtimeTranslationWire, @unchecked Sendable {
    static let endpoint = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
    static let model = "models/gemini-3.5-live-translate-preview"
    let service = ProviderService.gemini
    let waitsForCreated = false
    let closing: String? = #"{"realtimeInput":{"audioStreamEnd":true}}"#
    let confirmsClose = false
    private let resampler = Downsampler24To16()

    func request(credential: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.setValue(credential, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 20
        return request
    }
    func opening(_ configuration: TranslationConfiguration) throws -> [String] {
        guard configuration.sourceLanguage == nil else {
            throw BridgeError.unavailable("Gemini detects the input language; choose Automatic.")
        }
        guard TranslationLanguage.geminiLanguages.contains(where: { $0.code == configuration.targetLanguage }) else { throw BridgeError.unsupportedLanguage }
        let setup: [String: Any] = ["setup": [
            "model": Self.model,
            "generationConfig": ["responseModalities": ["AUDIO"], "translationConfig": ["targetLanguageCode": configuration.targetLanguage]],
            "inputAudioTranscription": [String: Any](), "outputAudioTranscription": [String: Any]()]]
        return [try Self.json(setup)]
    }
    func update(_ configuration: TranslationConfiguration) throws -> String? { nil }
    func append(_ pcm: Data) throws -> String {
        let audio = resampler.process(pcm)
        return try Self.json(["realtimeInput": ["audio": ["data": audio.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }
    func decode(_ data: Data) throws -> [TranslationEnvelope] {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.invalidEvent }
        var events: [TranslationEvent] = []
        if message["setupComplete"] != nil { events.append(.updated) }
        if message["goAway"] != nil { events.append(.failure("session_expired")) }
        if let content = message["serverContent"] as? [String: Any] {
            for part in ((content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [] {
                if let encoded = (part["inlineData"] as? [String: Any])?["data"] as? String, let pcm = Data(base64Encoded: encoded), !pcm.isEmpty {
                    guard pcm.count % 2 == 0 else { throw BridgeError.invalidPCM }
                    events.append(.audio(pcm))
                }
            }
            if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String, !text.isEmpty { events.append(.sourceTranscript(text)) }
            if let text = (content["outputTranscription"] as? [String: Any])?["text"] as? String, !text.isEmpty { events.append(.targetTranscript(text)) }
        }
        return events.map { TranslationEnvelope(event: $0, timing: TranslationTiming()) }
    }
    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}

/// Palabra speech-to-speech over WebSocket. The API key is part of the connection URL, as the
/// service requires; the URL is never logged. Input and output are 24 kHz PCM16.
/// https://docs.palabra.ai/docs/streaming_api, protocol from the official Python SDK.
final class PalabraRealtimeWire: RealtimeTranslationWire, @unchecked Sendable {
    let service = ProviderService.palabra
    let waitsForCreated = false
    let closing: String? = #"{"message_type":"end_task","data":{"force":false}}"#
    let confirmsClose = false

    func request(credential: String) -> URLRequest {
        var components = URLComponents()
        components.scheme = "wss"; components.host = "streaming.palabra.ai"
        let session = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        components.path = "/streaming-api/\(session)/v1/speech-to-speech/stream"
        components.queryItems = [URLQueryItem(name: "token", value: credential)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        return request
    }
    func opening(_ configuration: TranslationConfiguration) throws -> [String] {
        let source = configuration.sourceLanguage ?? "auto"
        guard source == "auto" || TranslationLanguage.palabraInputs.contains(where: { $0.code == source }) else { throw BridgeError.unsupportedLanguage }
        guard TranslationLanguage.palabraOutputs.contains(where: { $0.code == configuration.targetLanguage }) else { throw BridgeError.unsupportedLanguage }
        let task: [String: Any] = [
            "input_stream": ["content_type": "audio", "source": ["type": "ws", "format": "pcm_s16le", "sample_rate": 24_000, "channels": 1]],
            "output_stream": ["content_type": "audio", "target": ["type": "ws", "format": "pcm_s16le"]],
            "pipeline": [
                "transcription": ["source_language": source],
                "translations": [["target_language": configuration.targetLanguage, "speech_generation": ["voice_id": "default_high"]]],
                "allowed_message_types": ["translated_transcription", "partial_transcription", "validated_transcription"]]]
        return [try Self.json(["message_type": "set_task", "data": task])]
    }
    func update(_ configuration: TranslationConfiguration) throws -> String? { nil }
    func append(_ pcm: Data) throws -> String {
        try Self.json(["message_type": "input_audio_data", "data": ["data": pcm.base64EncodedString()]])
    }
    func decode(_ data: Data) throws -> [TranslationEnvelope] {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = message["message_type"] as? String else {
            throw BridgeError.invalidEvent
        }
        // The data field is an object, or the same object encoded as a JSON string.
        var payload = message["data"]
        if let text = payload as? String, let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { payload = nested }
        let body = payload as? [String: Any] ?? [:]
        let event: TranslationEvent?
        switch kind {
        case "task_status":
            event = ["started", "resumed", "updated"].contains(body["event"] as? String ?? "") ? .updated : nil
        case "output_audio_data":
            guard let encoded = (body["data"] as? String) ?? (payload as? String), let pcm = Data(base64Encoded: encoded), pcm.count % 2 == 0 else { throw BridgeError.invalidPCM }
            event = pcm.isEmpty ? nil : .audio(pcm)
        case "validated_transcription", "translated_transcription":
            let transcription = body["transcription"] as? [String: Any] ?? [:]
            guard let text = transcription["text"] as? String, !text.isEmpty else { event = nil; break }
            let id = "palabra-" + String((transcription["transcription_id"] as? String ?? UUID().uuidString).prefix(120))
            let segment = TranscriptSegment(id: id, text: text, isFinal: true, language: transcription["language"] as? String)
            event = .segment(segment, role: kind == "validated_transcription" ? .source : .target)
        case "error": event = .failure("translation_service_error")
        case "end_of_stream": event = .closed
        default: event = nil
        }
        return event.map { [TranslationEnvelope(event: $0, timing: TranslationTiming())] } ?? []
    }
    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}

/// 24 kHz to 16 kHz PCM16 for speech: two output samples per three input samples, with a light
/// three-tap low-pass before decimation. It keeps the remainder between calls.
final class Downsampler24To16: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int16] = []
    private var previous: Int16 = 0
    func process(_ pcm: Data) -> Data {
        lock.withLock {
            pcm.withUnsafeBytes { raw in pending.append(contentsOf: raw.bindMemory(to: Int16.self)) }
            var output: [Int16] = []
            output.reserveCapacity(pending.count * 2 / 3 + 2)
            var index = 0
            func filtered(_ i: Int) -> Int16 {
                let before = i == 0 ? previous : pending[i - 1], after = i + 1 < pending.count ? pending[i + 1] : pending[i]
                return Int16((Int(before) + 2 * Int(pending[i]) + Int(after)) / 4)
            }
            while index + 3 <= pending.count {
                output.append(filtered(index))
                let mid = (Int(filtered(index + 1)) + Int(filtered(index + 2))) / 2
                output.append(Int16(mid))
                index += 3
            }
            if index > 0 { previous = pending[index - 1] }
            pending.removeFirst(index)
            return output.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }
}
