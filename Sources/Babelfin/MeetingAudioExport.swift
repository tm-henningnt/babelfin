import AVFoundation
import BridgeCore

/// Reads the track files in blocks, so an 8-hour recording never sits in memory as PCM.
enum MeetingAudioExport {
    static let blockBytes = MeetingRecordingLimits.bytesPerSecond * 10

    /// Mixes the tracks and calls `body` with each block of mixed PCM16.
    static func mixed(_ tracks: [URL], check: () throws -> Void, _ body: (Data) throws -> Void) throws {
        let handles = try tracks.map { try FileHandle(forReadingFrom: $0) }
        defer { handles.forEach { try? $0.close() } }
        while true {
            try check()
            let blocks = try handles.map { try $0.read(upToCount: blockBytes) ?? Data() }
            guard blocks.contains(where: { !$0.isEmpty }) else { return }
            try body(blocks.dropFirst().reduce(blocks[0]) { MeetingAudio.mix($0, $1) })
        }
    }

    /// The mixed recording as AAC in an M4A file, for upload or for saving.
    static func m4a(_ tracks: [URL], to url: URL, check: () throws -> Void = {}) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: MeetingRecordingLimits.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: MeetingRecordingLimits.uploadBitRate]
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(MeetingRecordingLimits.sampleRate),
                                         channels: 1, interleaved: true) else { throw SpeechToolsError.invalidRecording }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try mixed(tracks, check: check) { block in
            let frames = AVAudioFrameCount(block.count / 2)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let target = buffer.int16ChannelData?[0] else { return }
            block.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for index in 0..<Int(frames) { target[index] = Int16(littleEndian: samples[index]) }
            }
            buffer.frameLength = frames
            try file.write(from: buffer)
        }
    }

    /// The mixed recording as a 24 kHz mono PCM16 WAV file.
    static func wav(_ tracks: [URL], to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw SpeechToolsError.invalidRecording }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(count: 44))
        var length = 0
        try mixed(tracks, check: {}) { block in try handle.write(contentsOf: block); length += block.count }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: SpeechToolsWAV.header(dataBytes: length, sampleRate: MeetingRecordingLimits.sampleRate))
    }

    /// Microphone activity per half second, read in blocks.
    static func activity(_ track: URL) throws -> [Bool] {
        let handle = try FileHandle(forReadingFrom: track)
        defer { try? handle.close() }
        var result: [Bool] = []
        while let block = try handle.read(upToCount: blockBytes), !block.isEmpty { result += MeetingAudio.activity(block) }
        return result
    }
}
