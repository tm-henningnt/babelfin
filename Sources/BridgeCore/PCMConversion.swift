import Foundation
import AVFoundation

/// Owns the state used by one AVAudioConverter input callback. The converter's
/// callback is Sendable in supported SDKs, so every access to its non-Sendable input
/// buffer and cursor is serialized here.
private final class ConversionInputState: @unchecked Sendable {
    private let lock = NSLock()
    private let input: AVAudioPCMBuffer
    private var offset = 0
    private var held: AVAudioPCMBuffer?
    private var copyingFailed = false

    init(input: AVAudioPCMBuffer) { self.input = input }

    var consumedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return offset
    }

    var failed: Bool {
        lock.lock(); defer { lock.unlock() }
        return copyingFailed
    }

    func next(requested: AVAudioPacketCount, flag: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard offset < Int(input.frameLength) else { flag.pointee = .noDataNow; return nil }
        let frames = min(Int(requested), Int(input.frameLength) - offset)
        guard frames > 0, let part = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: AVAudioFrameCount(frames)) else {
            copyingFailed = true; flag.pointee = .noDataNow; return nil
        }
        part.frameLength = AVAudioFrameCount(frames)
        let sources = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destinations = UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList)
        let stride = Int(input.format.streamDescription.pointee.mBytesPerFrame)
        do {
            guard sources.count == destinations.count else { throw BridgeError.invalidPCM }
            for index in 0..<sources.count {
                let offsetBytes = offset * stride
                let bytes = try AudioFrameCopy.byteCount(frames: frames, bytesPerFrame: stride,
                    sourceBytes: Int(sources[index].mDataByteSize) - offsetBytes,
                    destinationBytes: Int(destinations[index].mDataByteSize))
                guard let from = sources[index].mData, let to = destinations[index].mData else { throw BridgeError.invalidPCM }
                memcpy(to, from.advanced(by: offsetBytes), bytes)
            }
        } catch { copyingFailed = true; flag.pointee = .noDataNow; return nil }
        offset += frames
        held = part
        flag.pointee = .haveData
        return held
    }
}

