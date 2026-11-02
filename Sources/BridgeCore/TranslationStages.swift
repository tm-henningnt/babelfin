import Foundation

/// Closed diagnostic values cross the stage boundary; raw provider errors never do.
public enum TranslationFailureReason: Equatable, Sendable {
    case httpStatus(Int), invalidRequest, invalidResponse, transport, overflow, busy, cancelled, timedOut, unknown
    public init(error: Error) {
        if let diagnosed = error as? any TranslationFailureDiagnosing {
            let reason = diagnosed.translationFailureReason
            if case .httpStatus(let status) = reason, !(100...599).contains(status) { self = .invalidResponse }
            else { self = reason }
        } else if error is CancellationError { self = .cancelled }
        else if let bridge = error as? BridgeError {
            switch bridge {
            case .timedOut: self = .timedOut
            case .invalidPCM, .invalidEvent: self = .invalidResponse
            default: self = .unknown
            }
        } else { self = .unknown }
    }
    public var isTransient: Bool {
        switch self {
        case .transport, .timedOut: return true
        case .httpStatus(let status): return (500...599).contains(status)
        default: return false
        }
    }
    public var safeSummary: String {
        switch self {
        case .httpStatus(let status):
            guard (100...599).contains(status) else { return "The service returned an unsupported response." }
            let action: String
            switch status {
            case 401: action = "Check that the saved API key is valid and has permission for this action."
            case 402: action = "Check the account balance and billing."
            case 403: action = "Check the key permissions and account access."
            case 404: action = "Check model or voice availability for this account."
            case 429: action = "Check usage limits and account balance before retrying."
            default: action = "Check service access and request settings."
            }
            return "The service rejected the request (HTTP \(status)). \(action)"
        case .invalidRequest: return "The request settings are invalid. Check the selected language and voice."
        case .invalidResponse: return "The service returned an unsupported response."
        case .transport: return "The service connection failed. Check your network."
        case .overflow: return "The service stream exceeded its buffer limit."
        case .busy: return "A service operation is already running."
        case .cancelled: return "The service operation was cancelled."
        case .timedOut: return "The service operation timed out."
        case .unknown: return "The service operation could not finish. Check service access and network."
        }
    }
}
public protocol TranslationFailureDiagnosing: Error {
    var translationFailureReason: TranslationFailureReason { get }
}

public enum TranscriptRole: String, Codable, Sendable { case source, target }
public enum TranscriptTimingReference: String, Codable, Sendable { case unknown, sourceAudio, outputAudio }

/// Segment times are optional offsets in the stated audio timeline, never fabricated arrival times.
/// A target segment may retain its sourceAudio anchor; that is not a playback timestamp.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let id: String
    public let revision: Int
    public let text: String
    public let isFinal: Bool
    public let language: String?
    public let startSeconds: Double?
    public let endSeconds: Double?
    public let speaker: String?
    public let timingReference: TranscriptTimingReference
    public init(id: String, revision: Int = 0, text: String, isFinal: Bool = false, language: String? = nil,
                startSeconds: Double? = nil, endSeconds: Double? = nil, speaker: String? = nil,
                timingReference: TranscriptTimingReference = .unknown) {
        self.id = id; self.revision = revision; self.text = text; self.isFinal = isFinal; self.language = language
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.speaker = speaker
        self.timingReference = timingReference
    }
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 256, revision >= 0, text.utf8.count <= 80_000,
              language.map({ $0.utf8.count <= 128 }) ?? true,
              speaker.map({ $0.utf8.count <= 256 }) ?? true,
              startSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              endSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw BridgeError.invalidEvent }
        if let startSeconds, let endSeconds, endSeconds < startSeconds { throw BridgeError.invalidEvent }
    }
}
public enum RecognitionEvent: Sendable { case segment(TranscriptSegment), failure(String), closed }
public typealias RecognitionEventHandler = @MainActor @Sendable (RecognitionEvent) async -> Void

