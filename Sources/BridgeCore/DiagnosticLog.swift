import Foundation

/// Diagnostic lines in a file for support: `~/Library/Logs/Babelfin/Babelfin.log`.
/// Callers write only closed, safe details: no audio, API keys, transcripts, notes or full URLs.
/// Each line is written when it arrives. Above 5 MB the file becomes `Babelfin.1.log` and a new
/// file starts, so the logs use at most about 10 MB. Only the app writes the file; check programs
/// and tests do not.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog(enabled: Bundle.main.bundleIdentifier == "no.tallmaker.Babelfin")
    public static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Babelfin", isDirectory: true)
    public static let maximumBytes = 5_000_000

    public let fileURL: URL
    private let enabled: Bool
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "no.tallmaker.Babelfin.DiagnosticLog", qos: .utility)
    private var handle: FileHandle?
    private var size = 0
    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    public init(folder: URL = DiagnosticLog.folder, enabled: Bool = true, maximumBytes: Int = DiagnosticLog.maximumBytes) {
        fileURL = folder.appendingPathComponent("Babelfin.log")
        self.enabled = enabled
        self.maximumBytes = maximumBytes
    }

    /// Appends one line: time, area and detail. Line breaks in the detail become spaces.
    public func write(_ area: String, _ detail: String) {
        guard enabled else { return }
        let time = Date()
        queue.async {
            let text = detail.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            self.append(Data("\(self.stamp.string(from: time))  \(area)  \(text)\n".utf8))
        }
    }

    /// A closed error kind for a log line, never a provider message: the failure reason, the
    /// tool error case or the error type.
    public static func kind(of error: Error) -> String {
        if let error = error as? SpeechToolsError { return "\(error)" }
        if error is any TranslationFailureDiagnosing { return "\(TranslationFailureReason(error: error))" }
        return "\(type(of: error))"
    }

    /// "12.3 s" since `start`, a system uptime.
    public static func elapsed(since start: TimeInterval) -> String {
        String(format: "%.1f s", ProcessInfo.processInfo.systemUptime - start)
    }

    /// Waits until every line written before this call is in the file.
    public func flush() { queue.sync {} }

    private func append(_ line: Data) {
        do {
            if handle == nil { try open() }
            if size + line.count > maximumBytes { try rotate() }
            try handle?.write(contentsOf: line)
            size += line.count
        } catch {
            try? handle?.close(); handle = nil
        }
    }
    private func open() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: fileURL.path) {
            guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let file = try FileHandle(forWritingTo: fileURL)
        size = Int(try file.seekToEnd())
        handle = file
    }
    private func rotate() throws {
        try handle?.close(); handle = nil
        let previous = fileURL.deletingLastPathComponent().appendingPathComponent("Babelfin.1.log")
        try? FileManager.default.removeItem(at: previous)
        try FileManager.default.moveItem(at: fileURL, to: previous)
        try open()
    }
}
