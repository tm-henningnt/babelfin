import Foundation
import CoreFoundation

public enum TranslationNoiseReduction: String, Sendable { case disabled, nearField = "near_field", farField = "far_field" }

/// How much speech a composed route collects before it translates. Longer segments give the
/// translator more context; shorter segments keep the translated speech closer to the speaker.
/// A natural pause can end a segment earlier in every mode.
public enum TranslationPacing: String, CaseIterable, Codable, Sendable {
    case fast, balanced, context
    /// A segment ends at the first short pause after this much speech.
    public var minimumSegmentSeconds: Double { switch self { case .fast: 2; case .balanced: 4; case .context: 6 } }
    /// Unbroken speech is cut here.
    public var maximumSegmentSeconds: Double { switch self { case .fast: 5; case .balanced: 8; case .context: 12 } }
    /// After this much speech, a short pause commits the segment when the latest partial transcript
    /// ends a sentence. More context waits for the normal rules.
    public var sentenceCommitSeconds: Double? { switch self { case .fast: 1.2; case .balanced: 1.5; case .context: nil } }
    /// Silence after which the recognition service commits a segment by itself.
    public var commitSilenceSeconds: Double { switch self { case .fast: 0.35; case .balanced: 0.45; case .context: 0.6 } }
    /// The rate controller keeps each segment's speech this long after its commit.
    public var targetLagSeconds: Double { switch self { case .fast: 1; case .balanced: 1.5; case .context: 2.5 } }
    public var displayName: String { switch self { case .fast: "Fast"; case .balanced: "Balanced"; case .context: "More context" } }
}

public struct TranslationConfiguration: Equatable, Sendable {
    public let targetLanguage: String
    public let noiseReduction: TranslationNoiseReduction
    public let route: TranslationRoute
    public let sourceLanguage: String?
    public let voiceID: String?
    public let pacing: TranslationPacing
    /// False for text-only translation: composed routes skip speech synthesis.
    public let speaksTranslation: Bool
    /// Voices for Speaker 1, 2, … on a route whose recognizer labels speakers. Empty turns labels off.
    public let speakerVoices: [String]
    public static let maximumSpeakerVoices = 8
    public init(targetLanguage: String = "en", noiseReduction: TranslationNoiseReduction = .nearField,
                route: TranslationRoute = .openAI, sourceLanguage: String? = nil, voiceID: String? = nil,
                pacing: TranslationPacing = .balanced, speaksTranslation: Bool = true, speakerVoices: [String] = []) {
        self.targetLanguage = targetLanguage
        self.noiseReduction = noiseReduction
        self.route = route; self.sourceLanguage = sourceLanguage; self.voiceID = voiceID; self.pacing = pacing
        self.speaksTranslation = speaksTranslation
        self.speakerVoices = Array(speakerVoices.prefix(Self.maximumSpeakerVoices))
    }
    /// The voice for a speaker label ("1", "2", …): the speaker voices in order, repeating when
    /// there are more speakers than voices. A segment without a label uses `voiceID`.
    public func voice(forSpeaker speaker: String?) -> String? {
        guard let speaker, let number = Int(speaker), number > 0, !speakerVoices.isEmpty else { return voiceID }
        return speakerVoices[(number - 1) % speakerVoices.count]
    }
}

public struct TranslationTiming: Equatable, Sendable {
    public let elapsedMilliseconds: Int?
    public let expiresAt: TimeInterval?
    public init(elapsedMilliseconds: Int? = nil, expiresAt: TimeInterval? = nil) {
        self.elapsedMilliseconds = elapsedMilliseconds; self.expiresAt = expiresAt
    }
}

