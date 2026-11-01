import Charts
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
    /// Compact controls show the line without the stage bar.
    var showsBar = true
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

    /// The stage names of this route, for the legend and the table.
    private func name(_ stage: PassageTiming.Stage) -> String {
        let stages = model.route.descriptor.stages
        switch stage {
        case .translation: return "Translation (\(stages[1].service?.displayName ?? stages[1].displayName))"
        case .voice: return "Voice (\(stages[2].service?.displayName ?? "system voice"))"
        case .waiting: return "Waiting for the previous passage"
        }
    }
    private static func color(_ stage: PassageTiming.Stage) -> Color {
        switch stage { case .translation: .blue; case .voice: .purple; case .waiting: .orange }
    }

    /// The last passage as one bar: each stage's share of the time to translated speech.
    private func stageBar(_ last: PassageTiming) -> some View {
        let scale = max(3, timings.map(\.totalSeconds).max() ?? 0)
        return GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(last.stages, id: \.stage) { part in
                    Rectangle().fill(Self.color(part.stage))
                        .frame(width: max(2, geometry.size.width * part.seconds / scale))
                        .help("\(name(part.stage)): \(seconds(part.seconds))")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10).clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityElement().accessibilityLabel("Last passage: " + last.stages.map { "\(name($0.stage)) \(seconds($0.seconds))" }.joined(separator: ", "))
    }

    /// The last passages, one stacked bar each, with the median time to speech as a dashed line.
    private var history: some View {
        Chart {
            ForEach(Array(timings.enumerated()), id: \.offset) { index, timing in
                ForEach(timing.stages, id: \.stage) { part in
                    BarMark(x: .value("Passage", String(index + 1)), y: .value("Seconds", part.seconds), width: .ratio(0.6))
                        .foregroundStyle(by: .value("Stage", name(part.stage)))
                }
            }
            if let median = median(\.totalSeconds) {
                RuleMark(y: .value("Median", median)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
            }
        }
        .chartForegroundStyleScale(domain: PassageTiming.Stage.allCases.map(name), range: PassageTiming.Stage.allCases.map(Self.color))
        .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text(seconds(v)) } } } }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 140)
        .accessibilityLabel("Time to translated speech for the last \(timings.count) passages")
    }

    private func compactLine(_ last: PassageTiming) -> some View {
        var parts = ["\(seconds(last.totalSeconds)) to speech"]
        if let value = last.translateSeconds { parts.append("translate \(seconds(value))") }
        if let value = last.voiceSeconds { parts.append("voice \(seconds(value))") }
        parts.append("wait \(seconds(last.waitSeconds))")
        return VStack(alignment: .leading, spacing: 4) {
            if showsBar { stageBar(last) }
            Text("\(seconds(last.totalSeconds)) to speech · median \(seconds(median(\.totalSeconds) ?? last.totalSeconds))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                .accessibilityLabel("Last passage timing: " + parts.joined(separator: ", "))
        }
    }

    private func table(_ last: PassageTiming) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            stageBar(last)
            if timings.count > 1 { history }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                    Text("Stage").foregroundStyle(.secondary)
                    Text("Last").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text("Median of \(timings.count)").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
                row("Passage heard", last.passageSeconds, median(\.passageSeconds))
                row(name(.translation), last.translateSeconds, median(\.translateSeconds), .translation)
                row(name(.voice) + ", first audio", last.voiceSeconds, median(\.voiceSeconds), .voice)
                row(name(.waiting), last.waitSeconds, median(\.waitSeconds), .waiting)
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

    @ViewBuilder private func row(_ title: String, _ last: Double?, _ median: Double?, _ stage: PassageTiming.Stage? = nil) -> some View {
        GridRow {
            HStack(spacing: 6) {
                if let stage { Circle().fill(Self.color(stage)).frame(width: 8, height: 8).accessibilityHidden(true) }
                Text(title)
            }
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
