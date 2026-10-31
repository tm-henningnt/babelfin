import Foundation
import AVFoundation
import BridgeCore

private final class TimingPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ value: Data) { lock.lock(); values.append(value); lock.unlock() }
    var packets: [Data] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Deterministic audio-clock checks. No devices, saved traces, sleeps or network.
enum CaptureTimingChecks {
    private static func render(_ mixer: RenderAudioMixer, frames: Int) -> [Float] {
        var values = [Float](repeating: 0, count: frames)
        values.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
        return values
    }
    private static func converted(rate: Double, channels: AVAudioChannelCount = 1,
                                  interleaved: Bool = false, variable: Bool = false,
                                  count: Int = 64) throws -> (stream: [Data], all: [Float]) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: channels, interleaved: interleaved)!
        let target = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let packets = TimingPackets()
        let conversion = try CaptureConversion(sourceFormat: format, target: target, loopback: channels > 1,
                                               convertedPCM: { packets.append($0) })
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        empty.frameLength = 0
        let emptyResult = try conversion.convert(empty)
        try expect(emptyResult.0.isEmpty && packets.packets.isEmpty, "Empty capture must not advance or emit converter audio")
        var sourceFrame = 0
        for index in 0..<count {
            let seconds = variable ? [0.02, 0.08, 0.03, 0.07, 0.1][index % 5] : 0.1
            let frames = Int((rate * seconds).rounded())
            let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            source.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                let value = Float(0.2 * sin(2 * .pi * 440 * Double(sourceFrame + i) / rate))
                for channel in 0..<Int(channels) {
                    if interleaved { source.floatChannelData![0][i * Int(channels) + channel] = value }
                    else { source.floatChannelData![channel][i] = value }
                }
            }
            sourceFrame += frames
            _ = try conversion.convert(AudioFrameCopy.copy(source))
        }
        let stream = packets.packets
        _ = try conversion.finish()
        let all = try packets.packets.flatMap { try PCM16.decode($0) }
        let expected = Int((Double(sourceFrame) * 24_000 / rate).rounded())
        try expect(all.count == expected, "Converter must conserve frames at \(rate)Hz, channels=\(channels), interleaved=\(interleaved)")
        let body = all[2400..<(all.count - 2400)]
        var sine = 0.0, cosine = 0.0
        for (i, value) in body.enumerated() {
            let phase = 2 * Double.pi * 440 * Double(i) / 24_000
            sine += Double(value) * sin(phase); cosine += Double(value) * cos(phase)
        }
        sine *= 2 / Double(body.count); cosine *= 2 / Double(body.count)
        var squared = 0.0
        for (i, value) in body.enumerated() {
            let phase = 2 * Double.pi * 440 * Double(i) / 24_000
            let difference = Double(value) - sine * sin(phase) - cosine * cos(phase)
            squared += difference * difference
        }
        try expect(abs(hypot(sine, cosine) - 0.2) < 0.003 && sqrt(squared / Double(body.count)) < 0.001,
                   "Joined converter samples must preserve a continuous sine at \(rate)Hz")
        return (stream, all)
    }
    static func run() throws -> Int {
        // Generated schedule:100ms input bursts,256-frame render quanta at24kHz.
        // Captures are admitted at the first quantum after each100ms boundary.
        // Old conversion produced2464/2048-frame batches and failed this comparison.
        let conversion = try converted(rate: 48_000, channels: 2)
        let mixer = RenderAudioMixer(originalLevel: 1, ducking: false, mixesTranslation: false,
                                     initialOriginalLeadFrames: RenderAudioMixer.liveOriginalLeadFrames)
        var output: [Float] = [], packet = 0, peak = 0
        for position in stride(from: 0, to: 64 * 2400, by: 256) {
            if packet < conversion.stream.count && position >= packet * 2400 {
                try mixer.appendOriginal(conversion.stream[packet]); packet += 1
                peak = max(peak, mixer.snapshot.originalFrames)
            }
            output.append(contentsOf: render(mixer, frames: 256))
        }
        let streaming = try conversion.stream.flatMap { try PCM16.decode($0) }
        let lead = RenderAudioMixer.liveOriginalLeadFrames
        let compared = min(streaming.count, output.count - lead) - 256
        try expect(output.prefix(lead).allSatisfy { $0 == 0 }, "Original startup lead must be explicit silence")
        var largestError: Float = 0
        for i in 0..<compared { largestError = max(largestError, abs(output[lead + i] - streaming[i])) }
        try expect(largestError < 0.000001 && mixer.snapshot.discardedOriginalFrames == 0 && peak <= 2880,
                   "Actual conversion→mixer burst schedule must preserve initial and steady PCM without gaps/drops")
        mixer.stop()
        print("PASS: Actual converter→mixer100ms/256-frame schedule preserves continuous PCM within120ms ring")

        for (rate, channels, interleaved) in [(16_000.0, 1, false), (24_000.0, 1, false),
                                              (44_100.0, 2, false), (48_000.0, 2, true),
                                              (96_000.0, 2, false)] {
            _ = try converted(rate: rate, channels: AVAudioChannelCount(channels), interleaved: interleaved,
                              variable: true, count: 40)
        }
        print("PASS: Variable/empty/interleaved capture preserves frame totals and waveform at16/24/44.1/48/96kHz")

        let immediate = RenderAudioMixer(originalLevel: 1, ducking: false, mixesTranslation: false)
        try immediate.appendOriginal(PCM16.encode([Float(0.2)]))
        try expect(render(immediate, frames: 1)[0] > 0.19, "Default mixer must remain immediate")
        immediate.stop()
        let original = RenderAudioMixer(originalLevel: 1, ducking: false, mixesTranslation: false, initialOriginalLeadFrames: lead)
        try expect(render(original, frames: 1024).allSatisfy { $0 == 0 }, "Before capture output must remain silent")
        let pcm = PCM16.encode([Float](repeating: 0.2, count: 512))
        try original.appendOriginal(pcm)
        let first = render(original, frames: 256)
        try expect(first.prefix(lead).allSatisfy { $0 == 0 } && first.suffix(16).allSatisfy { $0 > 0.19 },
                   "Rendering before capture must not consume the initial lead")
        _ = render(original, frames: 1024) // Deliberately drain/underrun after startup.
        try original.appendOriginal(pcm)
        try expect(render(original, frames: 1)[0] > 0.19, "Ordinary underrun must not repeatedly rearm startup hold")
        original.clearOriginal()
        _ = render(original, frames: 1024)
        try original.appendOriginal(pcm)
        let recovered = render(original, frames: 256)
        try expect(recovered.prefix(lead).allSatisfy { $0 == 0 } && recovered.suffix(16).allSatisfy { $0 > 0.19 },
                   "Capture rebuild must discard old original and rearm one bounded lead")
        original.reset()
        try original.appendOriginal(pcm)
        let reset = render(original, frames: 256)
        try expect(reset.prefix(lead).allSatisfy { $0 == 0 } && reset.suffix(16).allSatisfy { $0 > 0.19 },
                   "Full reset must rearm the original lead")
        original.stop()
        try expect(render(original, frames: 256).allSatisfy { $0 == 0 }, "Stopped mixer must remain silent")
        print("PASS: Original lead waits for capture, defaults to zero, rearms only on reset/capture rebuild")

        let mixed = RenderAudioMixer(originalLevel: 0.25, ducking: false, initialOriginalLeadFrames: lead)
        try mixed.appendOriginal(pcm)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let speech = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        speech.frameLength = 256; speech.floatChannelData![0].initialize(repeating: 0.1, count: 256)
        mixed.schedule(speech, completionType: .dataRendered, completion: { _ in })
        mixed.startPlayback()
        let a = render(mixed, frames: 128), b = render(mixed, frames: 128)
        try expect(a.allSatisfy { abs($0 - 0.08) < 0.00002 } &&
                   b.prefix(112).allSatisfy { abs($0 - 0.08) < 0.00002 } &&
                   b.suffix(16).allSatisfy { abs($0 - 0.12) < 0.00002 },
                   "Original lead must span render quanta without delaying translated samples")
        let retired = TimingPackets()
        let direct = RenderAudioMixer(originalLevel: 0.01, ducking: true, initialOriginalLeadFrames: lead)
        try direct.appendOriginal(pcm)
        direct.schedule(speech, completionType: .dataRendered, completion: { _ in retired.append(Data([1])) })
        direct.startPlayback()
        _ = render(direct, frames: 256) // Consume the initial lead before switching.
        let bufferedOriginal = direct.snapshot.originalFrames
        let queued = BufferedAudioPlayback(prebufferFrames: 7200)
        try queued.append(speech, on: direct)
        try expect(queued.queuedFrames == 256, "Transition fixture must contain held translated reservations")
        direct.schedule(speech, completionType: .dataRendered, completion: { _ in retired.append(Data([1])) })
        let continued = queued.continuingOriginal(on: direct)
        try expect(direct.snapshot.originalFrames == bufferedOriginal && queued.queuedFrames == 0 && continued.queuedFrames == 0,
                   "Production original transition must preserve captured original while discarding translation reservations")
        let switched = render(direct, frames: 128)
        try expect(switched[0] < 0.05 && zip(switched, switched.dropFirst()).allSatisfy { $0 <= $1 + 0.000001 } && switched.allSatisfy { $0 <= 0.2001 },
                   "Original switch must discard speech and fade the original up to full level without a jump")
        direct.retireRenderedCompletions()
        try expect(retired.packets.isEmpty, "Discarded translated audio must not report rendered completion")
        let beforeResume = direct.snapshot.originalFrames
        direct.switchToTranslation(originalLevel: 0, ducking: true)
        try expect(direct.snapshot.originalFrames == beforeResume, "Translation resume cleared original continuity")
        direct.schedule(speech, completionType: .dataRendered, completion: { _ in })
        try expect(render(direct, frames: 64).allSatisfy { abs($0 - 0.1) < 0.0001 }, "Disabled original mix leaked original after reconnect")
        direct.switchToOriginal()
        direct.switchToTranslation(originalLevel: 0.25, ducking: false)
        direct.schedule(speech, completionType: .dataRendered, completion: { _ in })
        let resumed = render(direct, frames: 64)
        try expect(resumed.allSatisfy { $0 >= 0.08 - 0.0001 && $0 <= 0.12 + 0.0001 } && resumed[63] > resumed[0],
                   "Translation resume must keep speech headroom and fade the original toward its configured gain")
        direct.stop()
        mixed.stop()
        print("PASS: Startup original hold never delays translated audio")
        return 4
    }
}
