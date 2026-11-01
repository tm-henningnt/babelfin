import AVFoundation
import Foundation
import BridgeCore
#if canImport(Translation)
import Translation
#endif

/// Language codes for Apple's on-device frameworks. Babelfin uses `no` for Norwegian;
/// Apple's voices and translation models use `nb` (Bokmål).
enum AppleLanguage {
    static func code(_ language: String) -> String {
        let base = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()
        return base == "no" ? "nb" : base
    }
    /// The Babelfin code for an Apple language code.
    static func babelfin(_ code: String) -> String { code == "nb" ? "no" : code }
}

/// On-device speech with the system voices (AVSpeechSynthesizer). Nothing leaves the Mac.
/// The synthesizer renders a sentence at once; the stage converts it to mono 24 kHz PCM16.
/// https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)
@MainActor final class AppleSpeechSynthesisStage: SpeechSynthesisStage {
    private var render: SpeechRender?
    private var rate = 1.0

    /// The best installed voice for a language: premium, then enhanced, then default quality.
    static func voice(for language: String, voiceID: String?) -> AVSpeechSynthesisVoice? {
        if let voiceID, !voiceID.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: voiceID) { return chosen }
        let code = AppleLanguage.code(language)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { AppleLanguage.code($0.language) == code && !isPersonalVoice($0) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    /// Personal Voice is for augmentative communication; Babelfin does not use it.
    nonisolated static func isPersonalVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if #available(macOS 14.0, *) { return voice.voiceTraits.contains(.isPersonalVoice) }
        return false
    }
    func prepareSpeakingRate(_ rate: Double) -> Bool {
        self.rate = rate.isFinite ? min(2, max(0.5, rate)) : 1
        return true
    }
    func synthesize(text: String, language: String, voiceID: String?, credentials: ProviderCredentials,
                    onAudio: @escaping TranslationAudioHandler) async throws {
        let rate = self.rate; self.rate = 1
        try await speak(text: text, language: language, voiceID: voiceID, rate: rate, onAudio: onAudio)
    }
    func synthesize(text: String, language: String, voiceID: String?, direction: SpeechDirection,
                    credentials: ProviderCredentials, onAudio: @escaping TranslationAudioHandler) async throws {
        try await speak(text: text, language: language, voiceID: voiceID, rate: direction.speed, onAudio: onAudio)
    }
    func cancel() { render?.stop(); render = nil }

    private func speak(text: String, language: String, voiceID: String?, rate: Double,
                       onAudio: @escaping TranslationAudioHandler) async throws {
        guard let voice = Self.voice(for: language, voiceID: voiceID) else {
            throw BridgeError.unavailable("No system voice speaks this language. Add one in System Settings › Accessibility › Read & Speak.")
        }
        let speed = min(AVSpeechUtteranceMaximumSpeechRate,
                        max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate)))
        let render = SpeechRender(); self.render = render
        let audio = AsyncThrowingStream<Data, Error> { render.start(text: text, voice: voice.identifier, rate: speed, into: $0) }
        try await withTaskCancellationHandler {
            for try await chunk in audio {
                try Task.checkCancellation()
                try await onAudio(chunk)
            }
        } onCancel: { render.stop() }
        if self.render === render { self.render = nil }
    }
}

/// One utterance rendered to buffers. The synthesizer calls back serially from its own
/// thread; `stop` may come from any thread and only asks the synthesizer to stop.
private final class SpeechRender: @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let resampler = SynthesisResampler()
    func start(text: String, voice: String, rate: Float, into continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice); utterance.rate = rate
        synthesizer.write(utterance) { [resampler] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            do {
                // The last buffer is empty and ends the utterance.
                if pcm.frameLength == 0 {
                    let tail = try resampler.finish()
                    if !tail.isEmpty { continuation.yield(tail) }
                    continuation.finish()
                } else {
                    let chunk = try resampler.convert(pcm)
                    if !chunk.isEmpty { continuation.yield(chunk) }
                }
            } catch { continuation.finish(throwing: error) }
        }
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

/// Converts the synthesizer's buffers (22.05 kHz Float32 on macOS 27) to mono 24 kHz PCM16.
/// The synthesizer calls it serially from one thread.
private final class SynthesisResampler: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { throw BridgeError.invalidPCM }
        var supplied = false
        return try run(converter, frames: buffer.frameLength, rate: buffer.format.sampleRate) { status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
    }
    /// Returns the samples the converter still holds.
    func finish() throws -> Data {
        guard let converter else { return Data() }
        return try run(converter, frames: 4_096, rate: converter.inputFormat.sampleRate) { status in
            status.pointee = .endOfStream; return nil
        }
    }
    private func run(_ converter: AVAudioConverter, frames: AVAudioFrameCount, rate: Double,
                     input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) throws -> Data {
        let capacity = AVAudioFrameCount(ceil(Double(frames) * 24_000 / rate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw BridgeError.invalidPCM }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in input(status) }
        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else { throw BridgeError.invalidPCM }
        return PCM16.encode(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }
}

#if canImport(Translation)
/// On-device text translation with Apple's Translation framework. The text stays on the Mac;
/// Apple may collect usage metrics without the text. Each language pair keeps one session.
/// From macOS 26.4 the stage tries the faster traditional models first and uses Apple
/// Intelligence for pairs they do not cover, such as Norwegian.
/// https://developer.apple.com/documentation/translation/translationsession
@available(macOS 26.0, *)
@MainActor final class AppleTranslationStage: TextTranslationStage {
    private var sessions: [String: SessionBox] = [:]
    private var task: Task<String, Error>?

    func translate(text: String, sourceLanguage: String?, targetLanguage: String, credentials: ProviderCredentials) async throws -> String {
        guard let sourceLanguage, !sourceLanguage.isEmpty else {
            throw BridgeError.unavailable("Choose the input language. On-device translation does not detect it.")
        }
        let source = Locale.Language(identifier: AppleLanguage.code(sourceLanguage))
        let target = Locale.Language(identifier: AppleLanguage.code(targetLanguage))
        let key = "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
        let task = Task { @MainActor in
            do { return try await self.translate(text, source: source, target: target, key: key) }
            catch TranslationError.notInstalled {
                throw BridgeError.unavailable("Install both languages in System Settings › General › Language & Region › Translation Languages.")
            } catch TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage {
                throw BridgeError.unavailable("On-device translation does not support this language pair on this Mac.")
            }
        }
        self.task = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func cancel() { task?.cancel(); task = nil }

    private func translate(_ text: String, source: Locale.Language, target: Locale.Language, key: String) async throws -> String {
        if let session = sessions[key] { return try await Self.run(session, text) }
        if #available(macOS 26.4, *) {
            let fast = SessionBox(TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency))
            do {
                let result = try await Self.run(fast, text); sessions[key] = fast; return result
            } catch TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage, TranslationError.notInstalled {
                let intelligence = SessionBox(TranslationSession(installedSource: source, target: target, preferredStrategy: .highFidelity))
                let result = try await Self.run(intelligence, text); sessions[key] = intelligence; return result
            }
        }
        let session = SessionBox(TranslationSession(installedSource: source, target: target))
        let result = try await Self.run(session, text); sessions[key] = session; return result
    }
    /// One translation at a time per session: the stage awaits each call before the next.
    final class SessionBox: @unchecked Sendable {
        let session: TranslationSession
        init(_ session: TranslationSession) { self.session = session }
    }
    nonisolated private static func run(_ box: SessionBox, _ text: String) async throws -> String {
        try await box.session.translate(text).targetText
    }
}
#endif
