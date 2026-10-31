import Foundation

/// Product limits, independent of a provider's larger advertised maximums.
public enum SpeechToolsLimits {
    public static let recordingBytes = 25_000_000
    public static let transcriptBytes = 200_000
    public static let translatedBytes = 400_000
    public static let segments = 4_000
    public static let segmentBytes = 3_000
    public static let notesBytes = 200_000
    public static let notesChunkBytes = 12_000
    public static let voiceCharacters = 2_000
    public static let voicePCMBytes = 24_000 * 2 * 90
}

public enum SpeechToolsError: LocalizedError, Sendable, Equatable {
    case recordingTooLarge, invalidRecording, unsupportedFormat, invalidResponse
    case transcriptTooLarge, notesTooLarge, emptyText, clipTooLong, invalidPCM, unsupportedVoiceProvider
    public var errorDescription: String? {
        switch self {
        case .recordingTooLarge: return "Choose a recording up to 25 MB."
        case .invalidRecording: return "The recording could not be read. Choose a local audio file."
        case .unsupportedFormat: return "Choose a WAV, MP3, M4A, MP4, FLAC, OGG, or WebM recording."
        case .invalidResponse: return "The service returned an incomplete or unsupported transcript."
        case .transcriptTooLarge: return "This transcript is too large. Split the recording into shorter parts."
        case .notesTooLarge: return "This text is too long for notes. Select a shorter section."
        case .emptyText: return "Add some text first."
        case .clipTooLong: return "Voice clips can contain up to 2,000 characters."
        case .invalidPCM: return "The service returned an unsupported audio clip."
        case .unsupportedVoiceProvider: return "Choose ElevenLabs or Fish Audio for a voice clip."
        }
    }
}

/// Speaker labels are anonymous, local to this recording. Times refer to source audio.
public struct RecordingSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sourceText: String
    public let translatedText: String?
    public let speaker: String?
    public let startSeconds: Double?
    public let endSeconds: Double?
    public init(id: String, sourceText: String, translatedText: String? = nil, speaker: String? = nil,
                startSeconds: Double? = nil, endSeconds: Double? = nil) {
        self.id = id; self.sourceText = sourceText; self.translatedText = translatedText
        self.speaker = speaker; self.startSeconds = startSeconds; self.endSeconds = endSeconds
    }
    public func translated(_ text: String) -> Self {
        Self(id: id, sourceText: sourceText, translatedText: text, speaker: speaker,
             startSeconds: startSeconds, endSeconds: endSeconds)
    }
}

