import BridgeCore

@MainActor enum ProviderFactory {
    static func make(_ route: TranslationRoute) -> any TranslationProvider {
        switch route {
        case .openAI: return OpenAITranslationProvider()
        case .elevenLabs:
            return ComposedTranslationProvider(recognizer: ElevenLabsSpeechRecognizer(), translator: OpenAITextTranslationStage(), synthesizer: ElevenLabsSpeechSynthesisStage())
        case .fish:
            return ComposedTranslationProvider(recognizer: ElevenLabsSpeechRecognizer(), translator: OpenAITextTranslationStage(), synthesizer: FishSpeechSynthesisStage())
        }
    }
}
