import SwiftUI
import BridgeCore

enum PipelineTimingPreferences {
    static let visible = "babelfin.pipelineTiming.visible"
}

/// Stage times of a composed route, measured per recognized passage. The clock starts when
/// recognition ends a passage after the speaker's pause and stops when the first translated
/// audio reaches playback.
struct PipelineTimingView: View {
    @ObservedObject var model: AppModel
    var compact = false
    private var timings: [PassageTiming] { model.passageTimings }

    var body: some View {
        if model.route.descriptor.isDirect {
            Text("\(model.route.displayName) recognizes, translates and speaks in one step, so Babelfin cannot time each stage." + (model.route == .openAI ? " In tests the translation followed the speaker by about 8 seconds." : ""))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if let last = timings.last {
            if compact { compactLine(last) } else { table(last) }
        } else {
            Text(model.active && !model.bypass ? "Timing appears after the first translated passage." : "Timing appears while this direction translates.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func compactLine(_ last: PassageTiming) -> some View {
        var parts = ["\(seconds(last.totalSeconds)) to speech"]
        if let value = last.translateSeconds { parts.append("translate \(seconds(value))") }
        if let value = last.voiceSeconds { parts.append("voice \(seconds(value))") }
        parts.append("wait \(seconds(last.waitSeconds))")
        return Text("Last passage: " + parts.joined(separator: " · ") + " · median \(seconds(median(\.totalSeconds) ?? last.totalSeconds))")
            .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(2)
            .accessibilityLabel("Last passage timing: " + parts.joined(separator: ", "))
    }

    private func table(_ last: PassageTiming) -> some View {
        let speech = model.route == .fish ? "Fish Audio" : "ElevenLabs"
        return VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                    Text("Stage").foregroundStyle(.secondary)
                    Text("Last").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text("Median of \(timings.count)").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
                row("Passage heard", last.passageSeconds, median(\.passageSeconds))
                row("Translation (OpenAI)", last.translateSeconds, median(\.translateSeconds))
                row("Voice, first audio (\(speech))", last.voiceSeconds, median(\.voiceSeconds))
                row("Waiting for the previous passage", last.waitSeconds, median(\.waitSeconds))
                Divider().gridCellColumns(3)
                GridRow {
                    Text("Pause to translated speech").fontWeight(.semibold)
                    Text(seconds(last.totalSeconds)).fontWeight(.semibold)
                    Text(median(\.totalSeconds).map(seconds) ?? "–").fontWeight(.semibold)
                }
                GridRow {
                    Text("Speaking rate")
                    Text(String(format: "%.2f×", last.rate))
                    Text(median(\.rate).map { String(format: "%.2f×", $0) } ?? "–")
                }
            }
            .font(.callout).monospacedDigit()
            Text(footnote(last)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pipeline timing")
    }

    private func footnote(_ last: PassageTiming) -> String {
        var text = String(format: "Times start when recognition ends a passage, %.2f s after the speaker pauses (Delay: %@). Playback adds about 0.3 s.",
                          model.pacing.commitSilenceSeconds, model.pacing.displayName)
        if last.preparedAhead { text += " The last passage was translated and voiced while the previous one played." }
        return text
    }

    @ViewBuilder private func row(_ title: String, _ last: Double?, _ median: Double?) -> some View {
        GridRow {
            Text(title)
            Text(last.map(seconds) ?? "–")
            Text(median.map(seconds) ?? "–")
        }
    }

    private func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

    private func median(_ key: KeyPath<PassageTiming, Double?>) -> Double? { Self.median(timings.compactMap { $0[keyPath: key] }) }
    private func median(_ key: KeyPath<PassageTiming, Double>) -> Double? { Self.median(timings.map { $0[keyPath: key] }) }
    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
