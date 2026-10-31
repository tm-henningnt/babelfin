import Foundation

public struct AudioGraphHealth {
    public var routeIntact = true
    public var inputFormatValid = true
    public var outputFormatValid = true
    public var captureRunning = true
    public var playbackRunning = true
    public var inputFormatChanged = false
    public var outputFormatChanged = false
    public init() {}
}

public enum AudioRecoveryAction: Equatable {
    case unchanged
    case recover(capture: Bool, playback: Bool)
    case stopRouteChanged
    case stopFormatUnavailable
    case stopUnstable
}

/// Evaluated by the audio engine's configuration-notification handler, outside its callback queue.
public struct AudioConfigurationRecovery {
    private var attempts: [TimeInterval] = []
    public init() {}
    public mutating func evaluate(_ health: AudioGraphHealth, at uptime: TimeInterval) -> AudioRecoveryAction {
        guard health.routeIntact else { return .stopRouteChanged }
        guard health.inputFormatValid, health.outputFormatValid else { return .stopFormatUnavailable }
        let rebuildCapture = !health.captureRunning || health.inputFormatChanged
        let rebuildPlayback = !health.playbackRunning || health.outputFormatChanged
        guard rebuildCapture || rebuildPlayback else { return .unchanged }
        attempts.removeAll { uptime - $0 >= 5 || uptime < $0 }
        guard attempts.count < 3 else { return .stopUnstable }
        attempts.append(uptime)
        return .recover(capture: rebuildCapture, playback: rebuildPlayback)
    }
}
