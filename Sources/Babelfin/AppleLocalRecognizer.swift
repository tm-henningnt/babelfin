import AVFoundation
import Foundation
import BridgeCore
#if canImport(Speech)
import Speech
#endif
#if canImport(Translation)
import Translation
#endif

/// One result of on-device recognition: tentative text for the current passage, or its final text.
struct LocalTranscript: Sendable, Equatable {
    let text: String
    let isFinal: Bool
}

/// The speech engine behind `AppleLocalRecognizer`. Checks replace it with a fake.
protocol LocalTranscriptionEngine: AnyObject, Sendable {
    /// Prepares the model for the language and starts analysis. Results arrive on `results`.
    func start(language: String) async throws -> AsyncThrowingStream<LocalTranscript, Error>
    /// Mono 24 kHz PCM16, in order. Called from one thread at a time.
    func append(_ pcm: Data) throws
    /// Ends the current passage: the engine finalizes the text of all audio received so far.
    func finalizePassage() async throws
    /// Ends the input; the results stream finishes after the last final result.
    func finish() async throws
    func cancel() async
}

/// On-device recognition for a composed route. Babelfin ends a passage at the end of speech or
/// at a short pause after 4–8 s, as on the cloud routes, and the engine finalizes it. Tentative
/// text revises the current passage; final text completes it.
@MainActor final class AppleLocalRecognizer: StreamingSpeechRecognizer {
    var onEvent: RecognitionEventHandler?
    private let engine: any LocalTranscriptionEngine
    private let feed = LocalAudioFeed()
    private var results: Task<Void, Never>?
    private var used = false, active = false, closing = false, done = false
    private var failure: String?
    private var sourceLanguage: String?
    private var passage = 0, revision = 0
    private let finishTimeout: TimeInterval

    init(engine: any LocalTranscriptionEngine, finishTimeout: TimeInterval = 5) {
        self.engine = engine; self.finishTimeout = finishTimeout
    }

    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        guard !used else { throw BridgeError.unavailable("Create a new recognition session before starting again.") }
        used = true
        guard let language = configuration.sourceLanguage, !language.isEmpty else {
            throw BridgeError.unavailable("Choose the input language. On-device recognition does not detect it.")
        }
        sourceLanguage = language
        let stream: AsyncThrowingStream<LocalTranscript, Error>
        do { stream = try await engine.start(language: language) }
        catch let error as BridgeError { throw error }
        catch { throw BridgeError.unavailable("On-device recognition could not start for this language.") }
        active = true
        feed.open(engine: engine, pacing: configuration.pacing) { [weak self] in
            Task { @MainActor [weak self] in await self?.endPassage() }
        }
        results = Task { [weak self] in
            do {
                for try await transcript in stream {
                    guard let self, self.active || self.closing else { return }
                    await self.receive(transcript)
                }
                self?.done = true
            } catch {
                guard !Task.isCancelled else { return }
                await self?.fail("On-device recognition stopped.")
            }
        }
    }
    nonisolated func append(_ pcm: Data) throws { try feed.append(pcm) }
    func stopInput() { feed.close() }
    func updatePacing(_ pacing: TranslationPacing) { feed.setPacing(pacing) }

    func finish() async throws {
        guard active, !closing else { if let failure { throw BridgeError.unavailable(failure) }; return }
        closing = true; feed.close()
        do { try await engine.finish() } catch { cancel(); throw BridgeError.unavailable("On-device recognition could not finish the last passage.") }
        let deadline = ProcessInfo.processInfo.systemUptime + finishTimeout
        while failure == nil, !done, ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if let failure { throw BridgeError.unavailable(failure) }
        guard done else { cancel(); throw BridgeError.unavailable("The final recognition transcript was not confirmed before the session closed.") }
        cancel(); await onEvent?(.closed)
    }
    func cancel() {
        active = false
        feed.close()
        results?.cancel(); results = nil
        let engine = self.engine
        Task { await engine.cancel() }
    }

    private func endPassage() async {
        guard active, !closing else { return }
        do { try await engine.finalizePassage() } catch { await fail("On-device recognition stopped.") }
    }
    private func receive(_ transcript: LocalTranscript) async {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 32_000 else { return }
        revision += 1
        await onEvent?(.segment(TranscriptSegment(id: "local-\(passage)", revision: revision, text: text,
                                                  isFinal: transcript.isFinal, language: sourceLanguage)))
        if transcript.isFinal { passage += 1; revision = 0 }
    }
    private func fail(_ message: String) async {
        guard failure == nil, active || closing else { return }
        failure = message; cancel(); await onEvent?(.failure(message))
    }
}