@MainActor public protocol StreamingSpeechRecognizer: AnyObject, Sendable {
    var onEvent: RecognitionEventHandler? { get set }
    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws
    nonisolated func append(_ pcm: Data) throws
    func stopInput()
    /// Completes only after accepted input and the last committed transcript have been delivered.
    func finish() async throws
    func cancel()
    /// Applies a new Delay to the passages that follow. Settings the service fixes at connect stay.
    func updatePacing(_ pacing: TranslationPacing)
}
public extension StreamingSpeechRecognizer {
    func updatePacing(_ pacing: TranslationPacing) {}
}
@MainActor public protocol TextTranslationStage: AnyObject, Sendable {
    func translate(text: String, sourceLanguage: String?, targetLanguage: String, credentials: ProviderCredentials) async throws -> String
    func cancel()
    /// Requests the stage runs at once. Above one, waiting passages are translated as they arrive.
    var maximumConcurrentRequests: Int { get }
    /// Translates and appends the text to `progress` as it arrives; returns the whole translation.
    func translate(text: String, sourceLanguage: String?, targetLanguage: String, credentials: ProviderCredentials,
                   into progress: StreamingTranslation) async throws -> String
}
extension TextTranslationStage {
    public var maximumConcurrentRequests: Int { 1 }
    /// Translates and appends the text to `progress` as it arrives; returns the whole translation.
    /// A stage that cannot stream appends the whole translation at once.
    public func translate(text: String, sourceLanguage: String?, targetLanguage: String, credentials: ProviderCredentials,
                          into progress: StreamingTranslation) async throws -> String {
        let translated = try await translate(text: text, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, credentials: credentials)
        progress.append(translated)
        return translated
    }
}
@MainActor public protocol SpeechSynthesisStage: AnyObject, Sendable {
    /// Output is ordered mono24kHz PCM16; await the sink for backpressure and honor cancellation.
    func synthesize(text: String, language: String, voiceID: String?, credentials: ProviderCredentials,
                    onAudio: @escaping TranslationAudioHandler) async throws
    func cancel()
    /// Requests a speaking rate for the next synthesis. Returns true when the service applies
    /// it natively; otherwise the caller time-stretches the returned audio.
    func prepareSpeakingRate(_ rate: Double) -> Bool
    /// Speaks a voice clip as directed. The default ignores the direction.
    func synthesize(text: String, language: String, voiceID: String?, direction: SpeechDirection,
                    credentials: ProviderCredentials, onAudio: @escaping TranslationAudioHandler) async throws
}
public extension SpeechSynthesisStage {
    func prepareSpeakingRate(_ rate: Double) -> Bool { false }
    func synthesize(text: String, language: String, voiceID: String?, direction: SpeechDirection,
                    credentials: ProviderCredentials, onAudio: @escaping TranslationAudioHandler) async throws {
        try await synthesize(text: text, language: language, voiceID: voiceID, credentials: credentials, onAudio: onAudio)
    }
}

/// How a voice clip is spoken. Only voice clips use it; live translation keeps each service's defaults.
public struct SpeechDirection: Equatable, Sendable {
    public enum Delivery: String, CaseIterable, Sendable {
        case steady, natural, expressive
        public var displayName: String { rawValue.capitalized }
    }
    public static let speeds: ClosedRange<Double> = 0.7...1.2
    public static let standard = SpeechDirection()
    public var delivery: Delivery
    /// Speaking rate. ElevenLabs and Fish Audio both accept 0.7 to 1.2.
    public var speed: Double
    public init(delivery: Delivery = .natural, speed: Double = 1) {
        self.delivery = delivery
        self.speed = speed.isFinite ? min(Self.speeds.upperBound, max(Self.speeds.lowerBound, speed)) : 1
    }
}

/// Stores revision/finality metadata, not full meeting text. Once committed, a segment may
/// update the transcript but must never enqueue speech a second time.
public struct TranscriptRevisionLedger: Sendable {
    public enum Change: Equatable, Sendable { case ignored, partial, committed, correctedCommit }
    private var entries: [String: (revision: Int, committed: Bool)] = [:]
    private let maximumSegments: Int
    public init(maximumSegments: Int = 10_000) { self.maximumSegments = maximumSegments }
    public mutating func accept(_ segment: TranscriptSegment) throws -> Change {
        try segment.validate()
        if let old = entries[segment.id] {
            guard segment.revision > old.revision else { return .ignored }
            guard !old.committed || segment.isFinal else { return .ignored }
            entries[segment.id] = (segment.revision, old.committed || segment.isFinal)
            if old.committed { return .correctedCommit }
        } else {
            guard entries.count < maximumSegments else { throw BridgeError.unavailable("Transcript segment limit reached. Start a new session.") }
            entries[segment.id] = (segment.revision, segment.isFinal)
        }
        return segment.isFinal ? .committed : .partial
    }
}

public extension StreamingSpeechRecognizer {
    func stopInput() { cancel() }
}
