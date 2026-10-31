import Foundation

/// Scribe batch schema. Reference: https://elevenlabs.io/docs/api-reference/speech-to-text/convert
/// This intentionally does not consume speaker-library identities or guessed speaker roles.
public enum SpeechToolsTranscription {
    private struct Response: Decodable {
        let text: String
        let language_code: String?
        let words: [Word]
    }
    private struct Word: Decodable {
        let text: String
        let type: String
        let start: Double?
        let end: Double?
        let speaker_id: String?
    }
    public static func parseElevenLabs(_ data: Data, diarize: Bool) throws -> RecordingTranscript {
        guard data.count <= 8 * 1_024 * 1_024 else { throw SpeechToolsError.transcriptTooLarge }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw SpeechToolsError.invalidResponse }
        guard response.text.utf8.count <= SpeechToolsLimits.transcriptBytes, response.words.count <= 60_000 else {
            throw SpeechToolsError.transcriptTooLarge
        }
        if let code = response.language_code, !RecordingTranscript.isLanguageCode(code) { throw SpeechToolsError.invalidResponse }
        var segments: [RecordingSegment] = []
        var speakers: [String: String] = [:]
        var text = "", speaker: String?, start: Double?, end: Double?
        var missingStart = false, missingEnd = false, previousStart: Double?
        var reconstructed = ""
        func flush() throws {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                guard segments.count < SpeechToolsLimits.segments else { throw SpeechToolsError.transcriptTooLarge }
                segments.append(RecordingSegment(id: "segment-\(segments.count + 1)", sourceText: clean, speaker: speaker,
                                                 startSeconds: missingStart ? nil : start, endSeconds: missingEnd ? nil : end))
            }
            text = ""; start = nil; end = nil; missingStart = false; missingEnd = false
        }
        for word in response.words {
            guard ["word", "spacing", "audio_event"].contains(word.type),
                  word.text.utf8.count <= SpeechToolsLimits.segmentBytes,
                  RecordingTranscript.validTime(word.start), RecordingTranscript.validTime(word.end),
                  word.speaker_id.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true else { throw SpeechToolsError.invalidResponse }
            if let start = word.start, let end = word.end, end < start { throw SpeechToolsError.invalidResponse }
            guard reconstructed.utf8.count + word.text.utf8.count <= SpeechToolsLimits.transcriptBytes else { throw SpeechToolsError.transcriptTooLarge }
            reconstructed += word.text
            if word.type == "spacing" {
                guard word.text.allSatisfy({ $0.isWhitespace }) else { throw SpeechToolsError.invalidResponse }
                if text.utf8.count + word.text.utf8.count > SpeechToolsLimits.segmentBytes { try flush() }
                else { text += word.text }
                continue
            }
            if let current = word.start {
                if let previousStart, current < previousStart { throw SpeechToolsError.invalidResponse }
                previousStart = current
            }
            var label: String?
            if diarize, let id = word.speaker_id {
                if speakers[id] == nil {
                    guard speakers.count < 32 else { throw SpeechToolsError.invalidResponse }
                    speakers[id] = "Speaker \(speakers.count + 1)"
                }
                label = speakers[id]
            }
            let gap = word.start.flatMap { next in end.map { next - $0 } } ?? 0
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               label != speaker || gap > 2 || text.utf8.count + word.text.utf8.count > SpeechToolsLimits.segmentBytes {
                try flush()
            }
            speaker = label
            if start == nil { start = word.start }
            if word.start == nil { missingStart = true }
            if word.end == nil { missingEnd = true }
            if let wordEnd = word.end { end = max(end ?? wordEnd, wordEnd) }
            text += word.text
        }
        try flush()
        // Do not silently lose text if a provider returns only part of the word timeline.
        guard response.text.filter({ !$0.isWhitespace }) == reconstructed.filter({ !$0.isWhitespace }) else {
            throw SpeechToolsError.invalidResponse
        }
        let result = RecordingTranscript(sourceLanguage: response.language_code, segments: segments)
        try result.validate()
        return result
    }
}
