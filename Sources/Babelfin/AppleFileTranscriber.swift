import AVFoundation
import Foundation
import BridgeCore
#if canImport(Speech)
import Speech
#endif

/// Audio file › On this Mac: decodes the recording to 24 kHz PCM in a temporary file, transcribes it
/// with SpeechAnalyzer and deletes the file. Nothing is sent. The language must be chosen.
@MainActor final class OnThisMacRecordingTranscriber: SpeechToolsTranscriber {
    nonisolated static let maximumSeconds = 3_600.0
    let requiredServices: Set<ProviderService> = []
    private var task: Task<[RecordingSegment], Error>?
    func transcribe(source: RecordingSource, sourceLanguage: String?, diarize: Bool,
                    credentials: ProviderCredentials) async throws -> RecordingTranscript {
        guard let language = sourceLanguage else { throw BridgeError.unavailable("Choose the language of the recording. On this Mac cannot detect it.") }
        // The private recording folder, which Babelfin cleans at launch; readable only by the user.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Babelfin recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let track = folder.appendingPathComponent("file-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: track) }
        try await Task.detached { try RecordingAudioDecoder.writeTrack(source, to: track, maximumSeconds: Self.maximumSeconds) }.value
        let work = Task { try await AppleFileTranscriber.transcribe(track: track, language: language, speaker: nil, check: {}) }
        task = work; defer { task = nil }
        return RecordingTranscript(sourceLanguage: language, segments: try await work.value)
    }
    func cancel() { task?.cancel() }
}

/// Transcribes a recorded track on this Mac with SpeechAnalyzer (macOS 26). Nothing is sent.
/// Apple's models need the language; they do not label speakers.
/// https://developer.apple.com/documentation/speech/speechtranscriber
enum AppleFileTranscriber {
    /// Final results of one PCM16 track as segments with times, all with `speaker`.
    static func transcribe(track: URL, language: String, speaker: String?, check: @escaping @Sendable () throws -> Void) async throws -> [RecordingSegment] {
        #if canImport(Speech)
        if #available(macOS 26.0, *) { return try await Engine.transcribe(track: track, language: language, speaker: speaker, check: check) }
        #endif
        throw BridgeError.unavailable("On this Mac transcription needs macOS 26 or later.")
    }

    #if canImport(Speech)
    @available(macOS 26.0, *)
    private enum Engine {
        typealias Item = (text: String, start: Double, end: Double)

        static func transcribe(track: URL, language: String, speaker: String?, check: @escaping @Sendable () throws -> Void) async throws -> [RecordingSegment] {
            let wanted = Locale(identifier: AppleLanguage.code(language))
            let module: any SpeechModule
            let results: AsyncThrowingStream<Item, Error>
            if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
                module = transcriber
                results = finals(transcriber.results) { ($0.isFinal, $0.text) }
            } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
                let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                                       reportingOptions: [], attributeOptions: [.audioTimeRange])
                module = transcriber
                results = finals(transcriber.results) { ($0.isFinal, $0.text) }
            } else {
                throw BridgeError.unavailable("On this Mac cannot transcribe this language.")
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
                  let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(MeetingRecordingLimits.sampleRate), channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: source, to: format) else {
                throw BridgeError.unavailable("The on-device speech model is not ready. Try again in a moment.")
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.prepareToAnalyze(in: format)
            var continuation: AsyncStream<AnalyzerInput>.Continuation!
            let input = AsyncStream<AnalyzerInput> { continuation = $0 }
            try await analyzer.start(inputSequence: input)
            let collector = Task { () throws -> [Item] in
                var items: [Item] = []
                for try await item in results { items.append(item) }
                return items
            }
            do {
                let handle = try FileHandle(forReadingFrom: track)
                defer { try? handle.close() }
                while let block = try handle.read(upToCount: MeetingRecordingLimits.bytesPerSecond * 5), !block.isEmpty {
                    try check(); try Task.checkCancellation()
                    if let buffer = try convert(block, from: source, with: converter, to: format) { continuation.yield(AnalyzerInput(buffer: buffer)) }
                }
                continuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                continuation.finish(); await analyzer.cancelAndFinishNow(); collector.cancel()
                throw error
            }
            return try await collector.value.enumerated().map { index, item in
                RecordingSegment(id: "\(speaker ?? "track")-\(index)", sourceText: item.text, speaker: speaker,
                                 startSeconds: item.start, endSeconds: item.end)
            }
        }

        /// The final results, split into passages at pauses of at least `pause` seconds between words,
        /// or after `maximumWords`. Dictation returns several minutes as one result without this.
        static let pause = 0.7
        static let maximumWords = 40
        private static func finals<Results: AsyncSequence & Sendable>(_ results: Results, _ read: @escaping @Sendable (Results.Element) -> (Bool, AttributedString))
            -> AsyncThrowingStream<Item, Error> where Results.Element: Sendable {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await result in results {
                            let (isFinal, text) = read(result)
                            guard isFinal else { continue }
                            for passage in passages(text) { continuation.yield(passage) }
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        static func passages(_ text: AttributedString) -> [Item] {
            var items: [Item] = [], words: [String] = []
            var start: Double?, end = 0.0
            func flush() {
                let joined = words.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if let start, !joined.isEmpty { items.append((joined, start, max(start, end))) }
                words = []; start = nil
            }
            for run in text.runs {
                let piece = String(text[run.range].characters)
                guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self], range.start.seconds.isFinite else { words.append(piece); continue }
                if start != nil, range.start.seconds - end >= pause || words.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count >= maximumWords { flush() }
                if start == nil { start = range.start.seconds }
                words.append(piece)
                end = range.end.seconds.isFinite ? range.end.seconds : range.start.seconds
            }
            flush()
            return items
        }

        private static func convert(_ pcm: Data, from source: AVAudioFormat, with converter: AVAudioConverter, to format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
            let samples = try PCM16.decode(pcm)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { throw BridgeError.invalidPCM }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            let capacity = AVAudioFrameCount(ceil(Double(samples.count) * format.sampleRate / source.sampleRate)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw BridgeError.invalidPCM }
            var supplied = false, error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard status != .error, error == nil else { throw BridgeError.invalidPCM }
            return output.frameLength > 0 ? output : nil
        }
    }
    #endif
}
