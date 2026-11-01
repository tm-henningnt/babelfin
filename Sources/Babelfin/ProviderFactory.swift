import BridgeCore

/// Builds a route's provider from its registry stages. Every registered stage needs a factory
/// here; a lifecycle check enforces that.
@MainActor enum ProviderFactory {
    static func make(_ route: TranslationRoute) -> any TranslationProvider {
        let stages = route.descriptor.stages
        if route.descriptor.isDirect {
            guard let provider = direct(stages[0].id) else { preconditionFailure("No factory for stage \(stages[0].id)") }
            return provider
        }
        guard let recognizer = recognizer(stages[0].id), let translator = translator(stages[1].id), let synthesizer = synthesizer(stages[2].id) else {
            preconditionFailure("No factory for a stage of route \(route.rawValue)")
        }
        return ComposedTranslationProvider(recognizer: recognizer, translator: translator, synthesizer: synthesizer)
    }
    static func direct(_ id: String) -> (any TranslationProvider)? {
        switch id {
        case ProviderRegistry.openAIRealtime.id: return OpenAITranslationProvider()
        case ProviderRegistry.geminiLive.id: return RealtimeTranslationProvider(wire: GeminiRealtimeWire())
        case ProviderRegistry.palabraLive.id: return RealtimeTranslationProvider(wire: PalabraRealtimeWire())
        #if canImport(MicrosoftCognitiveServicesSpeech)
        case ProviderRegistry.azureInterpreter.id: return AzureInterpreterProvider()
        #endif
        default: return nil
        }
    }
    static func recognizer(_ id: String) -> (any StreamingSpeechRecognizer)? {
        id == ProviderRegistry.elevenLabsScribe.id ? ElevenLabsSpeechRecognizer() : nil
    }
    static func translator(_ id: String) -> (any TextTranslationStage)? {
        switch id {
        case ProviderRegistry.openAIText.id: return OpenAITextTranslationStage()
        case ProviderRegistry.serverText.id:
            guard let endpoint = TranslationServerSettings.load() else { return UnconfiguredTextTranslationStage() }
            return OpenAICompatibleTextTranslationStage(endpoint: endpoint)
        default: return nil
        }
    }
    static func synthesizer(_ id: String) -> (any SpeechSynthesisStage)? {
        switch id {
        case ProviderRegistry.elevenLabsSpeech.id: return ElevenLabsSpeechSynthesisStage()
        case ProviderRegistry.fishSpeech.id: return FishSpeechSynthesisStage()
        default: return nil
        }
    }
}
