import Foundation
import Combine
import BridgeCore

/// Audio bytes counted on the capture and playback threads, folded into the ledger on the main actor.
final class UsageMeter: @unchecked Sendable {
    let route: TranslationRoute
    private let lock = NSLock()
    private var sent = 0, received = 0
    init(route: TranslationRoute) { self.route = route }
    func countSent(_ bytes: Int) { lock.withLock { sent += bytes } }
    func countReceived(_ bytes: Int) { lock.withLock { received += bytes } }
    /// PCM16 mono 24 kHz bytes since the last drain.
    func drain() -> (sent: Int, received: Int) { lock.withLock { defer { sent = 0; received = 0 }; return (sent, received) } }
}

/// The usage totals since the last reset, kept in preferences on this Mac.
@MainActor final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    private static let key = "babelfin.usage.v1"
    @Published private(set) var ledger: UsageLedger
    private var meters: [ObjectIdentifier: UsageMeter] = [:]
    private var timer: Timer?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ledger = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(UsageLedger.self, from: $0) } ?? UsageLedger(since: Date())
    }
    func begin(_ meter: UsageMeter) {
        meters[ObjectIdentifier(meter)] = meter
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in UsageStore.shared.drainAll() } }
        }
    }
    func end(_ meter: UsageMeter) {
        drain(meter)
        meters[ObjectIdentifier(meter)] = nil
        if meters.isEmpty { timer?.invalidate(); timer = nil }
        persist()
    }
    func addText(route: TranslationRoute, recognized: Int, translated: Int, spoken: Bool) {
        ledger.addText(route: route.descriptor, recognized: recognized, translated: translated, spoken: spoken)
        persist()
    }
    func reset() { ledger.reset(at: Date()); persist() }
    private func drainAll() { meters.values.forEach(drain); persist() }
    private func drain(_ meter: UsageMeter) {
        let bytes = meter.drain()
        guard bytes.sent > 0 || bytes.received > 0 else { return }
        ledger.addAudio(route: meter.route.descriptor, secondsSent: Double(bytes.sent) / 48_000, secondsReceived: Double(bytes.received) / 48_000)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.key) }
    }
}
