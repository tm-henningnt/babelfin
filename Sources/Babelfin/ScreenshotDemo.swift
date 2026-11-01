#if BABELFIN_SCREENSHOTS
import CoreAudio
import Foundation
import BridgeCore

/// Private documentation build only: fictional devices, settings and transcript so public
/// screenshots never show the owner's devices, voices or meetings. No audio is started.
@MainActor enum ScreenshotDemo {
    static let devices: [AudioDevice] = [
        AudioDevice(id: 9001, uid: "demo-builtin-mic", name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0, transport: kAudioDeviceTransportTypeBuiltIn),
        AudioDevice(id: 9002, uid: "demo-headphones", name: "Headphones", inputChannels: 0, outputChannels: 2, transport: kAudioDeviceTransportTypeBuiltIn),
        AudioDevice(id: 9003, uid: "demo-BlackHole2ch", name: "BlackHole 2ch", inputChannels: 2, outputChannels: 2, transport: kAudioDeviceTransportTypeVirtual),
        AudioDevice(id: 9004, uid: "demo-BlackHole16ch", name: "BlackHole 16ch", inputChannels: 16, outputChannels: 16, transport: kAudioDeviceTransportTypeVirtual)
    ]
    static func tools() -> SpeechToolsModel {
        let model = SpeechToolsModel(previewDeviceList: { devices }, keyPresence: { _ in true }, credentialVersion: { "demo" },
                                     loadCredentials: { _ in throw BridgeError.unavailable("Demo") })
        model.seedDemoVoiceClip()
        return model
    }
    static func conversation() -> ConversationModel {
        VoiceNameCache.remember([ProviderVoice(id: "demovoice", name: "Kari", provider: .elevenLabs, state: "available", isReady: true)])
        var outgoingPreferences = AppPreferences()
        outgoingPreferences.providerRoute = TranslationRoute.elevenLabs.rawValue
        outgoingPreferences.sourceLanguage = "no"; outgoingPreferences.targetLanguage = "en"
        outgoingPreferences.teams = SavedAudioRoute(input: SavedAudioDevice(uid: "demo-builtin-mic", name: "MacBook Pro Microphone"),
                                                     output: SavedAudioDevice(uid: "demo-BlackHole2ch", name: "BlackHole 2ch"))
        outgoingPreferences.teamsOutputConfigured = true
        outgoingPreferences.voices = [TranslationRoute.elevenLabs.rawValue: "demovoice"]
        var incomingPreferences = AppPreferences()
        incomingPreferences.destination = AudioDestination.listen.rawValue
        incomingPreferences.providerRoute = TranslationRoute.gemini.rawValue
        incomingPreferences.sourceLanguage = "en"; incomingPreferences.targetLanguage = "no"
        incomingPreferences.listen = SavedAudioRoute(input: SavedAudioDevice(uid: "demo-BlackHole16ch", name: "BlackHole 16ch"),
                                                     output: SavedAudioDevice(uid: "demo-headphones", name: "Headphones"))
        func model(_ preferences: AppPreferences) -> AppModel {
            AppModel(providerFactory: { OpenAITranslationProvider() }, deviceList: { devices },
                     preferences: MemoryAppPreferences(preferences), serviceKeyPresence: { _ in true },
                     providerResolver: { ProviderFactory.make($0) }, loadProviderCredentials: { _ in throw BridgeError.unavailable("Demo") })
        }
        let incoming = model(incomingPreferences)
        incoming.destination = .listen
        let conversation = ConversationModel(outgoing: model(outgoingPreferences), incoming: incoming)
        conversation.seedDemoTranscript()
        // Twelve fictional passages, so the timing view has a history to draw.
        let translate = [0.42, 0.38, 0.51, 0.36, 0.44, 0.40, 0.62, 0.39, 0.41, 0.37, 0.45, 0.40]
        let voice = [0.55, 0.61, 0.58, 0.49, 0.72, 0.57, 0.66, 0.52, 0.60, 0.54, 0.58, 0.56]
        let wait = [0.10, 0.00, 0.35, 0.05, 0.00, 0.80, 0.20, 0.00, 0.15, 0.00, 0.30, 0.05]
        conversation.outgoing.seedDemoTimings((0..<12).map { index in
            PassageTiming(passageSeconds: 4, translateSeconds: translate[index], voiceSeconds: voice[index], preparedAhead: index == 7,
                          totalSeconds: index == 7 ? 0.25 : translate[index] + voice[index] + wait[index], speechSeconds: 4, rate: 1)
        })
        UserDefaults.standard.set(true, forKey: PipelineTimingPreferences.visible)
        return conversation
    }
}

extension ConversationModel {
    func seedDemoTranscript() {
        let you = UUID(), meeting = UUID()
        let lines: [(UUID, ConversationDirection, String, String)] = [
            (you, .outgoing, "Møtet med Lars starter klokken ni, ikke ti.", "The meeting with Lars starts at nine, not ten."),
            (meeting, .incoming, "Can Ingrid send the five reports before Friday?", "Kan Ingrid sende de fem rapportene før fredag?"),
            (you, .outgoing, "Ja, hun sender dem i morgen.", "Yes, she will send them tomorrow.")
        ]
        demoTranscriptBegin(you, .outgoing); demoTranscriptBegin(meeting, .incoming)
        for (session, direction, source, target) in lines {
            demoTranscriptReceive(.sourceTranscript(source), session, direction)
            demoTranscriptReceive(.targetTranscript(target), session, direction)
        }
    }
}
#endif
