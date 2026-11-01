import Foundation

/// Streaming WSOLA time stretch for 24 kHz mono speech. Rate 1 passes audio through
/// unchanged; rates above 1 shorten speech and rates below 1 lengthen it, without changing its pitch. Synthesized
/// speech can lag continuous input, and only some voice services accept a speed setting.
/// One synthesis stream owns an instance and calls it sequentially.
public final class SpeechRateStretcher: @unchecked Sendable {
    public static let minimumRate = 0.9
    public static let maximumRate = 1.5
    private let frame = 480          // 20 ms analysis window
    private let hop = 240            // output hop (50% overlap)
    private let tolerance = 120      // ±5 ms similarity search
    private let window: [Float]
    private var input: [Float] = []
    private var inputPosition = 0.0  // fractional read position of the next frame in `input`
    private var tail: [Float]        // second half of the previous output frame, awaiting overlap
    private var previousNatural: [Float]? // continuation of the last frame, the WSOLA similarity target
    public private(set) var rate: Double = 1
    private let range: ClosedRange<Double>

    /// `range` limits `setRate`. Live catch-up uses the default; a voice clip may go slower.
    public init(range: ClosedRange<Double> = minimumRate...maximumRate) {
        self.range = range
        window = (0..<480).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 480)) }
        tail = [Float](repeating: 0, count: 240)
    }

    /// Sets the rate for audio processed from now on; the change is gradual by construction.
    public func setRate(_ value: Double) {
        rate = value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : 1
    }

    /// Returns stretched PCM16 for the PCM16 chunk; output may lag input by one frame.
    public func process(_ pcm: Data) throws -> Data {
        let samples = try PCM16.decode(pcm)
        if rate == 1 && input.isEmpty && previousNatural == nil { return pcm }
        input.append(contentsOf: samples)
        var output: [Float] = []
        while Int(inputPosition) + frame + tolerance * 2 <= input.count {
            let nominal = Int(inputPosition) + tolerance
            let start = bestStart(near: nominal)
            for i in 0..<hop { output.append(tail[i] + input[start + i] * window[i]) }
            for i in 0..<hop { tail[i] = input[start + hop + i] * window[hop + i] }
            previousNatural = Array(input[(start + hop)..<(start + hop + frame / 2)])
            inputPosition += Double(hop) * rate
            let consumed = max(0, Int(inputPosition) - tolerance)
            if consumed > 4_800 { input.removeFirst(consumed); inputPosition -= Double(consumed) }
        }
        return PCM16.encode(output)
    }

    /// Drains buffered audio at the end of an utterance and resets the stream state.
    public func finish() -> Data {
        guard !input.isEmpty || previousNatural != nil else { reset(); return Data() }
        var output = Array(tail)
        let remaining = Int(inputPosition) + tolerance
        if remaining < input.count { output.append(contentsOf: input[(remaining + hop)...].prefix(Int.max)) }
        reset()
        return PCM16.encode(output)
    }

    public func reset() {
        input.removeAll(); inputPosition = 0; previousNatural = nil
        tail = [Float](repeating: 0, count: hop)
    }

    /// Picks the frame start within ±tolerance whose first half best continues the previous frame.
    private func bestStart(near nominal: Int) -> Int {
        guard let target = previousNatural else { return nominal }
        var best = nominal, bestScore = -Float.infinity
        for offset in stride(from: -tolerance, through: tolerance, by: 2) {
            let start = nominal + offset
            guard start >= 0, start + frame <= input.count else { continue }
            var score: Float = 0
            for i in stride(from: 0, to: target.count, by: 2) { score += target[i] * input[start + i] }
            if score > bestScore { bestScore = score; best = start }
        }
        return best
    }
}

/// The speaking rate for a direct route whose translated speech arrives faster than it plays,
/// so the delay stays steady instead of growing with every long passage.
public enum CatchUpRate {
    public static func forBacklog(seconds: Double) -> Double {
        if seconds > 6 { return 1.3 }
        if seconds > 3 { return 1.15 }
        return 1
    }
}
