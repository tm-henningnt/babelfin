import AppKit
import SwiftUI
import BridgeCore

/// Saves transcripts and notes as Markdown in a folder the user chooses, for Obsidian and other
/// note tools. Off by default: transcripts otherwise stay in memory. One folder per meeting:
/// <folder>/2026/11/2026-11-01 2158 Meeting/2026-11-01 2158 Meeting Notes.md.
@MainActor enum AutoExport {
    static let enabledKey = "babelfin.autoExport.enabled"
    static let folderKey = "babelfin.autoExport.folder"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var root: URL {
        if let path = UserDefaults.standard.string(forKey: folderKey), !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Babelfin", isDirectory: true)
    }

    /// Writes the files into the meeting's folder and replaces earlier versions. Each file name starts
    /// with the folder name, so links such as [[2026-11-01 2158 Meeting Transcript]] are unique in a vault.
    /// Returns a message when the folder cannot be written.
    @discardableResult
    static func write(date: Date, title: String, files: [String: String]) -> String? {
        guard enabled else { return nil }
        let name = MarkdownExport.folderName(date, title: title)
        let folder = root.appendingPathComponent(MarkdownExport.monthPath(date), isDirectory: true).appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, content) in files {
                try Data(content.utf8).write(to: folder.appendingPathComponent(name + " " + MarkdownExport.safeName(file) + ".md"), options: .atomic)
            }
            return nil
        } catch {
            return "Babelfin could not save to \(root.path). Choose another folder in Settings › General."
        }
    }

    /// The folder title of each exported recording, so two recordings in one minute get two folders.
    private static var titles: [UUID: String] = [:]
    private static func title(for document: MeetingDocument) -> String {
        if let known = titles[document.id] { return known }
        let month = root.appendingPathComponent(MarkdownExport.monthPath(document.createdAt), isDirectory: true)
        var title = document.title, number = 1
        while FileManager.default.fileExists(atPath: month.appendingPathComponent(MarkdownExport.folderName(document.createdAt, title: title)).path) {
            number += 1; title = "\(document.title) \(number)"
        }
        titles[document.id] = title
        return title
    }

    /// A recording's notes, transcripts and email, with the user's own notes.
    static func export(_ document: MeetingDocument, userNotes: String = "") -> String? {
        guard enabled else { return nil }
        let folderTitle = title(for: document)
        let participants = document.speakers.map { document.name($0) }
        let front = MarkdownExport.frontMatter([
            ("date", .date(document.createdAt)), ("type", .text("meeting")), ("source", .text("Babelfin")),
            ("transcription", .text(document.service.rawValue)), ("duration", .text(MeetingPrompts.clock(document.segments.last?.endSeconds ?? 0))),
            ("participants", .list(participants)), ("tags", .list(["meeting", "babelfin"])),
        ])
        let title = document.title + ", " + document.createdAt.formatted(date: .abbreviated, time: .shortened)
        var files = ["Transcript": front + "\n" + MarkdownExport.transcript(title: "Transcript", segments: document.segments, names: document.names, translation: true)]
        let link = MarkdownExport.folderName(document.createdAt, title: folderTitle) + " Transcript"
        let own = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownSection = own.isEmpty ? "" : "\n\n## Your notes\n\n" + own
        if let notes = document.notes { files["Notes"] = front + "\n# \(title)\n\n" + notes + ownSection + "\n\nTranscript: [[\(link)]]\n" }
        if let clean = document.clean { files["Clean transcript"] = front + "\n# Clean transcript\n\n" + clean + "\n" }
        if let translated = document.translatedNotes { files["Notes (translated)"] = front + "\n" + translated + "\n" }
        if let email = document.email { files["Follow-up email"] = front + "\n" + email + "\n" }
        return write(date: document.createdAt, title: folderTitle, files: files)
    }

    /// An Audio file transcript, with the translation under each passage.
    static func export(_ recording: RecordingTranscript, name: String, date: Date) -> String? {
        let front = MarkdownExport.frontMatter([
            ("date", .date(date)), ("type", .text("transcript")), ("source", .text("Babelfin")),
            ("language", .text(recording.sourceLanguage ?? "auto")), ("tags", .list(["transcript", "babelfin"])),
        ])
        return write(date: date, title: name, files: ["Transcript": front + "\n" + MarkdownExport.transcript(
            title: name, segments: recording.segments, translation: recording.targetLanguage != nil)])
    }

    /// The live transcript of both directions: each original with its translation below it.
    static func export(live transcript: MeetingTranscript, started: Date) -> String? {
        let front = MarkdownExport.frontMatter([
            ("date", .date(started)), ("type", .text("transcript")), ("source", .text("Babelfin live translation")),
            ("tags", .list(["transcript", "babelfin"])),
        ])
        var lines = ["# Live transcript", ""]
        for entry in transcript.entries where !entry.segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if entry.role == .target { lines.append("> \(entry.segment.text)"); lines.append(""); continue }
            let who = transcript.speakerLabel(entry) ?? (entry.direction == .outgoing ? "You" : "Meeting")
            let time = entry.firstReceivedAt.formatted(date: .omitted, time: .standard)
            lines.append("**[\(time)] \(who):** \(entry.segment.text)")
        }
        return write(date: started, title: "Live transcript", files: ["Transcript": front + "\n" + lines.joined(separator: "\n") + "\n"])
    }
}

/// Saves the live transcript every 30 seconds while it changes, when auto-export is on.
@MainActor final class LiveTranscriptExporter {
    static let shared = LiveTranscriptExporter()
    private var task: Task<Void, Never>?
    private var written = 0
    func start(_ conversation: ConversationModel) {
        task = Task { [weak conversation] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let conversation else { return }
                let transcript = conversation.transcript
                if transcript.entries.isEmpty { self.written = 0; continue }
                guard AutoExport.enabled, transcript.entries.count != self.written,
                      let started = transcript.entries.first?.firstReceivedAt else { continue }
                AutoExport.export(live: transcript, started: started)
                self.written = transcript.entries.count
            }
        }
    }
}

/// Settings › General › Save to a folder.
struct AutoExportSection: View {
    @AppStorage(AutoExport.enabledKey) private var enabled = false
    @AppStorage(AutoExport.folderKey) private var folder = ""
    var body: some View {
        Section {
            Toggle("Save transcripts and notes automatically", isOn: $enabled).accessibilityLabel("Save transcripts and notes automatically")
            LabeledContent("Folder") {
                HStack {
                    Text((AutoExport.root.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…", action: choose)
                    Button("Show") {
                        let folder = FileManager.default.fileExists(atPath: AutoExport.root.path) ? AutoExport.root : AutoExport.root.deletingLastPathComponent()
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            }
        } header: { Text("Save to a folder") } footer: {
            Text("Markdown files with front matter, one folder per meeting by year and month, for Obsidian and other note tools: live transcripts, recordings with their notes, and Audio file transcripts. The files stay until you delete them. If iCloud syncs your Documents folder, the files go to iCloud too.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = AutoExport.root.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
