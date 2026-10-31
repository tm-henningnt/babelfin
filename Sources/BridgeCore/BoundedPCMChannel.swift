import Foundation

/// One consumer; admitted and in-flight packets share the same duration and item budget.
/// All mutable state is protected by lock, and a packet completes exactly once.
public final class BoundedPCMChannel: @unchecked Sendable {
    public struct Packet: Sendable {
        public let id: UUID
        public let pcm: Data
        public let admittedAt: TimeInterval
    }
    public struct Snapshot: Sendable {
        public let frames: Int
        public let highWaterFrames: Int
        public let completedFrames: Int
        public let oldestAge: TimeInterval
    }
    public let stream: AsyncStream<Packet>
    private let continuation: AsyncStream<Packet>.Continuation
    private let lock = NSLock()
    private let maximumFrames: Int
    private let maximumPackets: Int
    private var accepting = false
    private var tickets: [UUID: (frames: Int, time: TimeInterval)] = [:]
    private var frames = 0
    private var highWaterFrames = 0
    private var completedFrames = 0

    public init(maximumFrames: Int = 24_000, maximumPackets: Int = 64) {
        self.maximumFrames = maximumFrames
        self.maximumPackets = maximumPackets
        var captured: AsyncStream<Packet>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingOldest(maximumPackets)) { captured = $0 }
        continuation = captured
    }
    public func open() { lock.lock(); accepting = true; lock.unlock() }
    public func append(_ pcm: Data, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard !pcm.isEmpty, pcm.count % 2 == 0 else { throw BridgeError.invalidPCM }
        lock.lock(); defer { lock.unlock() }
        guard accepting else { throw BridgeError.unavailable("Translation is not ready.") }
        let count = pcm.count / 2
        guard count <= maximumFrames - frames, tickets.count < maximumPackets else { throw BridgeError.uploadBacklog }
        let packet = Packet(id: UUID(), pcm: pcm, admittedAt: now)
        tickets[packet.id] = (count, now); frames += count
        switch continuation.yield(packet) {
        case .enqueued: highWaterFrames = max(highWaterFrames, frames)
        case .dropped, .terminated:
            tickets.removeValue(forKey: packet.id); frames -= count
            throw BridgeError.uploadBacklog
        @unknown default:
            tickets.removeValue(forKey: packet.id); frames -= count
            throw BridgeError.uploadBacklog
        }
    }
    public func complete(_ packet: Packet) {
        lock.lock(); defer { lock.unlock() }
        guard let ticket = tickets.removeValue(forKey: packet.id) else { return }
        frames -= ticket.frames; completedFrames += ticket.frames
    }
    public func snapshot(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let oldest = tickets.values.map(\.time).min() ?? now
        return Snapshot(frames: frames, highWaterFrames: highWaterFrames,
                        completedFrames: completedFrames, oldestAge: max(0, now - oldest))
    }
    public func finish() {
        lock.lock(); accepting = false; lock.unlock()
        continuation.finish()
    }
    public func cancel() {
        lock.lock(); accepting = false; tickets.removeAll(); frames = 0; lock.unlock()
        continuation.finish()
    }
}
