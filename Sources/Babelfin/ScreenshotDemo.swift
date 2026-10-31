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
        incomingPreferences.providerRoute = TranslationRoute.fish.rawValue
        incomingPreferences.sourceLanguage = "en"; incomingPreferences.targetLanguage = "no"
        incomingPreferences.listen = SavedAudioRoute(input: SavedAudioDevice(uid: "demo-BlackHole16ch", name: "BlackHole 16ch"),
                                                     output: SavedAudioDevice(uid: "demo-headphones", name: "Headphones"))
        func model(_ preferences: AppPreferences) -> AppModel {
            AppModel(providerFactory: { OpenAITranslationProvider() }, deviceList: { devices },
                     preferences: MemoryAppPreferences(preferences), keyPresence: { true }, serviceKeyPresence: { _ in true },
                     providerResolver: { ProviderFactory.make($0) }, loadProviderCredentials: { _ in throw BridgeError.unavailable("Demo") })
        }
        let incoming = model(incomingPreferences)
        incoming.destination = .listen
        let conversation = ConversationModel(outgoing: model(outgoingPreferences), incoming: incoming)
        conversation.seedDemoTranscript()
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
