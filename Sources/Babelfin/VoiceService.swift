import Foundation
import BridgeCore

enum VoiceProvider: String, CaseIterable, Identifiable, Sendable {
    case elevenLabs, fish
    var id: String { rawValue }
    var displayName: String { self == .elevenLabs ? "ElevenLabs" : "Fish Audio" }
}
struct ProviderVoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Nil for a system voice on this Mac.
    let provider: VoiceProvider?
    let state: String
    let isReady: Bool
    /// The Babelfin language code of a system voice. Account voices can speak many languages.
    var language: String? = nil
}

/// This service never loads credentials itself and never enrolls a voice implicitly.
@MainActor final class VoiceService {
    private let transport: any ProviderHTTPTransport
    private var operation: ProviderCancellation?
    private var previewStage: (any SpeechSynthesisStage)?
    init(transport: any ProviderHTTPTransport = URLProviderHTTPTransport()) { self.transport = transport }
    func cancel() { operation?.cancel(); transport.cancel(); previewStage?.cancel() }
    private func begin() throws -> ProviderCancellation {
        guard operation == nil else { throw ProviderNetworkError.busy }
        let token = ProviderCancellation(); operation = token; return token
    }
    func list(provider: VoiceProvider, credentials: ProviderCredentials) async throws -> [ProviderVoice] {
        let token = try begin(); defer { operation = nil }
        var voices: [ProviderVoice] = [], pageToken: String?
        for page in 1...5 {
            var components = URLComponents(string: provider == .elevenLabs ? "https://api.elevenlabs.io/v2/voices" : "https://api.fish.audio/model")!
            components.queryItems = provider == .elevenLabs ? [.init(name: "page_size", value: "100")] : [.init(name: "self", value: "true"), .init(name: "page_size", value: "100"), .init(name: "page_number", value: String(page))]
            if let pageToken { components.queryItems?.append(.init(name: "next_page_token", value: pageToken)) }
            var request = URLRequest(url: components.url!); try authorize(&request, provider: provider, credentials: credentials)
            let response = try await transport.json(request)
            try token.check(); try Task.checkCancellation()
            guard let items = response[provider == .elevenLabs ? "voices" : "items"] as? [[String: Any]], items.count <= 200 else { throw ProviderNetworkError.invalidResponse }
            for item in items {
                guard let id = item[provider == .elevenLabs ? "voice_id" : "_id"] as? String,
                      let name = item[provider == .elevenLabs ? "name" : "title"] as? String, name.utf8.count <= 1_024 else { throw ProviderNetworkError.invalidResponse }
                try validateProviderToken(id)
                let state: String
                if provider == .fish {
                    let reported = item["state"] as? String ?? "unknown"
                    state = ["created", "trained", "failed", "training"].contains(reported) ? reported : "unknown"
                } else { state = Self.elevenReadiness(item) }
                if !voices.contains(where: { $0.id == id }) {
                    voices.append(ProviderVoice(id: id, name: name, provider: provider, state: state, isReady: state == "available" || state == "trained"))
                }
            }
            let more: Bool
            if provider == .elevenLabs {
                more = response["has_more"] as? Bool ?? false
                pageToken = response["next_page_token"] as? String
                if more { guard let pageToken, !pageToken.isEmpty, pageToken.utf8.count <= 2_048 else { throw ProviderNetworkError.invalidResponse } }
            } else { more = response["has_more"] as? Bool ?? ((response["total"] as? Int ?? 0) > page * 100) }
            if !more { return voices }
        }
        throw BridgeError.unavailable("This account has too many voices to list. Narrow the account voice library and try again.")
    }
    enum EnrollmentSample: Sendable { case file(URL), recorded(Data) }
    func enroll(provider: VoiceProvider, name: String, sampleURL: URL, consent: Bool, credentials: ProviderCredentials) async throws -> ProviderVoice {
        try await enroll(provider: provider, name: name, sample: .file(sampleURL), consent: consent, credentials: credentials)
    }
    func enroll(provider: VoiceProvider, name: String, sample source: EnrollmentSample, consent: Bool, credentials: ProviderCredentials) async throws -> ProviderVoice {
        guard consent else { throw BridgeError.unavailable("Confirm that you have permission to clone this voice.") }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 80, !cleanName.contains(where: { $0.isNewline }) else { throw ProviderNetworkError.invalidRequest }
        let token = try begin(); defer { operation = nil }
        let sample: (data: Data, ext: String, mime: String)
        switch source {
        case .file(let url): sample = try await Task.detached { try Self.readSample(url) }.value
        case .recorded(let wav):
            guard wav.count > 44, wav.count <= VoiceSampleBuffer.maximumBytes + 44, wav.prefix(4) == Data("RIFF".utf8) else { throw ProviderNetworkError.invalidRequest }
            sample = (wav, "wav", "audio/wav")
        }
        try token.check(); try Task.checkCancellation()
        let boundary = "Babelfin-" + UUID().uuidString
        var body = Data()
        func field(_ key: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if provider == .elevenLabs { field("name", cleanName) }
        else { field("title", cleanName); field("type", "tts"); field("train_mode", "fast"); field("visibility", "private"); field("generate_sample", "false") }
        let fileField = provider == .elevenLabs ? "files" : "voices"
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"sample.\(sample.ext)\"\r\nContent-Type: \(sample.mime)\r\n\r\n".utf8))
        body.append(sample.data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: provider == .elevenLabs ? "https://api.elevenlabs.io/v1/voices/add" : "https://api.fish.audio/model")!)
        request.httpMethod = "POST"; request.httpBody = body; request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        try authorize(&request, provider: provider, credentials: credentials)
        let response = try await transport.json(request, maximumBytes: 65_536)
        try token.check(); try Task.checkCancellation()
        guard let id = response[provider == .elevenLabs ? "voice_id" : "_id"] as? String else { throw ProviderNetworkError.invalidResponse }
        try validateProviderToken(id)
        let state = provider == .elevenLabs ? ((response["requires_verification"] as? Bool ?? false) ? "verification required" : "available") : (response["state"] as? String ?? "created")
        guard ["verification required", "available", "created", "trained", "training", "failed"].contains(state) else { throw ProviderNetworkError.invalidResponse }
        return ProviderVoice(id: id, name: cleanName, provider: provider, state: state, isReady: state == "available" || state == "trained")
    }
    func preview(provider: VoiceProvider, voiceID: String?, text: String, credentials: ProviderCredentials,
                 onAudio: @escaping TranslationAudioHandler) async throws {
        let token = try begin(); defer { operation = nil; previewStage = nil }
        let stage: any SpeechSynthesisStage = provider == .elevenLabs ? ElevenLabsSpeechSynthesisStage(transport: transport) : FishSpeechSynthesisStage(transport: transport)
        previewStage = stage
        try await stage.synthesize(text: text, language: "en", voiceID: voiceID, credentials: credentials, onAudio: onAudio)
        try token.check()
    }
    private static func elevenReadiness(_ item: [String: Any]) -> String {
        if let safety = item["safety_control"] as? String, safety != "NONE" { return "account action required" }
        if let sharing = item["sharing"] as? [String: Any], sharing["status"] as? String == "copied_disabled" { return "unavailable" }
        if let verification = item["voice_verification"] as? [String: Any],
           verification["requires_verification"] as? Bool == true, verification["is_verified"] as? Bool != true { return "verification required" }
        if item["category"] as? String == "professional" {
            let fineTuning = item["fine_tuning"] as? [String: Any]
            let states = fineTuning?["state"] as? [String: String]
            guard states?["eleven_v4_turbo"] == "fine_tuned" else { return "model preparation required" }
        }
        return "available"
    }
    private func authorize(_ request: inout URLRequest, provider: VoiceProvider, credentials: ProviderCredentials) throws {
        if provider == .elevenLabs { request.setValue(try credentials.require(.elevenLabs), forHTTPHeaderField: "xi-api-key") }
        else { request.setValue("Bearer \(try credentials.require(.fish))", forHTTPHeaderField: "Authorization") }
    }
    nonisolated private static func readSample(_ url: URL) throws -> (data: Data, ext: String, mime: String) {
        guard url.isFileURL else { throw ProviderNetworkError.invalidRequest }
        let ext = url.pathExtension.lowercased()
        let types = ["wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4"]
        guard let mime = types[ext] else { throw BridgeError.unavailable("Choose a WAV, MP3 or M4A voice sample.") }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 20 * 1_024 * 1_024 else { throw ProviderNetworkError.invalidRequest }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 20 * 1_024 * 1_024 + 1) ?? Data()
            guard !data.isEmpty, data.count <= 20 * 1_024 * 1_024 else { throw ProviderNetworkError.invalidRequest }
            return (data, ext, mime)
        } catch { throw BridgeError.unavailable("The voice sample could not be read. Choose a regular audio file smaller than 20 MB.") }
    }
}