/// Stage times for one recognized passage in a composed route, in seconds. The clock starts
/// when recognition commits the passage, after the speaker's pause.
public struct PassageTiming: Equatable, Sendable {
    /// Length of the recognized speech, when the recognizer reports it.
    public let passageSeconds: Double?
    /// Text translation request, from start to the translated text.
    public let translateSeconds: Double?
    /// Speech request, from start to its first audio.
    public let voiceSeconds: Double?
    /// Translation and speech ran while the previous passage played.
    public let preparedAhead: Bool
    /// From the commit to the first translated audio handed to playback.
    public let totalSeconds: Double
    public let speechSeconds: Double
    public let rate: Double
    /// System uptime when the first translated audio was handed to playback.
    public let handedOffAt: TimeInterval?
    /// From the hand-off to the first audible sample: the playback buffer, or audio queued ahead.
    public var playbackSeconds: Double?
    public init(passageSeconds: Double?, translateSeconds: Double?, voiceSeconds: Double?, preparedAhead: Bool,
                totalSeconds: Double, speechSeconds: Double, rate: Double, handedOffAt: TimeInterval? = nil, playbackSeconds: Double? = nil) {
        self.passageSeconds = passageSeconds; self.translateSeconds = translateSeconds; self.voiceSeconds = voiceSeconds
        self.preparedAhead = preparedAhead; self.totalSeconds = totalSeconds; self.speechSeconds = speechSeconds; self.rate = rate
        self.handedOffAt = handedOffAt; self.playbackSeconds = playbackSeconds
    }
    /// From the commit to the first audible sample, when the playback start is known.
    public var audibleSeconds: Double? { playbackSeconds.map { totalSeconds + $0 } }
    /// Time spent waiting for the previous passage to finish playing.
    public var waitSeconds: Double {
        preparedAhead ? totalSeconds : max(0, totalSeconds - (translateSeconds ?? 0) - (voiceSeconds ?? 0))
    }
    public enum Stage: String, CaseIterable, Sendable { case translation, voice, waiting }
    /// The parts of `totalSeconds`, in order. A passage prepared ahead only waited: its
    /// translation and speech ran while the previous passage played.
    public var stages: [(stage: Stage, seconds: Double)] {
        if preparedAhead { return [(.waiting, totalSeconds)] }
        return [(.translation, translateSeconds ?? 0), (.voice, voiceSeconds ?? 0), (.waiting, waitSeconds)].filter { $0.seconds > 0 }
    }
}

public struct TranslationEnvelope: Sendable {
    public let event: TranslationEvent
    public let timing: TranslationTiming
    public init(event: TranslationEvent, timing: TranslationTiming) { self.event = event; self.timing = timing }
}

public enum TranslationEvent: Equatable, Sendable {
    case audio(Data)
    case sourceTranscript(String)
    case targetTranscript(String)
    case segment(TranscriptSegment, role: TranscriptRole)
    case created, updated, closed
    case failure(String)
    case timing(TranslationTiming)
    case passage(PassageTiming)
    case notice(String)
    case other
}

/// Providers exchange little-endian PCM16, mono, 24 kHz. No device or UI types cross this seam.
/// A local provider can implement the same interface without credentials or a network connection.
public typealias TranslationAudioHandler = @Sendable (Data) async throws -> Void

public typealias TranslationEventHandler = @MainActor @Sendable (TranslationEvent) async -> Void

@MainActor public protocol TranslationProvider: AnyObject, Sendable {
    var onEvent: TranslationEventHandler? { get set }
    var onAudio: TranslationAudioHandler? { get set }
    func start(configuration: TranslationConfiguration, apiKey: String) async throws
    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws
    func applyLive(_ configuration: TranslationConfiguration) -> Bool
    nonisolated func append(_ pcm: Data) throws
    /// Discard unsent PCM synchronously before optional text-only completion.
    func stopInput()
    func finish() async
    func cancel()
}

public extension TranslationProvider {
    /// Applies a changed configuration to the running session. Returns false when the session
    /// needs a restart for it.
    func applyLive(_ configuration: TranslationConfiguration) -> Bool { false }
    func stopInput() { cancel() }
    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        guard configuration.route == .openAI else { throw BridgeError.unavailable("This adapter only supports the OpenAI translation route.") }
        try await start(configuration: configuration, apiKey: credentials.require(.openAI))
    }
}

