import Foundation

/// One capability of one service. A route is either one direct stage, or a chain of
/// recognition, text translation and synthesis stages.
public struct StageDescriptor: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable { case direct, recognition, translation, synthesis }
    public let id: String
    public let kind: Kind
    /// The account the stage uses. Nil for a stage that needs no account, such as a local server.
    public let service: ProviderService?
    public let displayName: String
    public let modelID: String
    /// Languages the stage accepts. Nil means any language that the previous stage produces.
    public let inputLanguages: [TranslationLanguage]?
    /// Languages the stage produces. Nil means the language it receives, or any requested target.
    public let outputLanguages: [TranslationLanguage]?
    /// The stage detects the input language when no hint is given.
    public let detectsLanguage: Bool
    /// The stage accepts a language hint for its input.
    public let acceptsLanguageHint: Bool
    /// A synthesis stage applies a speaking rate itself.
    public let nativeSpeakingRate: Bool
    /// A recognition stage labels speakers live.
    public let liveSpeakerLabels: Bool
    public init(id: String, kind: Kind, service: ProviderService?, displayName: String, modelID: String,
                inputLanguages: [TranslationLanguage]?, outputLanguages: [TranslationLanguage]?,
                detectsLanguage: Bool = false, acceptsLanguageHint: Bool = false, nativeSpeakingRate: Bool = false,
                liveSpeakerLabels: Bool = false) {
        self.id = id; self.kind = kind; self.service = service; self.displayName = displayName; self.modelID = modelID
        self.inputLanguages = inputLanguages; self.outputLanguages = outputLanguages
        self.detectsLanguage = detectsLanguage; self.acceptsLanguageHint = acceptsLanguageHint
        self.nativeSpeakingRate = nativeSpeakingRate; self.liveSpeakerLabels = liveSpeakerLabels
    }
}

/// A route that a direction can use: one direct stage, or a recognition → translation → synthesis chain.
public struct RouteDescriptor: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let stages: [StageDescriptor]
    public init(id: String, displayName: String, stages: [StageDescriptor]) throws {
        let kinds = stages.map(\.kind)
        guard kinds == [.direct] || kinds == [.recognition, .translation, .synthesis] else {
            throw BridgeError.unavailable("A route needs one direct stage or a recognition, translation and synthesis chain.")
        }
        self.id = id; self.displayName = displayName; self.stages = stages
    }
    public var isDirect: Bool { stages.count == 1 }
    public var services: Set<ProviderService> { Set(stages.compactMap(\.service)) }
    /// Languages the user can choose as input. Empty means automatic detection only.
    public var inputLanguages: [TranslationLanguage] { stages[0].inputLanguages ?? [] }
    /// Languages the route can speak: each stage's outputs, narrowed by the stages after it.
    public var outputLanguages: [TranslationLanguage] {
        guard let first = stages.last?.outputLanguages ?? stages.last?.inputLanguages else { return [] }
        let codes = stages.dropLast().compactMap { $0.kind == .translation ? $0.outputLanguages.map { Set($0.map(\.code)) } : nil }
        return first.filter { language in codes.allSatisfy { $0.contains(language.code) } }
    }
    public var acceptsLanguageHint: Bool { stages[0].acceptsLanguageHint }
    public var nativeSpeakingRate: Bool { stages.last?.nativeSpeakingRate ?? false }
    /// The route can label speakers and give each one a voice.
    public var liveSpeakerLabels: Bool { !isDirect && stages[0].liveSpeakerLabels && stages.last?.service != nil }
    /// The account whose voices the route speaks with. Nil for a direct route.
    public var speechService: ProviderService? { isDirect ? nil : stages.last?.service }
}