public struct RecordingTranscript: Codable, Equatable, Sendable {
    public let sourceLanguage: String?
    public let targetLanguage: String?
    public let segments: [RecordingSegment]
    public init(sourceLanguage: String?, targetLanguage: String? = nil, segments: [RecordingSegment]) {
        self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage; self.segments = segments
    }
    public func validate() throws {
        guard segments.count <= SpeechToolsLimits.segments,
              segments.reduce(0, { $0 + $1.sourceText.utf8.count }) <= SpeechToolsLimits.transcriptBytes,
              segments.reduce(0, { $0 + ($1.translatedText?.utf8.count ?? 0) }) <= SpeechToolsLimits.translatedBytes else {
            throw SpeechToolsError.transcriptTooLarge
        }
        for code in [sourceLanguage, targetLanguage].compactMap({ $0 }) {
            guard Self.isLanguageCode(code) else { throw SpeechToolsError.invalidResponse }
        }
        var ids = Set<String>()
        for segment in segments {
            guard !segment.id.isEmpty, segment.id.utf8.count <= 128, ids.insert(segment.id).inserted,
                  !segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  segment.sourceText.utf8.count <= SpeechToolsLimits.segmentBytes,
                  segment.translatedText.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 8_000 }) ?? true,
                  segment.speaker.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains(where: { $0.isNewline }) }) ?? true,
                  Self.validTime(segment.startSeconds), Self.validTime(segment.endSeconds) else { throw SpeechToolsError.invalidResponse }
            if let start = segment.startSeconds, let end = segment.endSeconds, end < start { throw SpeechToolsError.invalidResponse }
        }
    }
    public func plainText(includeTranslation: Bool = true) -> String {
        segments.map { segment in
            var heading: [String] = []
            if let start = segment.startSeconds {
                let end = segment.endSeconds.map { "–" + Self.timestamp($0) } ?? ""
                heading.append("[\(Self.timestamp(start))\(end)]")
            }
            if let speaker = segment.speaker { heading.append(speaker) }
            var lines = heading.isEmpty ? [] : [heading.joined(separator: " ")]
            lines.append(segment.sourceText)
            if includeTranslation, let translation = segment.translatedText { lines.append(translation) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
    static func isLanguageCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }
    }
    static func validTime(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 && $0 <= 86_400 } ?? true }
    private static func timestamp(_ value: Double) -> String {
        guard validTime(value) else { return "?" }
        let seconds = Int(value)
        return seconds >= 3_600 ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

public struct MeetingNotes: Equatable, Sendable {
    public let text: String
    public let sourceCharacters: Int
    public let coveredCharacters: Int
    public let chunkCount: Int
    /// Coverage means all supplied text was processed, not that a recording captured every speaker.
    public var isComplete: Bool { coveredCharacters == sourceCharacters }
    public init(text: String, sourceCharacters: Int, coveredCharacters: Int, chunkCount: Int) {
        self.text = text; self.sourceCharacters = sourceCharacters
        self.coveredCharacters = coveredCharacters; self.chunkCount = chunkCount
    }
}

public struct SpeechToolsProgress: Equatable, Sendable {
    public enum Stage: String, Sendable { case transcription, translation, notes, voiceClip }
    public let stage: Stage
    public let completed: Int
    public let total: Int
    public init(stage: Stage, completed: Int, total: Int) {
        self.stage = stage; self.completed = completed; self.total = total
    }
}

public enum SpeechToolsText {
    /// Preserves every character, including delimiters, and prefers whitespace boundaries.
    public static func chunks(_ text: String, maximumBytes: Int) throws -> [String] {
        guard maximumBytes > 0 else { throw SpeechToolsError.invalidResponse }
        var output: [String] = [], buffer = "", bytes = 0
        for character in text {
            let count = String(character).utf8.count
            guard count <= maximumBytes else { throw SpeechToolsError.notesTooLarge }
            while bytes + count > maximumBytes {
                if let boundary = buffer.lastIndex(where: { $0.isWhitespace }),
                   buffer.distance(from: buffer.startIndex, to: boundary) > buffer.count / 2 {
                    let split = buffer.index(after: boundary)
                    output.append(String(buffer[..<split])); buffer = String(buffer[split...]); bytes = buffer.utf8.count
                } else { output.append(buffer); buffer = ""; bytes = 0 }
            }
            buffer.append(character); bytes += count
        }
        if !buffer.isEmpty { output.append(buffer) }
        return output
    }
}

public enum SpeechToolsWAV {
    /// Only our bounded canonical generated clips are accepted for local playback.
    public static func decode(_ wav: Data) throws -> Data {
        guard wav.count > 44, wav.count <= SpeechToolsLimits.voicePCMBytes + 44 else { throw SpeechToolsError.invalidPCM }
        let pcm = Data(wav.dropFirst(44))
        let canonical = try encode(pcm: pcm)
        guard canonical.prefix(44) == wav.prefix(44) else { throw SpeechToolsError.invalidPCM }
        return pcm
    }

    /// Canonical speech boundary: signed PCM16 little endian, mono, 24 kHz.
    public static func encode(pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= SpeechToolsLimits.voicePCMBytes else {
            throw SpeechToolsError.invalidPCM
        }
        var output = Data(); output.reserveCapacity(44 + pcm.count)
        func ascii(_ value: String) { output.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { output.append(UInt8(value & 0xff)); output.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { output.append(UInt8((value >> shift) & 0xff)) } }
        ascii("RIFF"); u32(UInt32(36 + pcm.count)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm.count)); output.append(pcm)
        return output
    }
}
