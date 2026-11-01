import Foundation
import CAtomicMixer

/// Places translated speech at the times of the original segments. A passage that is longer
/// than its slot plays faster, up to `maximumRate`; when it is still too long, later passages
/// move back and catch up in the next pause.
public enum DubTimeline {
    public static let maximumRate = 1.3
    /// Silence kept between two passages that would otherwise touch.
    public static let gap = 0.15

    public struct Slot: Equatable, Sendable {
        public let start: Double
        /// Seconds of the synthesized passage at its natural rate.
        public let duration: Double
        public init(start: Double, duration: Double) { self.start = start; self.duration = duration }
    }
    public struct Placement: Equatable, Sendable {
        public let start: Double
        public let rate: Double
        public let duration: Double
    }

    /// Slots must be in time order. Each passage may use the time until the next slot starts.
    public static func place(_ slots: [Slot]) -> [Placement] {
        var cursor = 0.0, result: [Placement] = []
        for (index, slot) in slots.enumerated() {
            let start = max(slot.start, cursor)
            let available = index + 1 < slots.count ? slots[index + 1].start - gap - start : .infinity
            let rate = available > 0 ? min(maximumRate, max(1, slot.duration / available)) : maximumRate
            let duration = slot.duration / rate
            result.append(Placement(start: start, rate: rate, duration: duration))
            cursor = start + duration + gap
        }
        return result
    }
}

/// Builds a dub track: each passage time-stretched to its placement, optionally mixed over the
/// original through the playback mixer, so the original ducks as it does in live translation.
public enum DubRenderer {
    /// Passages and the original are mono 24 kHz PCM16. Returns mono 24 kHz PCM16.
    public static func render(passages: [Data], placements: [DubTimeline.Placement], original: Data?,
                              originalLevel: Float) throws -> Data {
        guard passages.count == placements.count else { throw SpeechToolsError.invalidPCM }
        var track: [Float] = []
        for (pcm, placement) in zip(passages, placements) {
            let stretcher = SpeechRateStretcher()
            stretcher.setRate(placement.rate)
            let samples = try PCM16.decode(stretcher.process(pcm) + stretcher.finish())
            let start = Int(placement.start * 24_000)
            if track.count < start + samples.count { track += [Float](repeating: 0, count: start + samples.count - track.count) }
            for (offset, sample) in samples.enumerated() { track[start + offset] += sample }
        }
        guard let original else { return PCM16.encode(track) }
        let source = try PCM16.decode(original)
        let count = max(track.count, source.count)
        guard Double(count) / 24_000 <= SpeechToolsLimits.dubSeconds else { throw SpeechToolsError.dubTooLong }
        guard let mixer = bf_mixer_create(originalLevel, true, true, 0) else { throw SpeechToolsError.invalidPCM }
        defer { bf_mixer_destroy(mixer) }
        bf_mixer_playing(mixer, true)
        // Render in the mixer's quantum: feed one block of each input, then render it.
        let block = 240
        var output = [Float](repeating: 0, count: count), originalBlock = [Float](repeating: 0, count: block)
        var speechBlock = [Float](repeating: 0, count: block), rendered = [Float](repeating: 0, count: block), end: UInt64 = 0
        for start in stride(from: 0, to: count, by: block) {
            let length = min(block, count - start)
            for i in 0..<block {
                originalBlock[i] = start + i < source.count ? source[start + i] : 0
                speechBlock[i] = start + i < track.count ? track[start + i] : 0
            }
            bf_mixer_append_original(mixer, originalBlock, block)
            guard bf_mixer_schedule(mixer, speechBlock, block, &end) else { throw SpeechToolsError.invalidPCM }
            _ = bf_mixer_render(mixer, &rendered, block)
            output.replaceSubrange(start..<start + length, with: rendered[0..<length])
        }
        return PCM16.encode(output)
    }
}
