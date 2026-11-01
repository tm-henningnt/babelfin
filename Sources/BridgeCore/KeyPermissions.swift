import Foundation

/// A permission that a service grants per API key, and a request that shows whether a key has
/// it. Each probe request is well formed but cannot produce output, so it costs no credits:
/// the service checks the key first and then rejects the request (a missing file, an unknown
/// voice or a missing model). A probe that the service rejects before it checks the key proves
/// nothing, so only the statuses in `KeyProbeClassifier` count as proof.
public struct KeyPermission: Sendable, Identifiable, Equatable {
    public enum Use: Sendable, Equatable { case stage(String), voiceList, voiceCreation, audioTools }
    public let id: String
    public let service: ProviderService
    /// The name that the provider's key settings use.
    public let name: String
    public let uses: [Use]
    public let probe: KeyProbe

    /// Short text for the features that need the permission.
    public var purpose: String {
        var parts: [String] = []
        for use in uses {
            switch use {
            case .stage(let id): if let stage = ProviderRegistry.stages.first(where: { $0.id == id }) { parts.append(stage.displayName) }
            case .voiceList: parts.append("the voice list")
            case .voiceCreation: parts.append("voice creation")
            case .audioTools: parts.append("audio tools")
            }
        }
        return parts.joined(separator: ", ")
    }
}

public struct KeyProbe: Sendable, Equatable {
    public struct Field: Sendable, Equatable { public let name, value: String }
    public enum Body: Sendable, Equatable { case none, json(String), multipart([Field]) }
    public let method: String
    public let url: URL
    public let body: Body
}

public enum KeyCheckOutcome: Codable, Sendable, Equatable {
    case granted
    /// The key lacks the permission. The scope is the service's own name for it, when it gives one.
    case missing(scope: String?)
    case invalidKey
    /// The check gave no proof either way. The text is safe to show.
    case unknown(String)
}

public enum KeyPermissions {
    private static func url(_ string: String) -> URL { URL(string: string)! }
    /// No voice has this ID, so a synthesis or voice edit request stops at "voice not found".
    private static let absentVoice = "zzzzzzzzzzzzzzzzzzzz"

