import Foundation

public enum PlaybackAdmissionDecision: Sendable { case admitted, wait, invalidated }

/// The native worker and deterministic fake renderer share this admission algorithm.
/// Capacity checks and scheduling must be atomic in `admit`; the callback never waits.
public struct PlaybackAdmission: Sendable {
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 5) { self.timeout = timeout }

    /// Returns the frames abandoned after a generation change. Task cancellation throws.
    public func play(_ pcm: Data,
                     admit: @escaping @Sendable (Data) throws -> PlaybackAdmissionDecision,
                     now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 10_000_000) }) async throws -> Int {
        guard pcm.count % 2 == 0 else { throw BridgeError.invalidPCM }
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = min(offset + 4800, pcm.endIndex)
            let piece = Data(pcm[offset..<end])
            let waitingSince = now()
            while true {
                try Task.checkCancellation()
                switch try admit(piece) {
                case .admitted: break
                case .invalidated: return (pcm.endIndex - offset) / 2
                case .wait:
                    guard now() - waitingSince < timeout else {
                        throw BridgeError.unavailable("Playback is not draining. Reconnect the selected output and start again.")
                    }
                    try await sleep()
                    continue
                }
                break
            }
            offset = end
        }
        return 0
    }
}
