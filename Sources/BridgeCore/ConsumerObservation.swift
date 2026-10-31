import Foundation

public enum ConsumerObservation: Equatable, Sendable {
    case unsupported, unknown, idle, active

    public static func matches(processID: Int32, ownProcessID: Int32, runningInput: Bool,
                               inputDevices: [UInt32], selectedDevice: UInt32) -> Bool {
        processID != ownProcessID && runningInput && inputDevices.contains(selectedDevice)
    }
}

/// An uncertain observation never proves that a microphone consumer has gone away.
public struct ConsumerDebouncer: Sendable {
    private var candidate: ConsumerObservation = .unknown
    private var since: TimeInterval = 0
    public private(set) var value: ConsumerObservation = .unknown
    public init() {}
    public mutating func update(_ observation: ConsumerObservation, at now: TimeInterval) -> ConsumerObservation {
        if observation == .unknown || observation == .unsupported {
            candidate = observation; value = observation; since = now
        } else {
            if observation != candidate { candidate = observation; since = now }
            if now - since >= 0.5 { value = observation }
        }
        return value
    }
}
