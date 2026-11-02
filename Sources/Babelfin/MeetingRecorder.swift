import AVFoundation
import Combine
import BridgeCore

/// Records a meeting into temporary files: the microphone, and for an online meeting also the
/// meeting audio from the Listen loopback, as separate tracks. It only reads inputs; it never
/// plays audio or changes a device. Each capture is bound to its device ID, so the system default
/// input is never opened. The files live in this app's temporary folder and are deleted on
/// discard, on a new recording, at quit, and at the next launch.
@MainActor final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()
    enum State: Equatable { case idle, recording, stopped }
    @Published private(set) var state = State.idle
    @Published private(set) var seconds: Double = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var meetingLevel: Float = 0
    @Published private(set) var kind = MeetingRecordingKind.online
    @Published private(set) var startedAt: Date?
    @Published private(set) var notice = ""
    /// The tracks of the current recording: the microphone first.
    private(set) var tracks: [URL] = []
    private var captures: [(DeviceInputCapture, AudioDevice)] = []
    private var sinks: [RecorderSink] = []
    private var writers: [TrackWriter] = []
    private var starting = false
    private var watch: Task<Void, Never>?
    private var generation = UUID()

    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Babelfin recordings", isDirectory: true)

    var hasRecording: Bool { state == .stopped && !tracks.isEmpty && seconds > 0 }

    /// At launch: keeps the newest recording left by an earlier session, for example after a crash,
    /// as a stopped recording, and deletes everything else in the folder.
    func recoverLeftovers() {
        let manager = FileManager.default
        let items = (try? manager.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sessions = items.filter { manager.fileExists(atPath: $0.appendingPathComponent("microphone.pcm").path) }
            .sorted { modified($0) > modified($1) }
        for item in items where item != sessions.first { try? manager.removeItem(at: item) }
        guard let session = sessions.first else { return }
        let microphone = session.appendingPathComponent("microphone.pcm"), meeting = session.appendingPathComponent("meeting.pcm")
        let bytes = ((try? manager.attributesOfItem(atPath: microphone.path))?[.size] as? Int) ?? 0
        guard bytes >= MeetingRecordingLimits.bytesPerSecond else { try? manager.removeItem(at: session); return }
        tracks = manager.fileExists(atPath: meeting.path) ? [microphone, meeting] : [microphone]
        kind = tracks.count == 2 ? .online : .room
        startedAt = modified(session); seconds = Double(bytes) / Double(MeetingRecordingLimits.bytesPerSecond)
        state = .stopped
        notice = "Babelfin kept a recording from the last session. Transcribe, save or discard it."
    }
    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func start(kind: MeetingRecordingKind, microphone: AudioDevice, meeting: AudioDevice?) async {
        guard state != .recording, !starting else { return }
        starting = true; defer { starting = false }
        notice = ""
        guard microphone.isPhysicalInput else { notice = "Choose a microphone for Speak in Settings › Audio devices."; return }
        if kind == .online {
            guard let meeting, !meeting.isPhysicalInput else {
                notice = "Choose the meeting loopback as the Listen audio source in Settings › Audio devices."; return
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { notice = "Allow microphone access in System Settings to record."; return }
        default: notice = "Allow microphone access in System Settings › Privacy & Security › Microphone to record."; return
        }
        discard()
        let token = UUID(); generation = token
        let directory = Self.folder.appendingPathComponent(token.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sources = kind == .online ? [microphone, meeting].compactMap { $0 } : [microphone]
            for (index, device) in sources.enumerated() {
                let url = directory.appendingPathComponent(index == 0 ? "microphone.pcm" : "meeting.pcm")
                let writer = try TrackWriter(url: url)
                let capture = try DeviceInputCapture(device: device.id)
                guard let target = AVAudioFormat(standardFormatWithSampleRate: Double(MeetingRecordingLimits.sampleRate), channels: 1) else {
                    throw BridgeError.unavailable("The recording format is unavailable.")
                }
                let sink = RecorderSink(format: capture.format, conversion: try CaptureConversion(
                    sourceFormat: capture.format, target: target, loopback: !device.isPhysicalInput, packetFrames: 2_400))
                let isMicrophone = index == 0
                sink.onConverted = { [weak self, writer] chunks, level in
                    for chunk in chunks { writer.append(chunk) }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        if isMicrophone { self.microphoneLevel = level } else { self.meetingLevel = level }
                    }
                }
                tracks.append(url); writers.append(writer)
                try capture.start { frames, buffers in sink.copy(frames: frames, buffers: buffers) }
                captures.append((capture, device)); sinks.append(sink)
            }
            self.kind = kind; startedAt = Date(); seconds = 0; state = .recording
            watch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, self.generation == token else { return }
                    self.tick()
                }
            }
        } catch {
            stopCaptures(); removeFiles()
            try? FileManager.default.removeItem(at: directory)
            notice = (error as? BridgeError)?.localizedDescription ?? "The recording could not start."
        }
    }

    /// Keeps what was recorded, including the samples still in the converters.
    func stop() {
        guard state == .recording else { return }
        stopCaptures()
        for (sink, writer) in zip(sinks, writers) { sink.drain().forEach(writer.append) }
        sinks = []
        seconds = Double(writers.first?.bytes ?? 0) / Double(MeetingRecordingLimits.bytesPerSecond)
        writers.forEach { $0.close() }
        state = .stopped
    }

    /// Deletes the recording and its files.
    func discard() {
        stopCaptures(); sinks = []
        writers.forEach { $0.close() }
        removeFiles()
        state = .idle; seconds = 0; startedAt = nil; notice = ""
    }

    private func tick() {
        seconds = Double(writers.first?.bytes ?? 0) / Double(MeetingRecordingLimits.bytesPerSecond)
        if writers.contains(where: \.full) {
            stop(); notice = "The recording stopped at the 8-hour limit."
        } else if !captures.allSatisfy({ capture, device in
            capture.isRunning && AudioDevices.cached().contains { $0.id == device.id && $0.uid == device.uid }
        }) {
            stop(); notice = "An audio source disconnected. The recording stopped and keeps what it has."
        } else if let failure = writers.compactMap(\.failure).first {
            stop(); notice = failure
        }
    }
    private func stopCaptures() {
        generation = UUID()
        watch?.cancel(); watch = nil
        captures.forEach { $0.0.stop() }; captures = []
        microphoneLevel = 0; meetingLevel = 0
    }
    private func removeFiles() {
        if let directory = tracks.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: directory) }
        tracks = []; writers = []
    }
}

/// Appends PCM to one track file on the converter's queue. It stops at the 8-hour limit.
final class TrackWriter: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var written = 0
    private var closed = false
    private var error: String?
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BridgeError.unavailable("The recording file could not be created.")
        }
        self.url = url
        handle = try FileHandle(forWritingTo: url)
    }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return written }
    var full: Bool { bytes >= MeetingRecordingLimits.maximumBytes }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return error }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, error == nil, written < MeetingRecordingLimits.maximumBytes else { return }
        let part = chunk.prefix(MeetingRecordingLimits.maximumBytes - written)
        do { try handle.write(contentsOf: part); written += part.count }
        catch { self.error = "The recording could not be written. Free some disk space and record again." }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}