public enum ProviderRegistry {
    public static let openAIRealtime = StageDescriptor(
        id: "openai-realtime-translate", kind: .direct, service: .openAI, displayName: "OpenAI realtime translation",
        modelID: "gpt-realtime-translate", inputLanguages: nil,
        outputLanguages: SupportedTargetLanguage.allCases.map { TranslationLanguage(code: $0.rawValue, name: $0.name) },
        detectsLanguage: true)
    public static let elevenLabsScribe = StageDescriptor(
        id: "elevenlabs-scribe-realtime", kind: .recognition, service: .elevenLabs, displayName: "ElevenLabs Scribe",
        modelID: "scribe_v2_realtime", inputLanguages: TranslationLanguage.elevenLabsOutputs, outputLanguages: nil,
        detectsLanguage: true, acceptsLanguageHint: true)
    /// OpenAI live transcription. It has no server turn detection, so the recognizer commits each passage.
    public static let openAILiveTranscribe = StageDescriptor(
        id: "openai-live-transcribe", kind: .recognition, service: .openAI, displayName: "OpenAI live transcription",
        modelID: "gpt-live-transcribe", inputLanguages: TranslationLanguage.openAILiveTranscribeInputs, outputLanguages: nil,
        detectsLanguage: true, acceptsLanguageHint: true)
    /// Fish Audio realtime recognition. Fish detects the language; it has no language hint.
    public static let fishLiveTranscribe = StageDescriptor(
        id: "fish-asr-realtime", kind: .recognition, service: .fish, displayName: "Fish Audio recognition",
        modelID: "transcribe-stream-1", inputLanguages: TranslationLanguage.fishRecognitionInputs, outputLanguages: nil,
        detectsLanguage: true, acceptsLanguageHint: true, liveSpeakerLabels: true)
    public static let openAIText = StageDescriptor(
        id: "openai-text", kind: .translation, service: .openAI, displayName: "OpenAI text translation",
        modelID: "gpt-5.6-luna", inputLanguages: nil, outputLanguages: nil)
    public static let elevenLabsSpeech = StageDescriptor(
        id: "elevenlabs-tts", kind: .synthesis, service: .elevenLabs, displayName: "ElevenLabs speech",
        modelID: "eleven_v4_turbo", inputLanguages: TranslationLanguage.elevenLabsOutputs, outputLanguages: TranslationLanguage.elevenLabsOutputs)
    public static let fishSpeech = StageDescriptor(
        id: "fish-tts", kind: .synthesis, service: .fish, displayName: "Fish Audio speech",
        modelID: "s2.1-pro", inputLanguages: TranslationLanguage.composedOutputs, outputLanguages: TranslationLanguage.composedOutputs,
        nativeSpeakingRate: true)

    public static let geminiLive = StageDescriptor(
        id: "gemini-live-translate", kind: .direct, service: .gemini, displayName: "Gemini Live Translate",
        modelID: "gemini-3.5-live-translate-preview", inputLanguages: nil, outputLanguages: TranslationLanguage.geminiLanguages,
        detectsLanguage: true)
    public static let palabraLive = StageDescriptor(
        id: "palabra-speech-to-speech", kind: .direct, service: .palabra, displayName: "Palabra speech translation",
        modelID: "palabra-speech-to-speech", inputLanguages: TranslationLanguage.palabraInputs, outputLanguages: TranslationLanguage.palabraOutputs,
        detectsLanguage: true, acceptsLanguageHint: true)

    public static let azureInterpreter = StageDescriptor(
        id: "azure-live-interpreter", kind: .direct, service: .azure, displayName: "Azure Live Interpreter",
        modelID: "live-interpreter", inputLanguages: nil, outputLanguages: TranslationLanguage.azureOutputs,
        detectsLanguage: true)

    /// A user-configured OpenAI-compatible text translation server.
    public static let serverText = StageDescriptor(
        id: "server-text", kind: .translation, service: nil, displayName: "your translation server",
        modelID: "server model", inputLanguages: nil, outputLanguages: nil)

    /// Languages of Apple's on-device frameworks on this Mac. The app loads them at launch on
    /// macOS 26 and later; nil keeps the on-device route hidden.
    public struct LocalLanguages: Sendable, Equatable {
        public let recognition: [TranslationLanguage]
        public let translation: [TranslationLanguage]
        public let speech: [TranslationLanguage]
        public init(recognition: [TranslationLanguage], translation: [TranslationLanguage], speech: [TranslationLanguage]) {
            self.recognition = recognition; self.translation = translation; self.speech = speech
        }
    }
    public static var localLanguages: LocalLanguages? {
        get { state.localLanguages }
        set { state.localLanguages = newValue }
    }
    /// On-device stages need no account. Recognition needs a chosen input language.
    public static var appleRecognition: StageDescriptor {
        StageDescriptor(id: "apple-speech-recognition", kind: .recognition, service: nil, displayName: "Apple speech recognition",
                        modelID: "SpeechAnalyzer", inputLanguages: localLanguages?.recognition ?? [], outputLanguages: nil,
                        acceptsLanguageHint: true)
    }
    public static var appleTranslation: StageDescriptor {
        StageDescriptor(id: "apple-translation", kind: .translation, service: nil, displayName: "Apple Translation",
                        modelID: "Translation", inputLanguages: nil, outputLanguages: localLanguages?.translation ?? [])
    }
    public static var appleSpeech: StageDescriptor {
        StageDescriptor(id: "apple-speech-voices", kind: .synthesis, service: nil, displayName: "a system voice",
                        modelID: "AVSpeechSynthesizer", inputLanguages: nil, outputLanguages: localLanguages?.speech ?? [],
                        nativeSpeakingRate: true)
    }
    private static var localRoute: RouteDescriptor {
        try! RouteDescriptor(id: "apple-local", displayName: "On this Mac", stages: [appleRecognition, appleTranslation, appleSpeech])
    }

    public static var stages: [StageDescriptor] {
        [openAIRealtime, geminiLive, palabraLive] + (azureAvailable ? [azureInterpreter] : [])
            + [elevenLabsScribe, openAILiveTranscribe, fishLiveTranscribe, openAIText, elevenLabsSpeech, fishSpeech] + (translationServerAvailable ? [serverText] : [])
            + (localLanguages != nil ? [appleRecognition, appleTranslation, appleSpeech] : [])
    }