public enum TranslationWire {
    public static let endpoint = URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!
    // OpenAI's published target-language list, verified 2026-10-29. Nordic output is not supported yet.
    public static let supportedTargets = Set(SupportedTargetLanguage.allCases.map(\.rawValue))
    public static func update(_ config: TranslationConfiguration) throws -> String {
        guard config.route == .openAI else { throw BridgeError.unavailable("Choose the matching translation provider.") }
        guard config.sourceLanguage == nil, config.voiceID == nil else {
            throw BridgeError.unavailable("OpenAI translation uses automatic source detection and speaker adaptation; source hints and selected voices require a composed route.")
        }
        guard supportedTargets.contains(config.targetLanguage) else { throw BridgeError.unsupportedLanguage }
        let noise: Any = config.noiseReduction == .disabled ? NSNull() : ["type": config.noiseReduction.rawValue]
        return try json(["type": "session.update", "session": ["audio": [
            "input": ["transcription": ["model": "gpt-realtime-whisper"], "noise_reduction": noise],
            "output": ["language": config.targetLanguage]
        ]]])
    }
    public static func append(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count % 2 == 0 else { throw BridgeError.invalidPCM }
        return try json(["type": "session.input_audio_buffer.append", "audio": data.base64EncodedString()])
    }
    public static func decode(_ data: Data) throws -> TranslationEvent {
        try decodeEnvelope(data).event
    }
    public static func decodeEnvelope(_ data: Data) throws -> TranslationEnvelope {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw BridgeError.invalidEvent }
        let elapsed = try integer(object["elapsed_ms"])
        let session = object["session"] as? [String: Any]
        let expires = try integer(session?["expires_at"])
        let timing = TranslationTiming(elapsedMilliseconds: elapsed, expiresAt: expires.map(Double.init))
        return TranslationEnvelope(event: try decodeEvent(object, type: type), timing: timing)
    }
    private static func integer(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded() == number.doubleValue else { throw BridgeError.invalidEvent }
        return number.intValue
    }
    private static func decodeEvent(_ object: [String: Any], type: String) throws -> TranslationEvent {
        switch type {
        case "session.created": return .created
        case "session.updated": return .updated
        case "session.closed": return .closed
        case "session.output_audio.delta":
            guard try integer(object["sample_rate"]) ?? 24_000 == 24_000,
                  try integer(object["channels"]) ?? 1 == 1,
                  object["format"] == nil || object["format"] as? String == "pcm16" else { throw BridgeError.invalidPCM }
            guard let delta = object["delta"] as? String, let pcm = Data(base64Encoded: delta),
                  !pcm.isEmpty, pcm.count % 2 == 0 else { throw BridgeError.invalidPCM }
            return .audio(pcm)
        case "session.input_transcript.delta": return .sourceTranscript(object["delta"] as? String ?? "")
        case "session.output_transcript.delta": return .targetTranscript(object["delta"] as? String ?? "")
        case "error":
            // Server messages can echo user content. Only allow a bounded, non-secret error code out.
            let raw = (object["error"] as? [String: Any])?["code"] as? String ?? "api_error"
            let safe = raw.count < 64 && raw.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? raw : "api_error"
            return .failure(safe)
        default: return .other
        }
    }
    private static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

public enum BridgeError: LocalizedError {
    case unsupportedLanguage, invalidPCM, invalidEvent, unavailable(String), uploadBacklog, playbackBacklog(Double), timedOut
    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: return "This provider does not support that output language."
        case .invalidPCM: return "Invalid PCM audio received."
        case .invalidEvent: return "Invalid translation event received."
        case .unavailable(let detail): return detail
        case .uploadBacklog: return "Audio upload fell behind. Check the network and start again."
        case .playbackBacklog(let seconds): return String(format: "Playback fell behind (%.1f seconds queued). Audio stopped to avoid growing delay.", seconds)
        case .timedOut: return "Translation connection timed out. Check network and API access, then start again."
        }
    }
}

public enum PCM16 {
    public static func encode(_ samples: [Float]) -> Data {
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let value = Int16((max(-1, min(1, finite)) * 32767).rounded())
            let bits = UInt16(bitPattern: value)
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return bytes
    }
    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count % 2 == 0 else { throw BridgeError.invalidPCM }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768
        }
    }
}