/// Confined to the serial conversion queue.
public final class CaptureConversion {
    let converter: AVAudioConverter
    let sourceFormat: AVAudioFormat
    let target: AVAudioFormat
    var pending = Data()
    private var finished = false
    private let packetBytes: Int
    private let convertedPCM: (@Sendable (Data) throws -> Void)?
    private let firstStereoPair: Bool
    public init(converter: AVAudioConverter, target: AVAudioFormat, packetFrames: Int = 2400,
                convertedPCM: (@Sendable (Data) throws -> Void)? = nil, firstStereoPair: Bool = false, sourceFormat: AVAudioFormat? = nil) {
        self.converter = converter; self.target = target
        self.sourceFormat = sourceFormat ?? converter.inputFormat
        self.packetBytes = max(1, packetFrames) * 2
        self.convertedPCM = convertedPCM
        self.firstStereoPair = firstStereoPair
    }
    /// BlackHole multichannel inputs carry the meeting's stereo mix on channels1/2.
    /// Give the converter a declared stereo layout instead of an unspecified16-channel map.
    /// Physical microphone formats and their existing conversion remain unchanged.
    public convenience init(sourceFormat: AVAudioFormat, target: AVAudioFormat, loopback: Bool,
                            packetFrames: Int = 2400, convertedPCM: (@Sendable (Data) throws -> Void)? = nil) throws {
        let selectPair = loopback && sourceFormat.channelCount > 2
        guard sourceFormat.sampleRate.isFinite, sourceFormat.sampleRate > 0,
              let format = selectPair ? AVAudioFormat(standardFormatWithSampleRate: sourceFormat.sampleRate, channels: 2) : sourceFormat else {
            throw BridgeError.invalidPCM
        }
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw BridgeError.unavailable("This audio source cannot be converted to24kHz mono.")
        }
        // AVAudioConverter defaults to channel remapping, which can discard the right
        // channel. A loopback stereo programme needs both sides mixed to mono.
        if loopback, format.channelCount > 1 { converter.downmix = true }
        self.init(converter: converter, target: target, packetFrames: packetFrames, convertedPCM: convertedPCM, firstStereoPair: selectPair, sourceFormat: sourceFormat)
    }
    public func convert(_ source: AVAudioPCMBuffer) throws -> ([Data], Float) {
        guard !finished else { throw BridgeError.invalidPCM }
        // Empty callbacks must not advance converter priming or allocate a zero-capacity slice.
        guard source.frameLength > 0 else { return ([], 0) }
        let input = firstStereoPair ? try Self.stereoPair(source) : source
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw BridgeError.invalidPCM }
        // Supplying a whole buffer is permitted by AVAudioConverter, but on macOS it
        // can defer a short remainder until a later call. Feeding owned requested-size
        // slices keeps live output batches aligned with the input duration. Slice work
        // stays on the existing bounded conversion queue, never the tap/render callback.
        let inputState = ConversionInputState(input: input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { @Sendable requested, flag in
            inputState.next(requested: requested, flag: flag)
        }
        guard !inputState.failed, inputState.consumedFrames == Int(input.frameLength), error == nil, status != .error,
              let channel = output.floatChannelData?[0] else { throw BridgeError.invalidPCM }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        let pcm = PCM16.encode(samples)
        if !pcm.isEmpty { try convertedPCM?(pcm) }
        pending.append(pcm)
        var chunks: [Data] = []
        while pending.count >= packetBytes { chunks.append(Data(pending.prefix(packetBytes))); pending.removeFirst(packetBytes) }
        return (chunks, min(1, rms * 5))
    }

    /// Runs on the bounded conversion queue after the tap's existing owned-buffer copy.
    private static func stereoPair(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard source.format.commonFormat == .pcmFormatFloat32, source.format.channelCount >= 2,
              source.frameLength <= source.frameCapacity,
              let input = source.floatChannelData,
              let format = AVAudioFormat(standardFormatWithSampleRate: source.format.sampleRate, channels: 2),
              let selected = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength),
              let output = selected.floatChannelData else { throw BridgeError.invalidPCM }
        selected.frameLength = source.frameLength
        let frames = Int(source.frameLength)
        let stride = source.format.isInterleaved ? Int(source.format.channelCount) : 1
        let buffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        for channel in 0..<2 {
            let bufferIndex = source.format.isInterleaved ? 0 : channel
            guard bufferIndex < buffers.count else { throw BridgeError.invalidPCM }
            _ = try AudioFrameCopy.byteCount(frames: frames, bytesPerFrame: stride * MemoryLayout<Float>.size,
                sourceBytes: Int(buffers[bufferIndex].mDataByteSize), destinationBytes: Int.max)
            let offset = source.format.isInterleaved ? channel : 0
            for frame in 0..<frames { output[channel][frame] = input[bufferIndex][frame * stride + offset] }
        }
        return selected
    }

    /// Called once on the conversion queue after closing the capture tap.
    public func finish() throws -> [Data] {
        guard !finished else { return [] }
        finished = true
        var chunks: [Data] = []
        for _ in 0..<32 {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 2400) else { throw BridgeError.invalidPCM }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, flag in
                flag.pointee = .endOfStream
                return nil
            }
            guard error == nil, status != .error else { throw BridgeError.invalidPCM }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                let pcm = PCM16.encode(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
                try convertedPCM?(pcm)
                pending.append(pcm)
            }
            while pending.count >= packetBytes { chunks.append(Data(pending.prefix(packetBytes))); pending.removeFirst(packetBytes) }
            if status == .endOfStream {
                if !pending.isEmpty { chunks.append(pending); pending.removeAll() }
                return chunks
            }
        }
        throw BridgeError.unavailable("Audio converter did not finish within its bounded drain.")
    }
}
