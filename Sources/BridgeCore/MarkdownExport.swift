import Foundation

/// Markdown files for note tools such as Obsidian: one folder per meeting, YAML front matter,
/// and links between the files of a meeting as [[name]].
public enum MarkdownExport {
    /// "2026/11" for the year and month folders.
    public static func monthPath(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d/%02d", parts.year ?? 0, parts.month ?? 0)
    }
    /// "2026-11-01 2158 Title", without characters that file systems or note tools reject.
    public static func folderName(_ date: Date, title: String, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        return stamp + " " + safeName(title)
    }
    /// A file or folder name: no path separators, colons, brackets, hashes or control characters; at most 80 characters.
    public static func safeName(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|[]#^").union(.controlCharacters).union(.newlines)
        let cleaned = String(text.unicodeScalars.map { banned.contains($0) ? " " : Character($0) })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
    }

    /// YAML front matter. Values are quoted; lists are flow sequences.
    public static func frontMatter(_ fields: [(String, FrontMatterValue)]) -> String {
        "---\n" + fields.map { key, value in "\(key): \(value.yaml)" }.joined(separator: "\n") + "\n---\n"
    }
    public enum FrontMatterValue {
        case text(String), list([String]), date(Date)
        var yaml: String {
            switch self {
            case .text(let value): return quote(value)
            case .list(let values): return "[" + values.map(quote).joined(separator: ", ") + "]"
            case .date(let value):
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
                return formatter.string(from: value)
            }
        }
        private func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ") + "\""
        }
    }

    /// A timed transcript: one paragraph per segment, "**[m:ss] Speaker:** text".
    public static func transcript(title: String, segments: [RecordingSegment], names: [String: String] = [:], translation: Bool = false) -> String {
        var lines = ["# \(title)", ""]
        for segment in segments {
            let text = segment.sourceText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            let time = segment.startSeconds.map { "[\(MeetingPrompts.clock($0))] " } ?? ""
            let speaker = segment.speaker.map { (names[$0] ?? $0) + ":" } ?? ""
            let head = (time + speaker).trimmingCharacters(in: .whitespaces)
            lines.append(head.isEmpty ? text : "**\(head)** \(text)")
            if translation, let translated = segment.translatedText, !translated.isEmpty { lines.append("> \(translated)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
