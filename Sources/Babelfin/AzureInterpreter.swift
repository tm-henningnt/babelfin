import Foundation
import BridgeCore
#if canImport(MicrosoftCognitiveServicesSpeech)
import MicrosoftCognitiveServicesSpeech
#endif

/// The user's Azure Speech resource endpoint. It is not secret and lives in UserDefaults; the
/// key is stored like the other service keys.
enum AzureSettings {
    static let endpointKey = "babelfin.azure.endpoint"
    static func load(_ defaults: UserDefaults = .standard) -> URL? {
        defaults.string(forKey: endpointKey).flatMap(validated)
    }
    static func save(_ text: String, defaults: UserDefaults = .standard) throws {
        guard let url = validated(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BridgeError.unavailable("Enter the resource endpoint from the Azure portal, for example https://my-speech.cognitiveservices.azure.com/.")
        }
        defaults.set(url.absoluteString, forKey: endpointKey)
    }
    static func remove(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: endpointKey) }
    /// An https resource endpoint on an Azure or Microsoft Cognitive Services host, without a user name or query.
    static func validated(_ text: String) -> URL? {
        guard let components = URLComponents(string: text), components.scheme == "https", let host = components.host?.lowercased(),
              components.user == nil, components.password == nil, components.query == nil,
              host.hasSuffix(".cognitiveservices.azure.com") || host.hasSuffix(".api.cognitive.microsoft.com") else { return nil }
        return URL(string: "https://\(host)/")
    }
    /// The Live Interpreter endpoint of a resource.
    static func interpreterEndpoint(_ resource: URL) -> String { "wss://\(resource.host ?? "")/stt/speech/universal/v2" }
}

/// Azure target language and a Microsoft neural voice for each output Babelfin offers.
enum AzureVoices {
    static let table: [String: (target: String, voice: String)] = [
        "ar": ("ar", "ar-SA-ZariyahNeural"), "zh": ("zh-Hans", "zh-CN-XiaoxiaoNeural"), "da": ("da", "da-DK-ChristelNeural"),
        "nl": ("nl", "nl-NL-ColetteNeural"), "en": ("en", "en-US-AvaMultilingualNeural"), "fi": ("fi", "fi-FI-SelmaNeural"),
        "fr": ("fr", "fr-FR-DeniseNeural"), "de": ("de", "de-DE-KatjaNeural"), "hi": ("hi", "hi-IN-SwaraNeural"),
        "it": ("it", "it-IT-ElsaNeural"), "ja": ("ja", "ja-JP-NanamiNeural"), "ko": ("ko", "ko-KR-SunHiNeural"),
        "no": ("nb", "nb-NO-PernilleNeural"), "pl": ("pl", "pl-PL-ZofiaNeural"), "pt": ("pt", "pt-BR-FranciscaNeural"),
        "ru": ("ru", "ru-RU-SvetlanaNeural"), "es": ("es", "es-ES-ElviraNeural"), "sv": ("sv", "sv-SE-SofieNeural"),
        "tr": ("tr", "tr-TR-EmelNeural"), "uk": ("uk", "uk-UA-PolinaNeural"),
    ]
}

/// Little-endian PCM16 mono from one WAV file, converted to 24 kHz. Azure sends one WAV per passage.
enum WAVToPCM24 {
    static func convert(_ wav: Data) throws -> Data {
        let bytes = [UInt8](wav)
        guard bytes.count >= 44, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] else { throw BridgeError.invalidPCM }
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        var offset = 12, rate = 0, samples: [Int16] = []
        while offset + 8 <= bytes.count {
            let id = bytes[offset..<offset + 4], size = u32(offset + 4), body = offset + 8
            guard body + size <= bytes.count || id == [0x64, 0x61, 0x74, 0x61] else { throw BridgeError.invalidPCM }
            if id == [0x66, 0x6d, 0x74, 0x20] {
                guard u16(body) == 1, u16(body + 2) == 1, u16(body + 14) == 16 else { throw BridgeError.invalidPCM }
                rate = u32(body + 4)
            } else if id == [0x64, 0x61, 0x74, 0x61] {
                let end = min(bytes.count, body + size)
                samples = stride(from: body, to: end - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
                break
            }
            offset = body + size + (size & 1)
        }
        guard (8_000...48_000).contains(rate), !samples.isEmpty else { throw BridgeError.invalidPCM }
        guard rate != 24_000 else { return samples.withUnsafeBufferPointer { Data(buffer: $0) } }
        let count = samples.count * 24_000 / rate
        var output = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let position = Double(index) * Double(rate) / 24_000, base = Int(position), fraction = position - Double(base)
            let a = Double(samples[min(base, samples.count - 1)]), b = Double(samples[min(base + 1, samples.count - 1)])
            output[index] = Int16(a + (b - a) * fraction)
        }
        return output.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

#if canImport(MicrosoftCognitiveServicesSpeech)
/// Azure Live Interpreter through Microsoft's Speech SDK: continuous recognition with open-range
/// language detection, translation to one target and synthesis with a neural voice.
@MainActor final class AzureInterpreterProvider: TranslationProvider {
    var onEvent: TranslationEventHandler?
    var onAudio: TranslationAudioHandler?
    nonisolated private let input = PushInput()
    nonisolated private let backlog = AudioBacklog()
    private var recognizer: SPXTranslationRecognizer?
    private var audio: AsyncStream<Data>.Continuation?
    private var consumer: Task<Void, Never>?
    private var generation = UUID()
    private var started = false

