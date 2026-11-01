import Foundation

/// The implemented translation model's documented output choices, not a claim of tested pair quality.
public enum SupportedTargetLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case chinese = "zh", english = "en", french = "fr", german = "de", hindi = "hi"
    case indonesian = "id", italian = "it", japanese = "ja", korean = "ko"
    case portuguese = "pt", russian = "ru", spanish = "es", vietnamese = "vi"
    public var id: String { rawValue }
    public var displayName: String { name }
    public var name: String {
        switch self {
        case .chinese: return "Chinese"
        case .english: return "English"
        case .french: return "French"
        case .german: return "German"
        case .hindi: return "Hindi"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .spanish: return "Spanish"
        case .vietnamese: return "Vietnamese"
        }
    }
}

public struct TranslationLanguage: Codable, Equatable, Sendable, Identifiable {
    public let code: String
    public let name: String
    public var id: String { code }
    public init(code: String, name: String) { self.code = code; self.name = name }
    public static let composedOutputs: [TranslationLanguage] = [
        ("ar", "Arabic"), ("bg", "Bulgarian"), ("zh", "Chinese"), ("hr", "Croatian"),
        ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"), ("en", "English"),
        ("fil", "Filipino"), ("fi", "Finnish"), ("fr", "French"), ("de", "German"),
        ("el", "Greek"), ("hi", "Hindi"), ("hu", "Hungarian"), ("id", "Indonesian"),
        ("it", "Italian"), ("ja", "Japanese"), ("ko", "Korean"), ("ms", "Malay"),
        ("no", "Norwegian"), ("pl", "Polish"), ("pt", "Portuguese"), ("ro", "Romanian"),
        ("ru", "Russian"), ("sk", "Slovak"), ("es", "Spanish"), ("sv", "Swedish"),
        ("ta", "Tamil"), ("tr", "Turkish"), ("uk", "Ukrainian"), ("vi", "Vietnamese")
    ].map { TranslationLanguage(code: $0.0, name: $0.1) }
    // Enumerated v4/v4Turbo model languages, checked2026-10-29.
    // https://elevenlabs.io/docs/overview/models#supported-languages
    // Scribe coverage: https://elevenlabs.io/docs/overview/capabilities/speech-to-text#supported-languages
    public static let elevenLabsOutputs: [TranslationLanguage] = [
        ("af", "Afrikaans"),
        ("ar", "Arabic"),
        ("hy", "Armenian"),
        ("as", "Assamese"),
        ("ast", "Asturian"),
        ("az", "Azerbaijani"),
        ("be", "Belarusian"),
        ("bn", "Bengali"),
        ("bs", "Bosnian"),
        ("bg", "Bulgarian"),
        ("my", "Burmese"),
        ("yue", "Cantonese"),
        ("ca", "Catalan"),
        ("ceb", "Cebuano"),
        ("hr", "Croatian"),
        ("cs", "Czech"),
        ("da", "Danish"),
        ("nl", "Dutch"),
        ("en", "English"),
        ("et", "Estonian"),
        ("fil", "Filipino"),
        ("fi", "Finnish"),
        ("fr", "French"),
        ("gl", "Galician"),
        ("ka", "Georgian"),
        ("de", "German"),
        ("el", "Greek"),
        ("gu", "Gujarati"),
        ("ha", "Hausa"),
        ("he", "Hebrew"),
        ("hi", "Hindi"),
        ("hu", "Hungarian"),
        ("is", "Icelandic"),
        ("id", "Indonesian"),
        ("ga", "Irish"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("jv", "Javanese"),
        ("kn", "Kannada"),
        ("kk", "Kazakh"),
        ("ko", "Korean"),
        ("ky", "Kyrgyz"),
        ("lv", "Latvian"),
        ("ln", "Lingala"),
        ("lt", "Lithuanian"),
        ("lb", "Luxembourgish"),
        ("mk", "Macedonian"),
        ("ms", "Malay"),
        ("ml", "Malayalam"),
        ("mt", "Maltese"),
        ("zh", "Mandarin Chinese"),
        ("mi", "Māori"),
        ("mr", "Marathi"),
        ("mn", "Mongolian"),
        ("ne", "Nepali"),
        ("no", "Norwegian"),
        ("oc", "Occitan"),
        ("or", "Odia"),
        ("ps", "Pashto"),
        ("fa", "Persian"),
        ("pl", "Polish"),
        ("pt", "Portuguese"),
        ("pa", "Punjabi"),
        ("ro", "Romanian"),
        ("ru", "Russian"),
        ("sr", "Serbian"),
        ("sd", "Sindhi"),
        ("sk", "Slovak"),
        ("sl", "Slovenian"),
        ("so", "Somali"),
        ("es", "Spanish"),
        ("sw", "Swahili"),
        ("sv", "Swedish"),
        ("tg", "Tajik"),
        ("ta", "Tamil"),
        ("te", "Telugu"),
        ("th", "Thai"),
        ("tr", "Turkish"),
        ("uk", "Ukrainian"),
        ("ur", "Urdu"),
        ("uz", "Uzbek"),
        ("vi", "Vietnamese"),
        ("cy", "Welsh"),
        ("yo", "Yoruba"),
    ].map { TranslationLanguage(code: $0.0, name: $0.1) }
    public static func name(for code: String) -> String {
        elevenLabsOutputs.first { $0.code == code }?.name ?? composedOutputs.first { $0.code == code }?.name ?? code
    }
}

/// Component documentation establishes selectable coverage, not tested pair/voice quality.
public struct ProviderCapabilities: Sendable {
    public enum SourceLanguageMode: Sendable { case automatic, automaticOrHint }
    public enum VoiceMode: Sendable { case dynamicAdaptation, selectableOrCloned }
    public enum TranscriptMode: Sendable { case appendOnly, revisionedSegments }
    public let providerID: String
    public let providerName: String
    public let modelID: String
    public let sourceLanguageMode: SourceLanguageMode
    public let targetLanguages: [SupportedTargetLanguage]
    public let voiceMode: VoiceMode
    public let transcriptMode: TranscriptMode
    public let requiresNetwork: Bool
    public let requiresAPIKey: Bool
    public let documentationDate: String
    public let userConfirmedOutputLanguages: Set<SupportedTargetLanguage>
    private var registered: RouteDescriptor? { ProviderRegistry.routes.first { $0.id == providerID } }
    public var outputLanguages: [TranslationLanguage] { registered?.outputLanguages ?? [] }
    public var inputLanguages: [TranslationLanguage] { registered?.inputLanguages ?? [] }
    public var requiresVoiceID: Bool { registered?.speechService == .elevenLabs }
    public static func forRoute(_ route: TranslationRoute) -> ProviderCapabilities {
        switch route {
        case .openAI: return .openAITranslation
        case .elevenLabs: return .elevenLabsTranslation
        case .fish: return .fishTranslation
        default:
            // A route without a hand-written record: describe it from its stages.
            let descriptor = route.descriptor
            return ProviderCapabilities(
                providerID: descriptor.id, providerName: descriptor.stages.map { $0.service?.displayName ?? "Your server" }.joined(separator: " + "),
                modelID: descriptor.stages.map(\.modelID).joined(separator: " / "),
                sourceLanguageMode: descriptor.acceptsLanguageHint ? .automaticOrHint : .automatic,
                targetLanguages: SupportedTargetLanguage.allCases,
                voiceMode: descriptor.isDirect ? .dynamicAdaptation : .selectableOrCloned,
                transcriptMode: descriptor.isDirect ? .appendOnly : .revisionedSegments,
                requiresNetwork: true, requiresAPIKey: true, documentationDate: "", userConfirmedOutputLanguages: [])
        }
    }
    public func validate(_ configuration: TranslationConfiguration) throws {
        guard outputLanguages.contains(where: { $0.code == configuration.targetLanguage }) else { throw BridgeError.unsupportedLanguage }
        if requiresVoiceID, configuration.voiceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw BridgeError.unavailable("Choose an ElevenLabs voice before starting.")
        }
    }
    public static let openAITranslation = ProviderCapabilities(
        providerID: "openai", providerName: "OpenAI", modelID: "gpt-realtime-translate",
        sourceLanguageMode: .automatic, targetLanguages: SupportedTargetLanguage.allCases,
        voiceMode: .dynamicAdaptation, transcriptMode: .appendOnly,
        requiresNetwork: true, requiresAPIKey: true, documentationDate: "2026-10-29",
        userConfirmedOutputLanguages: [.english])
    public static let elevenLabsTranslation = ProviderCapabilities(
        providerID: "elevenlabs", providerName: "ElevenLabs + OpenAI", modelID: "scribe_v2_realtime / text translation / eleven_v4_turbo",
        sourceLanguageMode: .automaticOrHint, targetLanguages: SupportedTargetLanguage.allCases,
        voiceMode: .selectableOrCloned, transcriptMode: .revisionedSegments, requiresNetwork: true, requiresAPIKey: true,
        documentationDate: "2026-10-29", userConfirmedOutputLanguages: [])
    public static let fishTranslation = ProviderCapabilities(
        providerID: "fish", providerName: "Fish Audio + ElevenLabs + OpenAI", modelID: "scribe_v2_realtime / text translation / s2.1-pro",
        sourceLanguageMode: .automaticOrHint, targetLanguages: SupportedTargetLanguage.allCases,
        voiceMode: .selectableOrCloned, transcriptMode: .revisionedSegments, requiresNetwork: true, requiresAPIKey: true,
        documentationDate: "2026-10-29", userConfirmedOutputLanguages: [])
}
