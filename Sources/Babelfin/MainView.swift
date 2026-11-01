import AppKit
import SwiftUI
import BridgeCore

/// Home: both directions side by side with their live controls, and the latest transcript lines.
/// The route and the audio devices show as one-line summaries that open popovers.
struct HomeView: View {
    @ObservedObject var conversation: ConversationModel
    var openTranscript: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ColumnsOrRows(minimumColumnWidth: 350, spacing: 16) {
                    DirectionCard(model: conversation.outgoing, incoming: false)
                    DirectionCard(model: conversation.incoming, incoming: true)
                }
                TranscriptStrip(conversation: conversation, open: openTranscript)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { if $0 == .active { refresh() } }
    }
    private func refresh() {
        for model in [conversation.outgoing, conversation.incoming] { model.refresh(); model.refreshKeyStatus() }
    }
}

/// Places its views side by side in equal columns when each column gets at least
/// `minimumColumnWidth`; otherwise it stacks them. Each row is as tall as its tallest view.
struct ColumnsOrRows: Layout {
    var minimumColumnWidth: CGFloat
    var spacing: CGFloat
    private func columns(_ width: CGFloat?, count: Int) -> Bool {
        guard let width, count > 1 else { return false }
        return (width - spacing * CGFloat(count - 1)) / CGFloat(count) >= minimumColumnWidth
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumColumnWidth * CGFloat(subviews.count)
        if columns(proposal.width, count: subviews.count) {
            let column = (width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count)
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if columns(bounds.width, count: subviews.count) {
            let column = (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count)
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (column + spacing)
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: column, height: bounds.height))
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + spacing
            }
        }
    }
}

/// `@State` needs the SwiftUI macro plugin, which the command-line toolchain lacks.
@MainActor private final class CardPopovers: ObservableObject {
    @Published var route = false
    @Published var audio = false
    @Published var timing = false
}

