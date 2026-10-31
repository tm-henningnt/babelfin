#if BABELFIN_MIXER_CHECKS
import AVFoundation
import BridgeCore
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
private final class Result: @unchecked Sendable {
    var samples = [Float](repeating: 0, count: 256)
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private func buffer(_ values: [Float]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
    result.frameLength = result.frameCapacity
    for index in values.indices { result.floatChannelData![0][index] = values[index] }
    return result
}
private func render(_ mixer: RenderAudioMixer, _ count: Int) -> [Float] {
    var result = [Float](repeating: 0, count: count)
    result.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
    return result
}
@main struct MixerConcurrencyChecks {
    static func main() throws {
        for operation in ["append", "snapshot", "retire"] {
            let mixer = RenderAudioMixer(originalLevel: 1, ducking: false, mixesTranslation: false)
            let completions = Counter()
            mixer.schedule(buffer([0]), completionType: .dataRendered) { _ in completions.increment() }
            mixer.startPlayback()
            _ = render(mixer, 1)
            require(completions.value == 0, "Render invoked a completion on the realtime lane")
            let input = (0..<1440).map { Float($0 + 1) / 2000 }
            let exact = try PCM16.decode(PCM16.encode(input))
            try mixer.appendOriginal(PCM16.encode(Array(input.prefix(960))))
            let acquired = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let producerDone = DispatchSemaphore(value: 0)
            mixer.controlCheckpoint = { name in
                if name == operation { acquired.signal(); release.wait() }
            }
            DispatchQueue.global().async {
                switch operation {
                case "append": try! mixer.appendOriginal(PCM16.encode(Array(input.suffix(480))))
                case "snapshot": _ = mixer.snapshot
                default: mixer.retireRenderedCompletions()
                }
                producerDone.signal()
            }
            require(acquired.wait(timeout: .now() + 1) == .success, "Producer did not acquire actual control lock")
            let rendered = DispatchSemaphore(value: 0)
            let result = Result()
            DispatchQueue.global().async {
                result.samples.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
                rendered.signal()
            }
            let completed = rendered.wait(timeout: .now() + 1) == .success
            // Always release the producer, even on failure, so the test cannot strand a lock.
            release.signal()
            require(producerDone.wait(timeout: .now() + 1) == .success, "Producer did not finish")
            require(completed, "Render waited for held producer/control lock")
            require(result.samples == Array(exact.prefix(256)), "Held \(operation) control lock replaced primed waveform with silence")
            require(completions.value == (operation == "retire" ? 1 : 0), "Completion retirement changed under control contention")
            mixer.controlCheckpoint = nil
            mixer.retireRenderedCompletions()
            require(completions.value == 1, "Rendered completion did not retire exactly once off render")
            let remaining = operation == "append" ? 1184 : 704
            var tail = [Float](repeating: 0, count: remaining)
            tail.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
            require(tail == Array(exact[256..<(256 + remaining)]), "Held \(operation) changed sample order/conservation")
            require(mixer.snapshot.originalFrames == 0 && mixer.snapshot.discardedOriginalFrames == 0, "No-overflow contention lost frames")
            print("PASS: held real \(operation) lock preserves waveform, nonblocking render and conservation")
        }
        try rolloverAndOverflow()
        try generationTransitions()
        try noOverflowOverlap()
        try concurrentStress()
    }
    private static func rolloverAndOverflow() throws {
        let mixer = RenderAudioMixer(originalLevel: 1, ducking: false, mixesTranslation: false)
        let start = UInt64(UInt32.max) - 127
        mixer.seedEmptyCursors(original: start, translated: start)
        let input = (0..<4000).map { Float($0 + 1) / 5000 }
        let decoded = try PCM16.decode(PCM16.encode(input))
        try mixer.appendOriginal(PCM16.encode(input))
        require(mixer.snapshot.originalFrames == 2880 && mixer.snapshot.discardedOriginalFrames == 1120,
                "Tag rollover changed fixed capacity or exact quiescent discard accounting")
        let completions = Counter()
        let speech = [Float](repeating: 0.01, count: 1024)
        mixer.schedule(buffer(speech), completionType: .dataRendered) { _ in completions.increment() }
        mixer.startPlayback()
        let output = render(mixer, 2880)
        for i in output.indices {
            require(abs(output[i] - (decoded[i + 1120] + (i < 1024 ? 0.01 : 0))) < 0.000001,
                    "Atomic sample stamp rollover reordered original/translated PCM")
        }
        mixer.retireRenderedCompletions()
        require(completions.value == 1 && mixer.snapshot.translatedFrames == 0 && mixer.snapshot.originalFrames == 0,
                "64-bit translated completion/capacity cursor failed at 32-bit stamp rollover")
        require(mixer.snapshot.discardedOriginalFrames == 1120, "Rendering changed exact discard conservation")
        mixer.clearOriginal()
        try mixer.appendOriginal(PCM16.encode([Float](repeating: 0.125, count: 3000)))
        require(mixer.snapshot.discardedOriginalFrames == 1240, "Clear/reset lost cumulative discard accounting")
        mixer.reset()
        require(mixer.snapshot.originalFrames == 0 && mixer.snapshot.discardedOriginalFrames == 1240,
                "Reset counted intentional cancellation as overflow")
        print("PASS: atomic stamp rollover, exact drop-oldest suffix/capacities and cumulative discard accounting")
    }
    private static func generationTransitions() throws {
        let mixer = RenderAudioMixer(originalLevel: 0.2, ducking: true, initialOriginalLeadFrames: 240)
        let original = try PCM16.decode(PCM16.encode([Float](repeating: 0.25, count: 2000)))
        try mixer.appendOriginal(PCM16.encode(original))
        let old = BufferedAudioPlayback(prebufferFrames: 0)
        try old.append(buffer([Float](repeating: 0.4, count: 1000)), on: mixer)
        _ = render(mixer, 480)
        let originalBefore = mixer.snapshot.originalFrames
        let fresh = old.continuingOriginal(on: mixer)
        require(old.queuedFrames == 0 && mixer.snapshot.translatedFrames == 0, "Mode cancellation retained old translated generation")
        let direct = render(mixer, 256)
        // Original mode fades up to unity over 80 ms; the startup lead must not rearm.
        require(direct[0] > 0 && zip(direct, direct.dropFirst()).allSatisfy { $0 <= $1 + 0.000001 } && direct.allSatisfy { $0 <= original[0] },
                "Original mode rearmed the startup lead or did not fade up toward unity")
        require(mixer.snapshot.originalFrames == originalBefore - 256, "Mode transition lost original frames")
        mixer.retireRenderedCompletions()
        mixer.switchToTranslation(originalLevel: 0, ducking: false)
        try fresh.append(buffer([Float](repeating: 0.125, count: 480)), on: mixer)
        require(render(mixer, 480).allSatisfy { $0 == 0.125 }, "Fresh translated sink replayed canceled audio or stalled")
        mixer.retireRenderedCompletions()
        require(fresh.queuedFrames == 0 && fresh.snapshot.renderedFrames == 480, "Fresh sink completion attached to stale cursor")
        try fresh.append(buffer([Float](repeating: 0.75, count: 480)), on: mixer)
        mixer.reset(); fresh.reset()
        require(render(mixer, 256).allSatisfy { $0 == 0 }, "Reset replayed pending original/translation")
        let afterReset = BufferedAudioPlayback(prebufferFrames: 0)
        try afterReset.append(buffer([Float](repeating: 0.0625, count: 480)), on: mixer)
        require(render(mixer, 480).allSatisfy { $0 == 0.0625 }, "Reset reused live translated slots or stale generation")
        mixer.retireRenderedCompletions()
        require(afterReset.queuedFrames == 0, "Post-reset completion did not retire")
        mixer.stop()
        try mixer.appendOriginal(PCM16.encode([Float](repeating: 0.8, count: 480)))
        mixer.schedule(buffer([Float](repeating: 0.8, count: 480)), completionType: .dataRendered) { _ in fatalError("Stopped completion replayed") }
        mixer.reset(); mixer.startPlayback(); mixer.switchToTranslation(originalLevel: 1, ducking: true)
        require(render(mixer, 1024).allSatisfy { $0 == 0 } && mixer.snapshot.originalFrames == 0 && mixer.snapshot.translatedFrames == 0,
                "Stop was re-enabled or replayed by later reset/control calls")
        print("PASS: original lead and fade to unity, mode cancellation, fresh translated sink, reset and irreversible Stop")
    }
    private static func noOverflowOverlap() throws {
        let mixer = RenderAudioMixer(originalLevel: 1, ducking: false, mixesTranslation: false)
        let values = (0..<(960 + 100 * 256)).map { Float(sin(Double($0) * 0.037)) * 0.7 }
        let decoded = try PCM16.decode(PCM16.encode(values))
        try mixer.appendOriginal(PCM16.encode(Array(values.prefix(960))))
        let begin = DispatchSemaphore(value: 0)
        let appended = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for index in 0..<100 {
                begin.wait()
                let start = 960 + index * 256
                try! mixer.appendOriginal(PCM16.encode(Array(values[start..<(start + 256)])))
                appended.signal()
            }
            done.signal()
        }
        for index in 0..<100 {
            begin.signal()
            let output = render(mixer, 256)
            require(output == Array(decoded[(index * 256)..<((index + 1) * 256)]), "Overlapping no-overflow producer changed phase/waveform")
            require(appended.wait(timeout: .now() + 1) == .success, "Overlapping producer stalled")
        }
        require(done.wait(timeout: .now() + 1) == .success, "Overlapping producer did not finish")
        require(render(mixer, 960) == Array(decoded.suffix(960)) && mixer.snapshot.discardedOriginalFrames == 0,
                "No-overflow overlapping publication changed exact frame conservation")
        print("PASS: overlapping real appends preserve exact no-overflow waveform/phase/conservation")
    }
    private static func concurrentStress() throws {
        let mixer = RenderAudioMixer(originalLevel: 1, ducking: false, mixesTranslation: false)
        let done = DispatchSemaphore(value: 0)
        let consumed = Counter()
        // Unique increasing PCM16 positions stay exactly representable. Both lanes
        // deliberately overlap beyond120ms capacity; gaps are permitted only as
        // counted oldest-frame drops, never replay/torn/zero samples.
        DispatchQueue.global().async {
            var previous: Float = 0
            for _ in 0..<1000 {
                let block = render(mixer, 64)
                for value in block where value != 0 {
                    require(value > previous, "Concurrent overwrite replayed/reordered a tagged slot")
                    previous = value; consumed.increment()
                }
            }
            done.signal()
        }
        for offset in stride(from: 0, to: 30000, by: 240) {
            let values = (offset..<(offset + 240)).map { Float($0 + 1) / 32767 }
            try mixer.appendOriginal(PCM16.encode(values))
        }
        require(done.wait(timeout: .now() + 3) == .success, "Concurrent overwrite render stalled")
        var remaining = render(mixer, mixer.snapshot.originalFrames)
        remaining.removeAll { $0 == 0 }
        require(UInt64(consumed.value + remaining.count) + mixer.snapshot.discardedOriginalFrames == 30000,
                "Concurrent tagged overwrite lost uncounted positions")
        require(mixer.snapshot.originalFrames == 0, "Concurrent original capacity did not drain")
        // Overlap explicit reset/mode/Stop publication with an active reader. Each
        // operation must finish without the render lane acquiring a control lock.
        let modeMixer = RenderAudioMixer(originalLevel: 0.2, ducking: true)
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<2000 { _ = render(modeMixer, 256) }
            stopped.signal()
        }
        for index in 0..<200 {
            try modeMixer.appendOriginal(PCM16.encode([Float](repeating: 0.25, count: 480)))
            modeMixer.schedule(buffer([Float](repeating: 0.125, count: 480)), completionType: .dataRendered) { _ in }
            modeMixer.startPlayback()
            if index % 3 == 0 { modeMixer.switchToOriginal() }
            if index % 3 == 1 { modeMixer.switchToTranslation(originalLevel: 0.2, ducking: true) }
            if index % 3 == 2 { modeMixer.reset() }
        }
        modeMixer.stop()
        require(stopped.wait(timeout: .now() + 3) == .success, "Reset/mode/Stop overlapped render stalled")
        require(render(modeMixer, 256).allSatisfy { $0 == 0 }, "Concurrent Stop left replayable output")
        print("PASS: concurrent tagged overwrite conservation and overlapping reset/mode/Stop")
    }
}
#endif