/// Passes audio to the engine and decides where passages end. `append` comes from the capture
/// thread; the lock keeps the cutter and the engine's input in order.
private final class LocalAudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: (any LocalTranscriptionEngine)?
    private var cutter = SegmentCutter(commitsOnSilence: true)
    private var passageEnded: (@Sendable () -> Void)?

    func open(engine: any LocalTranscriptionEngine, pacing: TranslationPacing, passageEnded: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.engine = engine; self.passageEnded = passageEnded
        cutter = SegmentCutter(minimumSeconds: pacing.minimumSegmentSeconds, maximumSeconds: pacing.maximumSegmentSeconds,
                               serviceCommitSeconds: pacing.commitSilenceSeconds, commitsOnSilence: true)
    }
    func setPacing(_ pacing: TranslationPacing) {
        lock.lock(); cutter.minimumSeconds = pacing.minimumSegmentSeconds; cutter.maximumSeconds = pacing.maximumSegmentSeconds; lock.unlock()
    }
    func append(_ pcm: Data) throws {
        lock.lock()
        guard let engine else { lock.unlock(); throw BridgeError.unavailable("Translation is not ready.") }
        do { try engine.append(pcm) } catch { lock.unlock(); throw error }
        let ended = cutter.commitAfter(pcm) ? passageEnded : nil
        lock.unlock()
        ended?()
    }
    func close() { lock.lock(); engine = nil; passageEnded = nil; lock.unlock() }
}

#if canImport(Speech)
/// Apple's on-device speech models through SpeechAnalyzer (macOS 26). SpeechTranscriber serves
/// the languages it supports; DictationTranscriber serves the others, such as Norwegian Bokmål.
/// The models download from Apple on first use and run on the Mac.
/// https://developer.apple.com/documentation/speech/speechanalyzer
@available(macOS 26.0, *)
final class SpeechAnalyzerEngine: LocalTranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var resultTask: Task<Void, Never>?
    private let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    /// Babelfin language codes that one of the two transcribers supports on this Mac.
    static func supportedLanguages() async -> Set<String> {
        let locales = await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales
        return Set(locales.compactMap { $0.language.languageCode?.identifier }.map(AppleLanguage.babelfin))
    }

    func start(language: String) async throws -> AsyncThrowingStream<LocalTranscript, Error> {
        let wanted = Locale(identifier: AppleLanguage.code(language))
        let module: any SpeechModule
        let results: AsyncThrowingStream<LocalTranscript, Error>
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            module = transcriber
            results = Self.map(transcriber.results) { (String($0.text.characters), $0.isFinal) }
        } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            module = transcriber
            results = Self.map(transcriber.results) { (String($0.text.characters), $0.isFinal) }
        } else {
            throw BridgeError.unavailable("On-device recognition does not support this language on this Mac.")
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              let converter = AVAudioConverter(from: source, to: format) else {
            throw BridgeError.unavailable("The on-device speech model is not ready. Try again in a moment.")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        var continuation: AsyncStream<AnalyzerInput>.Continuation!
        let stream = AsyncStream<AnalyzerInput> { continuation = $0 }
        try await analyzer.start(inputSequence: stream)
        lock.withLock { self.analyzer = analyzer; input = continuation; self.converter = converter; analyzerFormat = format }
        return results
    }
    func append(_ pcm: Data) throws {
        let samples = try PCM16.decode(pcm)
        lock.lock(); defer { lock.unlock() }
        guard let input, let converter, let analyzerFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw BridgeError.unavailable("Translation is not ready.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(ceil(Double(samples.count) * analyzerFormat.sampleRate / 24_000)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { throw BridgeError.invalidPCM }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil else { throw BridgeError.invalidPCM }
        if output.frameLength > 0 { input.yield(AnalyzerInput(buffer: output)) }
    }
    func finalizePassage() async throws {
        let analyzer = lock.withLock { self.analyzer }
        try await analyzer?.finalize(through: nil)
    }
    func finish() async throws {
        let (analyzer, input) = lock.withLock { (self.analyzer, self.input) }
        input?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
    }
    func cancel() async {
        let (analyzer, input) = lock.withLock { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?) in
            defer { self.analyzer = nil; self.input = nil }
            return (self.analyzer, self.input)
        }
        input?.finish()
        await analyzer?.cancelAndFinishNow()
    }

    /// Maps one transcriber's results to `LocalTranscript`.
    private static func map<Results: AsyncSequence & Sendable>(_ results: Results, _ transform: @escaping @Sendable (Results.Element) -> (String, Bool))
        -> AsyncThrowingStream<LocalTranscript, Error> where Results.Element: Sendable {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results {
                        let (text, isFinal) = transform(result)
                        continuation.yield(LocalTranscript(text: text, isFinal: isFinal))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

#if canImport(Speech) && canImport(Translation)
/// Reads which languages the on-device frameworks offer on this Mac. Reading the lists shows no
/// prompt and downloads nothing.
@available(macOS 26.0, *)
enum LocalLanguageLoader {
    static func load() async -> ProviderRegistry.LocalLanguages? {
        let recognition = await SpeechAnalyzerEngine.supportedLanguages()
        let translation = Set(await LanguageAvailability().supportedLanguages.compactMap { $0.languageCode?.identifier }.map(AppleLanguage.babelfin))
        let speech = Set(AVSpeechSynthesisVoice.speechVoices().map { AppleLanguage.babelfin(AppleLanguage.code($0.language)) })
        guard !recognition.isEmpty, !translation.isEmpty, !speech.isEmpty else { return nil }
        return .init(recognition: languages(recognition), translation: languages(translation), speech: languages(speech))
    }
    private static func languages(_ codes: Set<String>) -> [TranslationLanguage] {
        let english = Locale(identifier: "en")
        return codes.compactMap { code in english.localizedString(forLanguageCode: code).map { TranslationLanguage(code: code, name: $0) } }
            .sorted { $0.name < $1.name }
    }
}
#endif