    public static let all: [KeyPermission] = [
        KeyPermission(id: "elevenlabs.speech-to-text", service: .elevenLabs, name: "Speech to Text",
                      uses: [.stage(ProviderRegistry.elevenLabsScribe.id), .audioTools],
                      probe: KeyProbe(method: "POST", url: url("https://api.elevenlabs.io/v1/speech-to-text"),
                                      body: .multipart([.init(name: "model_id", value: "scribe_v1")]))),
        KeyPermission(id: "elevenlabs.text-to-speech", service: .elevenLabs, name: "Text to Speech",
                      uses: [.stage(ProviderRegistry.elevenLabsSpeech.id)],
                      probe: KeyProbe(method: "POST", url: url("https://api.elevenlabs.io/v1/text-to-dialogue/stream?output_format=pcm_24000"),
                                      body: .json(#"{"inputs":[{"text":"a","voice_id":"\#(absentVoice)"}]}"#))),
        KeyPermission(id: "elevenlabs.voices-read", service: .elevenLabs, name: "Voices (Read)",
                      uses: [.stage(ProviderRegistry.elevenLabsSpeech.id), .voiceList],
                      probe: KeyProbe(method: "GET", url: url("https://api.elevenlabs.io/v2/voices?page_size=1"), body: .none)),
        KeyPermission(id: "elevenlabs.voices-write", service: .elevenLabs, name: "Voices (Write)",
                      uses: [.voiceCreation],
                      probe: KeyProbe(method: "POST", url: url("https://api.elevenlabs.io/v1/voices/\(absentVoice)/edit"),
                                      body: .multipart([.init(name: "name", value: "Babelfin key check")]))),
        KeyPermission(id: "openai.realtime", service: .openAI, name: "Realtime",
                      uses: [.stage(ProviderRegistry.openAIRealtime.id), .stage(ProviderRegistry.openAILiveTranscribe.id)],
                      probe: KeyProbe(method: "POST", url: url("https://api.openai.com/v1/realtime/client_secrets"),
                                      body: .json(#"{"session":{"type":"none"}}"#))),
        KeyPermission(id: "openai.responses", service: .openAI, name: "Responses API",
                      uses: [.stage(ProviderRegistry.openAIText.id), .audioTools],
                      probe: KeyProbe(method: "POST", url: url("https://api.openai.com/v1/responses"), body: .json("{}"))),
        KeyPermission(id: "openai.audio", service: .openAI, name: "Model capabilities (Audio)",
                      uses: [.audioTools],
                      probe: KeyProbe(method: "POST", url: url("https://api.openai.com/v1/audio/transcriptions"), body: .multipart([]))),
        KeyPermission(id: "gemini.api", service: .gemini, name: "API access",
                      uses: [.stage(ProviderRegistry.geminiLive.id)],
                      probe: KeyProbe(method: "GET", url: url("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"), body: .none)),
        KeyPermission(id: "fish.api", service: .fish, name: "API access",
                      uses: [.stage(ProviderRegistry.fishSpeech.id), .voiceList, .voiceCreation],
                      probe: KeyProbe(method: "GET", url: url("https://api.fish.audio/model?page_size=1&self=true"), body: .none)),
    ]

    public static func `for`(_ service: ProviderService) -> [KeyPermission] { all.filter { $0.service == service } }

    /// Permissions that the route's stages need.
    public static func needed(by route: RouteDescriptor) -> [KeyPermission] {
        let ids = Set(route.stages.map(\.id))
        return all.filter { $0.uses.contains { if case .stage(let id) = $0 { return ids.contains(id) } else { return false } } }
    }
}

public enum KeyProbeClassifier {
    /// Classifies a probe response. Only the status, and a short service code or scope name
    /// from the body, are used; the body itself never reaches the user.
    public static func classify(service: ProviderService, status: Int, body: Data) -> KeyCheckOutcome {
        let object = (try? JSONSerialization.jsonObject(with: body.prefix(16_384))) as? [String: Any]
        switch status {
        // Google answers a rejected key with 400 INVALID_ARGUMENT, which elsewhere means the request reached the service.
        case 400 where service == .gemini && String(decoding: body.prefix(16_384), as: UTF8.self).contains("API key not valid"): return .invalidKey
        case 200...299, 400, 404: return .granted
        case 429: return .unknown("The service limited requests or the account has no credit. Try again later.")
        case 500...599: return .unknown("The service is unavailable. Try again later.")
        default: break
        }
        switch service {
        case .elevenLabs:
            let detail = object?["detail"] as? [String: Any]
            switch detail?["status"] as? String {
            case "missing_permissions"?:
                return .missing(scope: scope(in: detail?["message"] as? String, after: "missing the permission ", until: " to"))
            case "invalid_api_key"?: return .invalidKey
            case "quota_exceeded"?: return .unknown("The key or account has no credits left.")
            default: if status == 401 { return .unknown("The service refused the key (HTTP 401). Check the key in your ElevenLabs account.") }
            }
        case .openAI:
            let error = object?["error"] as? [String: Any]
            if error?["code"] as? String == "invalid_api_key" { return .invalidKey }
            let message = error?["message"] as? String ?? ""
            if message.contains("Missing scopes:") { return .missing(scope: scope(in: message, after: "Missing scopes: ", until: ". ")) }
            if message.lowercased().contains("insufficient permissions") { return .missing(scope: nil) }
        case .fish:
            if status == 401 || status == 403 { return .invalidKey }
            if status == 402 { return .unknown("The Fish Audio account has no credit.") }
        case .gemini:
            if status == 403 { return .unknown("Google refused the key (HTTP 403). Enable the Gemini API for the key's project.") }
        case .palabra, .azure: break
        }
        if status == 401 { return .invalidKey }
        if status == 403 { return .unknown("The service refused the account (HTTP 403). Check the account and its region.") }
        return .unknown("The service gave an unexpected answer (HTTP \(status)).")
    }

    /// A scope name such as `speech_to_text` or `api.responses.write`: letters, digits, `._`,
    /// commas and spaces only, so the text is safe to show.
    private static func scope(in message: String?, after prefix: String, until suffix: String?) -> String? {
        guard let message, let start = message.range(of: prefix) else { return nil }
        var rest = message[start.upperBound...]
        if let suffix, let end = rest.range(of: suffix) { rest = rest[..<end.lowerBound] }
        let value = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        guard !value.isEmpty, value.count <= 120,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._, ".unicodeScalars.contains($0) }) else { return nil }
        return value
    }
}

/// Sends each permission probe for one saved key. A probe produces no output and costs no
/// credits; see `KeyPermissions`. Response bodies stay in this file: only the classified
/// outcome leaves it.
public enum KeyChecker {
    public static func check(_ service: ProviderService, key: String) async -> KeyCheckReport {
        var outcomes: [String: KeyCheckOutcome] = [:]
        await withTaskGroup(of: (String, KeyCheckOutcome).self) { group in
            for permission in KeyPermissions.for(service) {
                group.addTask { (permission.id, await probe(permission, key: key)) }
            }
            for await (id, outcome) in group { outcomes[id] = outcome }
        }
        return KeyCheckReport(service: service, checkedAt: Date(), outcomes: outcomes)
    }

    private static func probe(_ permission: KeyPermission, key: String) async -> KeyCheckOutcome {
        var request = URLRequest(url: permission.probe.url, timeoutInterval: 15)
        request.httpMethod = permission.probe.method
        switch permission.service {
        case .elevenLabs: request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .openAI, .fish: request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .palabra, .azure: break  // No probe: Palabra's key goes in the URL; Azure's needs the resource endpoint.
        }
        switch permission.probe.body {
        case .none: break
        case .json(let text):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(text.utf8)
        case .multipart(let fields):
            let boundary = "babelfin-" + UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = ""
            for field in fields { body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n" }
            request.httpBody = Data((body + "--\(boundary)--\r\n").utf8)
        }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown("The service gave an unexpected answer.") }
            return KeyProbeClassifier.classify(service: permission.service, status: http.statusCode, body: data)
        } catch {
            return .unknown("The service could not be reached. Check your network.")
        }
    }
}

/// A probe carries a key, so it never follows a redirect.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The latest check of one key. It holds no secret, so Babelfin keeps it in preferences until
/// the key changes.
public struct KeyCheckReport: Codable, Sendable, Equatable {
    public let service: ProviderService
    public let checkedAt: Date
    public let outcomes: [String: KeyCheckOutcome]
    public init(service: ProviderService, checkedAt: Date, outcomes: [String: KeyCheckOutcome]) {
        self.service = service; self.checkedAt = checkedAt; self.outcomes = outcomes
    }
    public var keyRejected: Bool { outcomes.values.contains(.invalidKey) }
    /// Permissions the check proved missing. A rejected key counts as missing every permission.
    public var missing: [KeyPermission] {
        KeyPermissions.for(service).filter { permission in
            switch outcomes[permission.id] { case .missing?, .invalidKey?: return true; default: return false }
        }
    }
}
