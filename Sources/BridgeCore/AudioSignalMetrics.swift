import Foundation

/// Numeric signal statistics only. No audio samples or speech content are retained.
public struct AudioSignalMetrics: Sendable {
    public private(set) var samples: UInt64 = 0
    public private(set) var nonzeroSamples: UInt64 = 0
    public private(set) var peak: Double = 0
    private var sumSquares: Double = 0
    public init() {}
    public var rms: Double { samples == 0 ? 0 : sqrt(sumSquares / Double(samples)) }
    public mutating func recordPCM16(_ pcm: Data) throws {
        guard pcm.count % 2 == 0 else { throw BridgeError.invalidPCM }
        pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                let integer = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                let value = Double(integer) / 32768
                samples += 1
                if integer != 0 { nonzeroSamples += 1 }
                peak = max(peak, abs(value))
                sumSquares += value * value
            }
        }
    }
}

/// Detects absent valid frames, not acoustic silence. Reset for each capture generation.
public struct CaptureProgressWatchdog: Sendable {
    private let timeout: TimeInterval
    private var lastFrames: UInt64 = 0
    private var lastProgress: TimeInterval = 0
    public init(timeout: TimeInterval = 5) { self.timeout = timeout }
    public mutating func reset(at now: TimeInterval) { lastFrames = 0; lastProgress = now }
    public mutating func isStalled(frames: UInt64, at now: TimeInterval) -> Bool {
        if frames != lastFrames || now < lastProgress {
            lastFrames = frames
            lastProgress = now
            return false
        }
        return now - lastProgress >= timeout
    }
}
