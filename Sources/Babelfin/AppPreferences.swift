import Foundation
import BridgeCore

struct SavedAudioDevice: Codable, Equatable {
    let uid: String
    var name: String
}
struct SavedAudioRoute: Codable, Equatable {
    var input: SavedAudioDevice?
    var output: SavedAudioDevice?
}
struct AppPreferences: Codable, Equatable {
    var destination = AudioDestination.teams.rawValue
    var teams = SavedAudioRoute()
    var teamsOutputConfigured = false
    var listen = SavedAudioRoute()
    var listenInputConfigured = false
    var targetLanguage = SupportedTargetLanguage.english.rawValue
    var providerRoute = "openai"
    var sourceLanguage = ""
    var pacing = TranslationPacing.balanced.rawValue
    var speakTranslation = true
    var voices: [String: String] = [:]
    /// Voices for Speaker 1, 2, … per route. Empty or missing turns speaker labels off.
    var speakerVoices: [String: [String]] = [:]
    var readyForCalls = false
    var explicitlyMuted = false
    var explicitlyOff = true
    var translationIntent = true
    var transcriptVisible = false
    var originalMixEnabled = false
    var originalMixLevel = 0.25
    var originalMixDucking = true
    var outputVolume = 1.0
    private enum CodingKeys: String, CodingKey {
        case destination, teams, teamsOutputConfigured, listen, listenInputConfigured, targetLanguage, transcriptVisible, providerRoute, sourceLanguage, pacing, speakTranslation, voices, speakerVoices
        case originalMixEnabled, originalMixLevel, originalMixDucking, outputVolume
        case explicitlyMuted, explicitlyOff, translationIntent, readyForCalls
    }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        destination = try values.decodeIfPresent(String.self, forKey: .destination) ?? AudioDestination.teams.rawValue
        teams = try values.decodeIfPresent(SavedAudioRoute.self, forKey: .teams) ?? SavedAudioRoute()
        teamsOutputConfigured = try values.decodeIfPresent(Bool.self, forKey: .teamsOutputConfigured) ?? (teams.output != nil)
        listen = try values.decodeIfPresent(SavedAudioRoute.self, forKey: .listen) ?? SavedAudioRoute()
        listenInputConfigured = try values.decodeIfPresent(Bool.self, forKey: .listenInputConfigured) ?? (listen.input != nil)
        targetLanguage = try values.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "en"
        providerRoute = try values.decodeIfPresent(String.self, forKey: .providerRoute) ?? "openai"
        sourceLanguage = try values.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? ""
        pacing = try values.decodeIfPresent(String.self, forKey: .pacing) ?? TranslationPacing.balanced.rawValue
        speakTranslation = try values.decodeIfPresent(Bool.self, forKey: .speakTranslation) ?? true
        voices = try values.decodeIfPresent([String: String].self, forKey: .voices) ?? [:]
        speakerVoices = try values.decodeIfPresent([String: [String]].self, forKey: .speakerVoices) ?? [:]
        readyForCalls = try values.decodeIfPresent(Bool.self, forKey: .readyForCalls) ?? false
        explicitlyMuted = try values.decodeIfPresent(Bool.self, forKey: .explicitlyMuted) ?? false
        explicitlyOff = try values.decodeIfPresent(Bool.self, forKey: .explicitlyOff) ?? true
        translationIntent = try values.decodeIfPresent(Bool.self, forKey: .translationIntent) ?? true
        transcriptVisible = try values.decodeIfPresent(Bool.self, forKey: .transcriptVisible) ?? false
        originalMixEnabled = try values.decodeIfPresent(Bool.self, forKey: .originalMixEnabled) ?? false
        originalMixLevel = try values.decodeIfPresent(Double.self, forKey: .originalMixLevel) ?? 0.25
        originalMixDucking = try values.decodeIfPresent(Bool.self, forKey: .originalMixDucking) ?? true
        outputVolume = try values.decodeIfPresent(Double.self, forKey: .outputVolume) ?? 1
    }
    subscript(_ destination: AudioDestination) -> SavedAudioRoute {
        get { destination == .teams ? teams : listen }
        set { if destination == .teams { teams = newValue } else { listen = newValue } }
    }
}
@MainActor protocol AppPreferencesStoring {
    func load() -> AppPreferences
    func save(_ value: AppPreferences)
}
@MainActor final class UserDefaultsAppPreferences: AppPreferencesStoring {
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "babelfin.preferences.v1") { self.defaults = defaults; self.key = key }
    func load() -> AppPreferences {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(AppPreferences.self, from: data) else {
            return AppPreferences()
        }
        return value
    }
    func save(_ value: AppPreferences) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
@MainActor final class MemoryAppPreferences: AppPreferencesStoring {
    private var value: AppPreferences
    init(_ value: AppPreferences = AppPreferences()) { self.value = value }
    func load() -> AppPreferences { value }
    func save(_ value: AppPreferences) { self.value = value }
}

struct AppSessionConfiguration {
    let destination: AudioDestination
    let input: AudioDevice
    let output: AudioDevice
    let targetLanguage: String
    let route: TranslationRoute
    let sourceLanguage: String?
    let voiceID: String?
    var pacing: TranslationPacing = .balanced
    var speaksTranslation = true
    let originalAudio: Bool
    let originalMixEnabled: Bool
    let originalMixLevel: Double
    let originalMixDucking: Bool
    var speakerVoices: [String] = []
    var targetLanguageName: String { ProviderCapabilities.forRoute(route).outputLanguages.first { $0.code == targetLanguage }?.name ?? "Choose a language" }
}
