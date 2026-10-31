import AVFoundation

/// Control methods run on the audio controller's thread. Held and scheduled audio share one budget.
public final class BufferedAudioPlayback {
    /// One adaptive step and its ceiling (24 kHz frames). A mid-speech underrun means the
    /// source streams near real time with jitter; the next prime holds more audio. Ten
    /// seconds of steady playback lowers the target one step, never below the start value.
    public static let jitterStepFrames = 4_800
    public static let maximumPrebufferFrames = 28_800
    static let steadyFramesPerDecrease = 240_000
    /// Speech that resumes sooner than this after draining is jitter, not a natural pause.
    static let jitterGapSeconds: TimeInterval = 1.0
    private let queue = PlaybackBufferQueue()
    private let minimumPrebufferFrames: Int
    public private(set) var prebufferFrames: Int
    private var steadyFrames = 0
    private var held: [(AVAudioPCMBuffer, PlaybackBufferReservation)] = []
    private var heldFrames = 0
    private var playing = false
    public private(set) var refillCount = 0
    public init(prebufferFrames: Int = 7200) { self.prebufferFrames = prebufferFrames; minimumPrebufferFrames = prebufferFrames }
    public var prebufferSeconds: TimeInterval { Double(prebufferFrames) / 24_000 }
    public var queuedFrames: Int { queue.queuedFrames }
    public var remainingFrames: Int { queue.remainingFrames }
    public var isBuffering: Bool { !held.isEmpty }
    public var snapshot: PlaybackMetrics { queue.snapshot }

    public func append(_ buffer: AVAudioPCMBuffer, on scheduler: any AudioBufferScheduling) throws {
        if playing && queue.queuedFrames == 0 {
            scheduler.pausePlayback()
            playing = false
            refillCount += 1
            if minimumPrebufferFrames > 0, let gap = queue.secondsSinceDrained, gap < Self.jitterGapSeconds {
                prebufferFrames = min(Self.maximumPrebufferFrames, prebufferFrames + Self.jitterStepFrames)
                steadyFrames = 0
            }
        }
        let reservation = try queue.reserve(buffer)
        if playing {
            queue.submit(buffer, reservation: reservation, on: scheduler)
            steadyFrames += Int(buffer.frameLength)
            if steadyFrames >= Self.steadyFramesPerDecrease, prebufferFrames > minimumPrebufferFrames {
                prebufferFrames = max(minimumPrebufferFrames, prebufferFrames - Self.jitterStepFrames)
                steadyFrames = 0
            }
        } else {
            held.append((buffer, reservation))
            heldFrames += Int(buffer.frameLength)
            if heldFrames >= prebufferFrames { flush(on: scheduler) }
        }
    }
    public func flush(on scheduler: any AudioBufferScheduling) {
        guard !held.isEmpty else { return }
        let batch = held
        held.removeAll()
        heldFrames = 0
        for (buffer, reservation) in batch { queue.submit(buffer, reservation: reservation, on: scheduler) }
        playing = true
        scheduler.startPlayback()
    }
    /// Production transition used by AudioWorker; keeps the current device graph.
    public func continuingOriginal(on mixer: RenderAudioMixer?) -> BufferedAudioPlayback {
        // Reset only translated reservations/held buffers. The original ring and its
        // already-consumed startup lead belong to the uninterrupted capture stream.
        reset()
        mixer?.switchToOriginal()
        return BufferedAudioPlayback(prebufferFrames: 0)
    }
    public func reset() {
        queue.reset()
        held.removeAll()
        heldFrames = 0
        playing = false
    }
}