/// One direction: state and actions first, then what you hear, then the route and the devices.
private struct DirectionCard: View {
    @ObservedObject var model: AppModel
    let incoming: Bool
    @StateObject private var popovers = CardPopovers()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    TranslationControls(model: model, incoming: incoming, spaced: false).controlSize(.large)
                    Spacer(minLength: 8)
                    LevelMeter(level: model.level)
                        .accessibilityLabel(incoming ? "Listen input level" : "Microphone input level")
                        .accessibilityValue("\(Int(model.level * 100)) percent")
                }
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            if !model.pendingRestart.isEmpty { RestartNotice(model: model) }
            HStack(spacing: 10) {
                HearingPicker(model: model, incoming: incoming)
                Spacer(minLength: 8)
                OutputVolumeControl(model: model, incoming: incoming, compact: true)
            }
            if model.hearing == .both { originalMix }
            if !model.route.descriptor.isDirect && (model.active || !model.passageTimings.isEmpty) { timing }
            Divider()
            summaryRow("Route", routeSummary, pending: [.service, .voice, .inputLanguage, .outputLanguage, .delay], shows: $popovers.route) {
                RouteOptions(model: model, incoming: incoming)
            }
            summaryRow("Audio", "\(model.selectedInputName) → \(model.selectedOutputName)", pending: [.devices], shows: $popovers.audio) {
                AudioOptions(model: model, incoming: incoming)
            }
            review
            if !incoming && model.destination == .teams { callReadiness }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.active ? model.statusColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: model.active ? 1 : 0.5))
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: incoming ? "headphones" : "mic.fill")
                .font(.title2).foregroundStyle(model.active ? model.statusColor : Color.secondary)
                .frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(incoming ? "Listen" : "Speak").font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(title: model.sessionTitle, color: model.statusColor, busy: model.phase == .starting || model.phase == .stopping)
        }
    }
    private var subtitle: String {
        let place = model.destination == .teams && !incoming ? " · to the call" : ""
        let source = model.route.descriptor.acceptsLanguageHint && !model.sourceLanguage.isEmpty
            ? (model.capabilities.inputLanguages.first { $0.code == model.sourceLanguage }?.name ?? "Any language") : "Any language"
        return "\(source) → \(model.targetLanguageName)\(place)"
    }
    private var originalMix: some View {
        HStack(spacing: 8) {
            Text("Original").foregroundStyle(.secondary)
            Slider(value: $model.originalMixLevel, in: 0...1).frame(maxWidth: 140).accessibilityLabel("Original audio volume")
            Text(model.originalMixLevel, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 40, alignment: .trailing)
            Toggle("Lower under speech", isOn: $model.originalMixDucking).toggleStyle(.checkbox)
        }.font(.callout)
    }
    private var timing: some View {
        HStack(spacing: 8) {
            PipelineTimingView(model: model, compact: true)
            Spacer(minLength: 4)
            Button("Timing…") { popovers.timing = true }.controlSize(.small)
                .help("Shows how long each stage of the translation takes")
                .popover(isPresented: $popovers.timing, arrowEdge: .bottom) {
                    PipelineTimingView(model: model).padding(16).frame(width: 460)
                }
        }
    }
    private var routeSummary: String {
        var parts = [model.route.displayName, model.route.descriptor.isDirect ? "the voice follows the speaker" : model.voiceDisplayName]
        if !model.route.descriptor.isDirect { parts.append(model.pacing.displayName) }
        return parts.joined(separator: " · ")
    }
    private func summaryRow<Content: View>(_ title: String, _ value: String, pending: [AppModel.PendingSetting],
                                           shows: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(value).lineLimit(1).truncationMode(.middle).help(value)
            if pending.contains(where: model.pendingRestart.contains) {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    .help("Changed during translation. Choose Restart to apply it.").accessibilityLabel("Applies after Restart")
            }
            Spacer(minLength: 8)
            Button("Change…") { shows.wrappedValue = true }
                .controlSize(.small)
                .accessibilityLabel("Change \(incoming ? "Listen" : "Speak") \(title.lowercased())")
                .popover(isPresented: shows, arrowEdge: .trailing) { content().padding(20).frame(width: 440) }
        }
        .font(.callout)
    }
    @ViewBuilder private var review: some View {
        if !model.setupRequirements.isEmpty && !model.active {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.setupRequirements, id: \.self) { requirement in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
                        Text(requirement).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        reviewAction(for: requirement)
                    }
                }
            }
        }
    }
    @ViewBuilder private func reviewAction(for requirement: String) -> some View {
        let lower = requirement.lowercased()
        if lower.contains("key") {
            OpenSettingsButton(destination: .accounts, title: "Accounts…").controlSize(.small)
        } else if lower.contains("source") || lower.contains("output") || lower.contains("headphones") || lower.contains("reconnect") {
            Button("Change…") { popovers.audio = true }.controlSize(.small)
        } else if lower.contains("voice") || lower.contains("language") {
            Button("Change…") { popovers.route = true }.controlSize(.small)
        }
    }
    private var callReadiness: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Ready for calls",
                   isOn: Binding(get: { model.microphoneArmed }, set: { value in Task { await model.setMicrophoneArmed(value) } }))
                .disabled(model.phase == .stopping || model.checkingAPI || (model.active && !model.microphoneArmed))
                .help("Pass your voice through when another app uses BlackHole. Translation starts only when you choose it.")
            if model.microphoneArmed { Text(model.consumerStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }
    /// The session notice, only when it says more than the status: a problem, a resume or call readiness.
    private var notice: String? {
        let informative = model.phase == .failed || model.requiresDeviceResume || model.requiresConsumerResume
            || model.reconnecting || model.translationIssue != nil || model.microphoneArmed || model.finishingTranscript
        return informative ? model.sessionNotice : nil
    }
}