    private static let state = RegistryState()
    /// Babelfin offers the server routes while a translation server is saved in Settings.
    public static var translationServerAvailable: Bool {
        get { state.serverAvailable }
        set { state.serverAvailable = newValue }
    }

    /// The app sets this when it was built with Microsoft's Speech SDK.
    public static var azureAvailable: Bool {
        get { state.azureAvailable }
        set { state.azureAvailable = newValue }
    }

    public static var routes: [RouteDescriptor] {
        builtInRoutes + (azureAvailable ? [azureRoute] : []) + (translationServerAvailable ? serverRoutes : [])
            + (localLanguages != nil ? [localRoute] : [])
    }
    private static let azureRoute = try! RouteDescriptor(id: "azure", displayName: "Azure Live Interpreter", stages: [azureInterpreter])

    // The stage lists are fixed and valid, so construction cannot fail.
    private static let serverRoutes: [RouteDescriptor] = [
        try! RouteDescriptor(id: "elevenlabs-server", displayName: "ElevenLabs with your translation server",
                             stages: [elevenLabsScribe, serverText, elevenLabsSpeech]),
        try! RouteDescriptor(id: "fish-server", displayName: "Fish Audio with your translation server",
                             stages: [elevenLabsScribe, serverText, fishSpeech]),
    ]

    private static let builtInRoutes: [RouteDescriptor] = [
        try! RouteDescriptor(id: TranslationRoute.openAI.rawValue, displayName: "OpenAI", stages: [openAIRealtime]),
        try! RouteDescriptor(id: "gemini", displayName: "Gemini", stages: [geminiLive]),
        try! RouteDescriptor(id: "palabra", displayName: "Palabra", stages: [palabraLive]),
        try! RouteDescriptor(id: TranslationRoute.elevenLabs.rawValue, displayName: "ElevenLabs",
                             stages: [elevenLabsScribe, openAIText, elevenLabsSpeech]),
        try! RouteDescriptor(id: TranslationRoute.fish.rawValue, displayName: "Fish Audio",
                             stages: [elevenLabsScribe, openAIText, fishSpeech]),
        // OpenAI recognition: the Fish Audio route then needs no ElevenLabs account.
        try! RouteDescriptor(id: "fish-openai", displayName: "Fish Audio with OpenAI recognition",
                             stages: [openAILiveTranscribe, openAIText, fishSpeech]),
        try! RouteDescriptor(id: "elevenlabs-openai", displayName: "ElevenLabs with OpenAI recognition",
                             stages: [openAILiveTranscribe, openAIText, elevenLabsSpeech]),
        // Fish recognition for the languages Fish documents; Norwegian is not among them.
        try! RouteDescriptor(id: "fish-fish", displayName: "Fish Audio with Fish recognition",
                             stages: [fishLiveTranscribe, openAIText, fishSpeech]),
    ]

    /// Looks up every route the app defines, offered or not, so a route that stops being
    /// offered (a removed server) still describes itself until the user chooses another.
    public static func route(_ route: TranslationRoute) -> RouteDescriptor {
        (builtInRoutes + [azureRoute] + serverRoutes + [localRoute]).first { $0.id == route.rawValue }!
    }
}

private final class RegistryState: @unchecked Sendable {
    private let lock = NSLock(); private var available = false, azure = false
    private var local: ProviderRegistry.LocalLanguages?
    var localLanguages: ProviderRegistry.LocalLanguages? { get { lock.withLock { local } } set { lock.withLock { local = newValue } } }
    var serverAvailable: Bool { get { lock.withLock { available } } set { lock.withLock { available = newValue } } }
    var azureAvailable: Bool { get { lock.withLock { azure } } set { lock.withLock { azure = newValue } } }
}

public extension ProviderService {
    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"; case .elevenLabs: return "ElevenLabs"; case .fish: return "Fish Audio"
        case .gemini: return "Gemini"; case .palabra: return "Palabra"; case .azure: return "Azure"
        }
    }
}

public extension RouteDescriptor {
    /// One sentence for Settings that names each stage's service and the accounts used.
    var explanation: String {
        let names = stages.map { $0.service?.displayName ?? $0.displayName }
        let flow = isDirect ? "\(names[0]) receives your audio and returns translated speech."
            : "\(names[0]) recognizes the audio, \(names[1]) translates the text, and \(names[2]) speaks it."
        guard stages.allSatisfy({ $0.service != nil }) else { return flow }
        switch services.count {
        case 2: return flow + " Both accounts are used."
        case 3: return flow + " All three accounts are used."
        default: return flow
        }
    }
}

public extension ProviderRegistry {
    /// Every language that some route accepts or speaks, by name, for the setup wizard.
    static var allLanguages: [TranslationLanguage] {
        var seen = Set<String>(), result: [TranslationLanguage] = []
        for route in routes { for language in route.inputLanguages + route.outputLanguages where seen.insert(language.code).inserted { result.append(language) } }
        return result.sorted { $0.name < $1.name }
    }
}