    func start(configuration: TranslationConfiguration, apiKey: String) async throws {
        throw BridgeError.unavailable("Azure needs the resource endpoint and key from Settings › Accounts.")
    }
    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        guard !started else { throw BridgeError.unavailable("Create a fresh translation session before starting again.") }
        started = true
        let key = try credentials.require(.azure)
        guard let resource = AzureSettings.load() else { throw BridgeError.unavailable("Enter your Azure Speech resource endpoint in Settings › Accounts.") }
        guard configuration.sourceLanguage == nil else { throw BridgeError.unavailable("Azure detects the input language; choose Automatic.") }
        guard let target = AzureVoices.table[configuration.targetLanguage] else { throw BridgeError.unsupportedLanguage }
        let token = generation, backlog = self.backlog
        do {
            let settings = try SPXSpeechTranslationConfiguration(endpoint: AzureSettings.interpreterEndpoint(resource), subscription: key)
            settings.addTargetLanguage(target.target)
            settings.voiceName = target.voice
            let detection = try SPXAutoDetectSourceLanguageConfiguration(openRange: ())
            guard let format = SPXAudioStreamFormat(usingPCMWithSampleRate: 24_000, bitsPerSample: 16, channels: 1),
                  let stream = SPXPushAudioInputStream(audioFormat: format),
                  let audioConfiguration = SPXAudioConfiguration(streamInput: stream) else { throw BridgeError.unavailable("Azure audio input could not start.") }
            let recognizer = try SPXTranslationRecognizer(speechTranslationConfiguration: settings,
                                                          autoDetectSourceLanguageConfiguration: detection, audioConfiguration: audioConfiguration)
            input.set(stream)
            let (pieces, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            audio = continuation
            consumer = Task { [weak self] in
                // Azure sends a whole passage at once, and English often runs longer than the source.
                // Waiting audio plays a little faster, so the delay does not grow over a long session.
                let stretcher = SpeechRateStretcher()
                for await passage in pieces {
                    guard let self, self.generation == token else { return }
                    stretcher.setRate(CatchUpRate.forBacklog(seconds: backlog.seconds))
                    let pcm = (try? stretcher.process(passage)) ?? passage
                    backlog.remove(passage.count)
                    var offset = 0
                    while offset < pcm.count {
                        let end = min(offset + 4_800, pcm.count)
                        let piece = Data(pcm[offset..<end])
                        if let handler = self.onAudio {
                            do { try await handler(piece) } catch { await self.fail("audio_playback_failed", token: token); return }
                        } else { await self.onEvent?(.audio(piece)) }
                        offset = end
                    }
                }
            }
            recognizer.addRecognizedEventHandler { [weak self] _, event in
                let result = event.result
                let source = result.text ?? "", translated = (result.translations[target.target] as? String) ?? ""
                let id = result.resultId
                Task { @MainActor [weak self] in await self?.recognized(id: id, source: source, translated: translated, target: configuration.targetLanguage, token: token) }
            }
            recognizer.addSynthesizingEventHandler { [weak self] _, event in
                guard let wav = event.result.audio, !wav.isEmpty, let pcm = try? WAVToPCM24.convert(wav) else { return }
                // The consumer speeds up to catch up; past 30 s behind, the session reports the backlog
                // instead of dropping passages without a word.
                guard backlog.seconds < 30 else {
                    Task { @MainActor [weak self] in await self?.fail("received_audio_backlog", token: token) }
                    return
                }
                backlog.add(pcm.count)
                continuation.yield(pcm)
            }
            recognizer.addCanceledEventHandler { [weak self] _, event in
                let failed = event.reason == SPXCancellationReason.error
                Task { @MainActor [weak self] in if failed { await self?.fail("translation_disconnected", token: token) } }
            }
            try recognizer.startContinuousRecognition()
            self.recognizer = recognizer
        } catch let error as BridgeError {
            cancel(); throw error
        } catch {
            cancel()
            throw BridgeError.unavailable("Could not start Azure Live Interpreter. Check the endpoint, key, region and network.")
        }
        await onEvent?(.created)
        await onEvent?(.updated)
    }
    private func recognized(id: String, source: String, translated: String, target: String, token: UUID) async {
        guard generation == token else { return }
        let id = "azure-" + String(id.prefix(120))
        if !source.isEmpty { await onEvent?(.segment(TranscriptSegment(id: id, text: source, isFinal: true), role: .source)) }
        if !translated.isEmpty { await onEvent?(.segment(TranscriptSegment(id: id, text: translated, isFinal: true, language: target), role: .target)) }
    }
    nonisolated func append(_ pcm: Data) throws {
        guard pcm.count % 2 == 0 else { throw BridgeError.invalidPCM }
        try input.write(pcm)
    }
    func stopInput() { input.close() }
    func finish() async {
        input.close()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        cancel()
    }
    func cancel() {
        generation = UUID()
        input.close()
        try? recognizer?.stopContinuousRecognition()
        recognizer = nil
        audio?.finish(); audio = nil
        consumer?.cancel(); consumer = nil
    }
    private func fail(_ code: String, token: UUID) async {
        guard generation == token else { return }
        cancel()
        await onEvent?(.failure(code))
    }
}

/// Translated audio received but not yet played: added on the SDK thread, removed by the consumer.
private final class AudioBacklog: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func add(_ count: Int) { lock.withLock { bytes += count } }
    func remove(_ count: Int) { lock.withLock { bytes = max(0, bytes - count) } }
    var seconds: Double { lock.withLock { Double(bytes) / 48_000 } }
}

/// The SDK's push stream, written from the capture thread and closed from the main actor.
private final class PushInput: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SPXPushAudioInputStream?
    func set(_ value: SPXPushAudioInputStream) { lock.withLock { stream = value } }
    func write(_ pcm: Data) throws {
        try lock.withLock {
            guard let stream else { throw BridgeError.unavailable("The Azure audio input is closed.") }
            stream.write(pcm)
        }
    }
    func close() { lock.withLock { stream?.close(); stream = nil } }
}
#endif
