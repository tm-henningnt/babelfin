import Foundation
import CoreAudio
import BridgeCore

/// App lifecycle seam: production owns native audio; checks use no hardware or credentials.
@MainActor protocol AudioPipelineControlling: AnyObject, Sendable {
    var onPCM: (@Sendable (Data) throws -> Void)? { get set }
    var onFailure: (@MainActor @Sendable (String) -> Void)? { get set }
    var onNotice: (@MainActor @Sendable (String) -> Void)? { get set }
    var onLevel: (@MainActor @Sendable (Float) -> Void)? { get set }
    func configureOriginalMix(enabled: Bool, level: Float, ducking: Bool)
    func setOutputVolume(_ volume: Float)
    func updateListening(mixEnabled: Bool, level: Float, ducking: Bool, speechMuted: Bool)
    func start(input: AudioDevice, output: AudioDevice, destination: AudioDestination, translated: Bool) throws
    nonisolated func play(_ pcm: Data) throws
    nonisolated func playTranslated(_ pcm: Data) async throws
    func translatedSink() -> TranslationAudioHandler
    func switchToTranslation(deliver: @escaping @Sendable (Data) throws -> Void) throws
    func switchToOriginal() throws
    func stop()
    func stopAndDrain() async throws
    func metricsSummary() -> String
}

extension AudioPipeline: AudioPipelineControlling {}

@MainActor protocol ConsumerMonitoring: AnyObject {
    var onChange: (@MainActor @Sendable (ConsumerObservation) -> Void)? { get set }
    func start(deviceID: AudioDeviceID)
    func stop()
}
extension CoreAudioConsumerMonitor: ConsumerMonitoring {}

extension AudioPipelineControlling {
    func translatedSink() -> TranslationAudioHandler { { [weak self] pcm in guard let self else { return }; try await self.playTranslated(pcm) } }
    func switchToTranslation(deliver: @escaping @Sendable (Data) throws -> Void) throws { throw BridgeError.unavailable("This audio route cannot resume translation.") }
    func switchToOriginal() throws { throw BridgeError.unavailable("This audio route cannot switch to original audio.") }
    func setOutputVolume(_ volume: Float) {}
    func updateListening(mixEnabled: Bool, level: Float, ducking: Bool, speechMuted: Bool) {}
}
