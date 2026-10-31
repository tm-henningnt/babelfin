import AVFoundation

public struct CaptureFormatSelection {
    public let format: AVAudioFormat
    public let requiresRebuild: Bool
}

/// A hardware input node cannot resample. Its tap and converter must follow its hardware
/// input format, including after a Bluetooth microphone changes its sample rate.
public enum CaptureFormatPolicy {
    public static func validateHardware(sampleRate: Double, channels: AVAudioChannelCount) throws {
        guard sampleRate.isFinite, sampleRate > 0, channels > 0 else {
            throw BridgeError.unavailable("Input audio hardware format is unavailable.")
        }
    }
    public static func select(hardware: AVAudioFormat, client: AVAudioFormat,
                              installed: AVAudioFormat?) throws -> CaptureFormatSelection {
        try validateHardware(sampleRate: hardware.sampleRate, channels: hardware.channelCount)
        return CaptureFormatSelection(format: hardware,
            requiresRebuild: !hardware.isEqual(client) || (installed.map { !hardware.isEqual($0) } ?? true))
    }
}
