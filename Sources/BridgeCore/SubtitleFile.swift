import Foundation

/// SubRip (SRT) and WebVTT subtitle files from timed transcript segments.
/// A cue holds at most two lines of at most 42 characters; a longer segment becomes several cues
/// that share its time in proportion to their length.
public enum SubtitleFile {
    public enum Format: String, CaseIterable, Sendable {
        case srt, vtt
        public var fileExtension: String { rawValue }
        public var displayName: String { self == .srt ? "SubRip (SRT)" : "WebVTT" }
    }
    public enum Text: Sendable { case original, translation }

    public struct Cue: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let speaker: String?
        public let lines: [String]
    }

    public static let lineLength = 42
    /// A segment without an end time lasts this long per character, within the limits below.
    public static let secondsPerCharacter = 0.065
    public static let minimumDuration = 1.2
    public static let maximumDuration = 7.0

    /// The file content. Segments without a start time or without text are left out.
    public static func make(_ segments: [RecordingSegment], text: Text, format: Format, speakers: Bool = true) -> String {
        let items = cues(segments, text: text, speakers: speakers)
        switch format {
        case .srt:
            return items.enumerated().map { index, cue in
                "\(index + 1)\n\(time(cue.start, separator: ",")) --> \(time(cue.end, separator: ","))\n"
                    + label(cue, vtt: false) + "\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + items.map { cue in
                "\(time(cue.start, separator: ".")) --> \(time(cue.end, separator: "."))\n" + label(cue, vtt: true) + "\n"
            }.joined(separator: "\n")
        }
    }

    public static func cues(_ segments: [RecordingSegment], text: Text, speakers: Bool = true) -> [Cue] {
        let timed = segments.compactMap { segment -> (RecordingSegment, String, Double)? in
            let value = (text == .original ? segment.sourceText : segment.translatedText ?? "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard let start = segment.startSeconds, start.isFinite, start >= 0, !value.isEmpty else { return nil }
            return (segment, value, start)
        }.sorted { $0.2 < $1.2 }
        var result: [Cue] = []
        for (index, item) in timed.enumerated() {
            let (segment, value, start) = item
            var end = segment.endSeconds.flatMap { $0.isFinite && $0 > start ? $0 : nil }
                ?? start + min(maximumDuration, max(minimumDuration, Double(value.count) * secondsPerCharacter))
            if index + 1 < timed.count { end = min(end, max(start + 0.1, timed[index + 1].2)) }
            let chunks = wrap(value)
            let total = Double(chunks.reduce(0) { $0 + $1.joined(separator: " ").count })
            var cursor = start
            for (position, chunk) in chunks.enumerated() {
                let share = Double(chunk.joined(separator: " ").count) / max(1, total)
                let chunkEnd = position == chunks.count - 1 ? end : cursor + (end - start) * share
                result.append(Cue(start: cursor, end: chunkEnd, speaker: speakers ? segment.speaker : nil, lines: chunk))
                cursor = chunkEnd
            }
        }
        return result
    }

    /// Words into lines of at most `lineLength` characters, two lines per cue.
    /// A word longer than a line stays whole on its own line.
    public static func wrap(_ text: String) -> [[String]] {
        var lines: [String] = [], line = ""
        for word in text.split(separator: " ") {
            if line.isEmpty { line = String(word) }
            else if line.count + 1 + word.count <= lineLength { line += " " + word }
            else { lines.append(line); line = String(word) }
        }
        if !line.isEmpty { lines.append(line) }
        return stride(from: 0, to: lines.count, by: 2).map { Array(lines[$0..<min($0 + 2, lines.count)]) }
    }

    private static func label(_ cue: Cue, vtt: Bool) -> String {
        let text = (vtt ? cue.lines.map(escape) : cue.lines).joined(separator: "\n")
        guard let speaker = cue.speaker, !speaker.isEmpty else { return text }
        if vtt { return "<v \(escape(speaker))>" + text }
        return "\(speaker): " + text
    }
    /// WebVTT reserves `<`, `>` and `&` in cue text.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func time(_ seconds: Double, separator: String) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        let hours = milliseconds / 3_600_000, minutes = milliseconds / 60_000 % 60
        let wholeSeconds = milliseconds / 1000 % 60, rest = milliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, wholeSeconds, separator, rest)
    }
}
