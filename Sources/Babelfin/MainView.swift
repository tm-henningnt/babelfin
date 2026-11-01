import AppKit
import SwiftUI
import BridgeCore

/// One translation direction: session status and actions first, then the route as
/// aligned facts. Service, voice and original-audio mixing open the direction's Settings.
struct MainView: View {
    @ObservedObject var model: AppModel
    var incoming = false
    var showCompact: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PipelineTimingPreferences.visible) private var timingVisible = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                session
                review
                facts
                if !incoming && model.destination == .teams { Divider(); callControls }
            }
            .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refresh(); model.refreshKeyStatus() }
        .onChange(of: scenePhase) { phase in if phase == .active { model.refresh(); model.refreshKeyStatus() } }
    }
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(incoming ? "Listen" : "Speak").font(.title2.weight(.semibold))
                Text(purpose).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Compact", action: showCompact).help("Show compact controls")
                .accessibilityLabel("Show compact controls")
        }
    }
    private var purpose: String {
        if incoming { return "Hear the meeting translated into \(model.targetLanguageName) through your headphones." }
        return model.destination == .teams
            ? "Speak and be heard in \(model.targetLanguageName) through the virtual microphone."
            : "Listen to a microphone or Mac audio translated into \(model.targetLanguageName)."
    }
    private var session: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Circle().fill(model.statusColor).frame(width: 10, height: 10).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.sessionTitle).font(.headline)
                    Text(model.sessionNotice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.phase == .starting || model.phase == .stopping { ProgressView().controlSize(.small) }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Text("Input").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                ProgressView(value: Double(model.level), total: 1)
                    .tint(.accentColor).accessibilityLabel(incoming ? "Listen input level" : "Microphone input level")
                    .accessibilityValue("\(Int(model.level * 100)) percent")
            }
            HStack(spacing: 10) {
                TranslationControls(model: model, incoming: incoming, spaced: false).controlSize(.large)
                Spacer()
                Menu {
                    Button("Start original audio") { Task { await TranslationControlActions(model: model).startOriginal() } }
                        .disabled(TranslationControlActions(model: model).originalDisabled)
                    Button("Refresh devices") { model.refresh() }.disabled(model.locked)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("\(incoming ? "Listen" : "Speak") options")
            }
            if !model.pendingRestart.isEmpty { RestartNotice(model: model) }
            HStack(spacing: 10) {
                Text("Hear").foregroundStyle(.secondary)
                HearingPicker(model: model, incoming: incoming)
                Spacer()
                OutputVolumeControl(model: model, incoming: incoming)
            }
            DisclosureGroup("Timing", isExpanded: $timingVisible) {
                PipelineTimingView(model: model).padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
            .help("Shows how long each stage of the translation takes")
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
    @ViewBuilder private var review: some View {
        if !model.setupRequirements.isEmpty && !model.active {
            VStack(alignment: .leading, spacing: 0) {
                Text("Review next").font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
                ForEach(model.setupRequirements, id: \.self) { requirement in
                    Divider()
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
                        Text(requirement).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        reviewAction(for: requirement)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                Divider()
                Text("This translation uses \(model.requiredAccountNames). API usage is billed by each service and is separate from consumer subscriptions.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
    @ViewBuilder private func reviewAction(for requirement: String) -> some View {
        let lower = requirement.lowercased()
        if lower.contains("key") {
            OpenSettingsButton(destination: .accounts, title: "Accounts…")
        } else if lower.contains("voice") || lower.contains("language") && lower.contains("service") {
            OpenSettingsButton(destination: incoming ? .incoming : .outgoing, title: "Voice…")
        } else if lower.contains("reconnect") {
            Button("Refresh devices") { model.refresh() }
        } else {
            EmptyView()
        }
    }
    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            if !incoming {
                GridRow {
                    label("Use for", pending: .devices)
                    Picker("Use for", selection: $model.destination) {
                        Text("Virtual microphone").tag(AudioDestination.teams)
                        Text("My headphones").tag(AudioDestination.listen)
                    }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Destination").fixedSize()
                        .disabled(model.configurationLocked)
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            GridRow {
                label("Service", pending: .service)
                Text(model.route.displayName)
                OpenSettingsButton(destination: incoming ? .incoming : .outgoing, title: "Change…").labelStyle(.titleOnly).controlSize(.small)
            }
            GridRow {
                label("Voice", pending: .voice)
                Text(model.voiceDisplayName)
                OpenSettingsButton(destination: incoming ? .incoming : .outgoing, title: "Change…").labelStyle(.titleOnly).controlSize(.small)
            }
            GridRow {
                label("Original audio")
                Text(model.originalMixEnabled ? "Mixed under the translation" : "Off")
                OpenSettingsButton(destination: incoming ? .incoming : .outgoing, title: "Change…").labelStyle(.titleOnly).controlSize(.small)
            }
            Divider().gridCellColumns(3)
            GridRow {
                label(incoming ? "Audio source" : (model.destination == .teams ? "Microphone" : "Audio source"), pending: .devices)
                Picker("Audio source", selection: $model.inputUID) {
                    Text("Choose a source").tag("")
                    if !model.inputUID.isEmpty && !model.inputAvailable { Text("\(model.selectedInputName) — disconnected").tag(model.inputUID) }
                    ForEach(model.inputs.filter { !incoming || !$0.isPhysical }) { Text($0.name).tag($0.uid) }
                }.labelsHidden().gridCellColumns(2)
            }
            GridRow {
                label("Input language", pending: .inputLanguage)
                Group {
                    if !model.route.descriptor.acceptsLanguageHint { Text("Automatic") }
                    else {
                        Picker("Input language", selection: $model.sourceLanguage) {
                            Text("Automatic").tag("")
                            ForEach(model.capabilities.inputLanguages) { Text($0.name).tag($0.code) }
                        }.labelsHidden()
                    }
                }.gridCellColumns(2)
            }
            if !model.route.descriptor.isDirect {
                GridRow {
                    label("Delay", pending: .delay)
                    Picker("Delay", selection: $model.pacing) {
                        ForEach(TranslationPacing.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden().gridCellColumns(2)
                    .help("Fast translates short passages to stay close behind the speaker. More context waits for longer passages, which can translate better but arrive later.")
                }
            }
            GridRow {
                label("Translate to", pending: .outputLanguage)
                Picker("Translate to", selection: $model.targetLanguage) {
                    if !model.capabilities.outputLanguages.contains(where: { $0.code == model.targetLanguage }) { Text("Choose a language").tag(model.targetLanguage) }
                    ForEach(model.capabilities.outputLanguages) { Text($0.name).tag($0.code) }
                }.labelsHidden().gridCellColumns(2)
            }
            GridRow {
                label(model.destination == .teams ? "Send through" : "Listen through", pending: .devices)
                Picker("Audio output", selection: $model.outputUID) {
                    Text(model.destination == .teams ? "Choose BlackHole" : "Choose headphones or speakers").tag("")
                    if !model.outputUID.isEmpty && !model.outputAvailable { Text("\(model.selectedOutputName) — disconnected").tag(model.outputUID) }
                    ForEach(model.outputs) { Text($0.name).tag($0.uid) }
                }.labelsHidden().gridCellColumns(2)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text(routeHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .gridCellColumns(2)
            }
        }
        .disabled(model.configurationLocked)
    }
    private func label(_ text: String, pending: AppModel.PendingSetting? = nil) -> some View {
        HStack(spacing: 4) {
            Text(text).foregroundStyle(.secondary)
            if let pending, model.pendingRestart.contains(pending) {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    .help("Changed during translation. Choose Restart to apply it.")
                    .accessibilityLabel("Applies after Restart")
            }
        }.frame(width: 130, alignment: .leading)
    }
    private var callControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Ready for calls", isOn: Binding(get: { model.microphoneArmed }, set: { value in Task { await model.setMicrophoneArmed(value) } }))
                .disabled(model.phase == .stopping || model.checkingAPI || (model.active && !model.microphoneArmed))
            Text("When another app uses BlackHole, pass your voice through. Translation still starts only when you choose it. Microphone previews can also trigger this.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.microphoneArmed {
                Text(model.consumerStatus).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private var routeHelp: String {
        if incoming { return "Choose this loopback as the Teams speaker. Use a different loopback for Teams’ microphone, and listen through headphones." }
        if model.destination == .teams { return "Choose this output as the Teams microphone. Listen needs a separate loopback." }
        if model.inputs.first(where: { $0.uid == model.inputUID })?.isBlackHole == true {
            return "Send Mac audio to BlackHole in Sound settings, then play your video. All audio sent there is captured. Restore your usual output afterward."
        }
        return "Listen through headphones to keep translated speech out of your microphone."
    }
}
