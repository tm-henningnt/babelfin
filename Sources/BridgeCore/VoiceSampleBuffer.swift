import Foundation

/// In-memory voice-creation sample: canonical PCM16, mono, 24 kHz. It is never written
/// to disk; the owner discards it or encodes it as WAV for an explicitly confirmed upload.
public struct VoiceSampleBuffer: Sendable {
    public static let sampleRate = 24_000
    public static let minimumSeconds = 10
    public static let maximumSeconds = 90
    public static var maximumBytes: Int { sampleRate * 2 * maximumSeconds }

    public private(set) var pcm = Data()
    public init() {}

    public var seconds: Double { Double(pcm.count / 2) / Double(Self.sampleRate) }
    public var isFull: Bool { pcm.count >= Self.maximumBytes }
    public var meetsMinimum: Bool { pcm.count >= Self.sampleRate * 2 * Self.minimumSeconds }

    /// Appends up to the limit. Returns false once the buffer is full and audio was dropped.
    @discardableResult
    public mutating func append(_ chunk: Data) throws -> Bool {
        guard chunk.count.isMultiple(of: 2) else { throw BridgeError.invalidPCM }
        let room = Self.maximumBytes - pcm.count
        guard room > 0 else { return false }
        pcm.append(chunk.prefix(room))
        return chunk.count <= room
    }

    public mutating func discard() { pcm = Data() }

    /// WAV bytes for upload. Short recordings are refused before any network request.
    public func wav() throws -> Data {
        guard meetsMinimum else {
            throw BridgeError.unavailable("Record at least \(Self.minimumSeconds) seconds of speech before creating a voice.")
        }
        return try SpeechToolsWAV.encode(pcm: pcm)
    }
}