/// The route of one direction: service, voice, languages and Delay.
private struct RouteOptions: View {
    @ObservedObject var model: AppModel
    let incoming: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(incoming ? "Listen Route" : "Speak Route").font(.title3.weight(.semibold))
            Form {
                Picker("Service", selection: $model.route) {
                    ForEach(TranslationRoute.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Voice") { MainVoicePicker(model: model) }
                if model.route.descriptor.acceptsLanguageHint {
                    Picker(incoming ? "The meeting speaks" : "I speak", selection: $model.sourceLanguage) {
                        Text("Any language").tag("")
                        ForEach(model.capabilities.inputLanguages) { Text($0.name).tag($0.code) }
                    }
                }
                Picker("Translate to", selection: $model.targetLanguage) {
                    if !model.capabilities.outputLanguages.contains(where: { $0.code == model.targetLanguage }) { Text("Choose a language").tag(model.targetLanguage) }
                    ForEach(model.capabilities.outputLanguages) { Text($0.name).tag($0.code) }
                }
                if !model.route.descriptor.isDirect {
                    Picker("Delay", selection: $model.pacing) {
                        ForEach(TranslationPacing.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .help("Fast translates short passages to stay close behind the speaker. More context waits for longer passages, which can translate better but arrive later.")
                }
            }
            .formStyle(.columns)
            .disabled(model.configurationLocked)
            HStack {
                Spacer()
                OpenSettingsButton(destination: incoming ? .incoming : .outgoing, title: "More Settings…")
                    .help("Voices for speakers, text only and the original mix")
            }
        }
    }
}

/// The audio devices of one direction as form rows, shared by the Home popover and Settings › Audio devices.
struct DeviceRows: View {
    @ObservedObject var model: AppModel
    let incoming: Bool
    var body: some View {
        if !incoming {
            Picker("Use for", selection: $model.destination) {
                Text("The call").tag(AudioDestination.teams)
                Text("My headphones").tag(AudioDestination.listen)
            }.pickerStyle(.segmented)
        }
        Picker(incoming || model.destination == .listen ? "Audio source" : "Microphone", selection: $model.inputUID) {
            Text("Choose a source").tag("")
            if !model.inputUID.isEmpty && !model.inputAvailable { Text("\(model.selectedInputName) — disconnected").tag(model.inputUID) }
            ForEach(model.inputs.filter { !incoming || !$0.isPhysical }) { Text($0.name).tag($0.uid) }
        }
        Picker(model.destination == .teams && !incoming ? "Send through" : "Listen through", selection: $model.outputUID) {
            Text(model.destination == .teams && !incoming ? "Choose BlackHole" : "Choose headphones or speakers").tag("")
            if !model.outputUID.isEmpty && !model.outputAvailable { Text("\(model.selectedOutputName) — disconnected").tag(model.outputUID) }
            ForEach(model.outputs) { Text($0.name).tag($0.uid) }
        }
    }
    /// One line on how to set up the call app or the Mac for these devices.
    var help: String {
        if incoming { return "Choose this loopback as the speaker in your call app." }
        if model.destination == .teams { return "Choose this output as the microphone in your call app." }
        if model.inputs.first(where: { $0.uid == model.inputUID })?.isBlackHole == true {
            return "Set the Mac's sound output to BlackHole, then play the video. Restore it afterwards."
        }
        return "Use headphones to keep the translation out of the microphone."
    }
}

/// The Home popover for one direction's audio devices.
private struct AudioOptions: View {
    @ObservedObject var model: AppModel
    let incoming: Bool
    var body: some View {
        let rows = DeviceRows(model: model, incoming: incoming)
        VStack(alignment: .leading, spacing: 16) {
            Text(incoming ? "Listen Audio" : "Speak Audio").font(.title3.weight(.semibold))
            Form { rows }.formStyle(.columns).disabled(model.configurationLocked)
            Text(rows.help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh Devices") { model.refresh() }.disabled(model.locked)
                Spacer()
                OpenSettingsButton(destination: .audioDevices, title: "Audio Devices…")
            }
        }
    }
}

/// The state of a direction as a coloured capsule.
private struct StatusPill: View {
    let title: String
    let color: Color
    var busy = false
    var body: some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.mini) } else { Circle().fill(color).frame(width: 7, height: 7) }
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(color.opacity(color == .secondary ? 0.12 : 0.18), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// The input level as five bars, so it reads at a glance and takes little room.
struct LevelMeter: View {
    let level: Float
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Float(index) / 5 < level ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: 6 + CGFloat(index) * 3)
            }
        }
        .frame(height: 18)
        .help("Input level")
    }
}

/// The latest transcript lines of both directions: each original with its translation below it.
private struct TranscriptStrip: View {
    @ObservedObject var conversation: ConversationModel
    var open: () -> Void
    private struct Line: Identifiable {
        let id: String
        let who: String
        let incoming: Bool
        var original: String
        var translation: String?
    }
    private var lines: [Line] {
        var result: [Line] = []
        for entry in conversation.transcript.entries where !entry.segment.text.isEmpty {
            let incoming = entry.direction == .incoming
            if entry.role == .target, let last = result.indices.last, result[last].incoming == incoming, result[last].translation == nil {
                result[last].translation = entry.segment.text
            } else if entry.role != .target {
                result.append(Line(id: entry.id, who: conversation.transcript.speakerLabel(entry) ?? (incoming ? "Meeting" : "You"),
                                   incoming: incoming, original: entry.segment.text))
            }
        }
        return Array(result.suffix(4))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Transcript", systemImage: "text.bubble").font(.headline)
                Spacer()
                Button("Open full transcript", action: open).help("Window › Transcript (⌘2)")
            }
            if lines.isEmpty {
                Text("Translated speech appears here while a direction translates. It stays in memory until you clear it or quit.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(line.who).font(.caption.weight(.semibold))
                            .foregroundStyle(line.incoming ? Color.purple : Color.accentColor)
                            .frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.original).foregroundStyle(.secondary)
                            if let translation = line.translation { Text(translation) }
                        }
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}
