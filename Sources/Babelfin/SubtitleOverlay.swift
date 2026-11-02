import AppKit
import Combine
import SwiftUI
import BridgeCore

/// Subtitles: translated text in a floating window above other apps, also in full-screen
/// meetings. Captions show the latest lines; Transcript shows the running text. The window never
/// takes focus, moves by dragging and keeps its frame. Settings › General sets the appearance.
enum SubtitleStyle: String, CaseIterable, Identifiable {
    case captions, transcript
    var id: String { rawValue }
    var title: String { self == .captions ? "Captions" : "Transcript" }
}

enum SubtitleSource: String, CaseIterable, Identifiable {
    case meeting, voice, both
    var id: String { rawValue }
    var title: String { switch self { case .meeting: "Listen"; case .voice: "Speak"; case .both: "Both directions" } }
    func includes(_ direction: ConversationDirection) -> Bool {
        switch self { case .meeting: direction == .incoming; case .voice: direction == .outgoing; case .both: true }
    }
}

enum SubtitleText: String, CaseIterable, Identifiable {
    case translation, both
    var id: String { rawValue }
    var title: String { self == .translation ? "Translation" : "Original and translation" }
}

enum SubtitleFont: String, CaseIterable, Identifiable {
    case system, rounded, serif, monospaced
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var design: Font.Design {
        switch self { case .system: .default; case .rounded: .rounded; case .serif: .serif; case .monospaced: .monospaced }
    }
}

enum SubtitleWeight: String, CaseIterable, Identifiable {
    case regular, medium, semibold, bold
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var weight: Font.Weight {
        switch self { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold }
    }
}

enum SubtitleColor: String, CaseIterable, Identifiable {
    case white, yellow, cyan, green
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .white: .white
        case .yellow: Color(red: 1, green: 0.88, blue: 0.3)
        case .cyan: Color(red: 0.45, green: 0.9, blue: 1)
        case .green: Color(red: 0.55, green: 0.95, blue: 0.55)
        }
    }
}

enum SubtitlePreferences {
    static let style = "babelfin.subtitles.style"
    static let source = "babelfin.subtitles.source"
    static let textSize = "babelfin.subtitles.textSize"
    static let text = "babelfin.subtitles.text"
    static let font = "babelfin.subtitles.font"
    static let weight = "babelfin.subtitles.weight"
    static let color = "babelfin.subtitles.color"
    static let opacity = "babelfin.subtitles.opacity"
    static let outline = "babelfin.subtitles.outline"
    static let outlineWidth = "babelfin.subtitles.outlineWidth"
    static let shadow = "babelfin.subtitles.shadow"
    static let lines = "babelfin.subtitles.lines"
    static let centered = "babelfin.subtitles.centered"
    static let speakers = "babelfin.subtitles.speakers"
    static let clickThrough = "babelfin.subtitles.clickThrough"
    static let frame = "BabelfinSubtitles"
}

/// One subtitle: a translation with the original it came from.
struct SubtitleLine: Identifiable, Equatable {
    let id: String
    let direction: ConversationDirection
    let speaker: String?
    let original: String?
    let translation: String
}

/// The latest translated lines for the overlay, newest last.
enum SubtitleLines {
    static func latest(_ transcript: MeetingTranscript, source: SubtitleSource, limit: Int) -> [SubtitleLine] {
        var lines: [SubtitleLine] = []
        var originals: [ConversationDirection: String] = [:]
        // Only the newest entries can produce the last lines; a long meeting holds up to 50 000.
        for entry in transcript.entries.suffix(max(60, limit * 12)) where source.includes(entry.direction) {
            let text = entry.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if entry.role == .target {
                lines.append(SubtitleLine(id: entry.id, direction: entry.direction, speaker: transcript.speakerLabel(entry),
                                          original: originals.removeValue(forKey: entry.direction), translation: text))
            } else {
                originals[entry.direction] = text
            }
        }
        return Array(lines.suffix(limit))
    }
    /// Sample lines for the Settings preview.
    static let sample = [
        SubtitleLine(id: "1", direction: .incoming, speaker: "Speaker 1", original: "Can you send the reports before Friday?",
                     translation: "Kan du sende rapportene før fredag?"),
        SubtitleLine(id: "2", direction: .outgoing, speaker: nil, original: "Ja, jeg sender dem i morgen.",
                     translation: "Yes, I will send them tomorrow."),
    ]
}

/// The subtitle text and background in the chosen appearance. The overlay and the Settings preview share it.
struct SubtitleContent: View {
    let lines: [SubtitleLine]
    var placeholder: String?
    /// The overlay fills its window; the preview sizes to its text.
    var fillsHeight = true
    @AppStorage(SubtitlePreferences.style) private var style: SubtitleStyle = .captions
    @AppStorage(SubtitlePreferences.source) private var source: SubtitleSource = .both
    @AppStorage(SubtitlePreferences.textSize) private var textSize = 26.0
    @AppStorage(SubtitlePreferences.text) private var text: SubtitleText = .translation
    @AppStorage(SubtitlePreferences.font) private var font: SubtitleFont = .system
    @AppStorage(SubtitlePreferences.weight) private var weight: SubtitleWeight = .semibold
    @AppStorage(SubtitlePreferences.color) private var color: SubtitleColor = .white
    @AppStorage(SubtitlePreferences.opacity) private var opacity = 0.72
    @AppStorage(SubtitlePreferences.outline) private var outline = false
    @AppStorage(SubtitlePreferences.outlineWidth) private var outlineWidth = 2.0
    @AppStorage(SubtitlePreferences.shadow) private var shadow = true
    @AppStorage(SubtitlePreferences.lines) private var captionLines = 2
    @AppStorage(SubtitlePreferences.centered) private var centered = true
    @AppStorage(SubtitlePreferences.speakers) private var speakers = true

    private var shown: [SubtitleLine] { style == .captions ? Array(lines.suffix(captionLines)) : lines }
    private var alignment: HorizontalAlignment { centered ? .center : .leading }
    private var frameAlignment: Alignment { centered ? .bottom : .bottomLeading }

    var body: some View {
        Group {
            if shown.isEmpty {
                Text(placeholder ?? "")
                    .font(.system(size: max(13, textSize * 0.6), design: font.design))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if style == .captions {
                VStack(alignment: alignment, spacing: textSize * 0.35) {
                    ForEach(shown) { line in block(line, current: line.id == shown.last?.id) }
                }
                .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: frameAlignment)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: alignment, spacing: textSize * 0.45) {
                            ForEach(shown) { line in block(line, current: true).id(line.id) }
                        }
                        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                        .padding(.trailing, 8)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: shown.last?.id) { last in if let last { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(last, anchor: .bottom) } } }
                    .onAppear { if let last = shown.last?.id { reader.scrollTo(last, anchor: .bottom) } }
                }
            }
        }
        .padding(.horizontal, textSize * 0.8).padding(.vertical, textSize * 0.5)
        .background {
            if opacity > 0 { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(opacity)) }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.18), value: shown.map(\.id))
    }

    private func block(_ line: SubtitleLine, current: Bool) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if (speakers && source == .both) || (speakers && line.speaker != nil) {
                Text(label(line))
                    .font(.system(size: textSize * 0.5, weight: .semibold, design: font.design))
                    .foregroundStyle(line.direction == .incoming ? Color(red: 0.8, green: 0.65, blue: 1) : Color(red: 0.55, green: 0.75, blue: 1))
                    .modifier(TextEdge(outline: outline ? outlineWidth : 0, shadow: shadow))
            }
            if text == .both, let original = line.original {
                Text(original)
                    .font(.system(size: textSize * 0.62, weight: .regular, design: font.design))
                    .foregroundStyle(.white.opacity(0.75))
                    .modifier(TextEdge(outline: outline ? outlineWidth : 0, shadow: shadow))
            }
            Text(line.translation)
                .font(.system(size: textSize, weight: weight.weight, design: font.design))
                .foregroundStyle(color.color.opacity(current ? 1 : 0.7))
                .modifier(TextEdge(outline: outline ? outlineWidth : 0, shadow: shadow))
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func label(_ line: SubtitleLine) -> String {
        line.speaker ?? (line.direction == .incoming ? "Meeting" : "You")
    }
}

/// An outline and a drop shadow keep the text readable over any video, also without a panel.
/// The outline is eight hard shadows around the glyphs.
private struct TextEdge: ViewModifier {
    let outline: Double
    let shadow: Bool
    func body(content: Content) -> some View {
        content
            .modifier(Ring(width: outline))
            .shadow(color: .black.opacity(shadow ? 0.85 : 0), radius: shadow ? 4 : 0, x: 0, y: shadow ? 2 : 0)
    }
    private struct Ring: ViewModifier {
        let width: Double
        func body(content: Content) -> some View {
            if width > 0 {
                let d = CGFloat(width), e = CGFloat(width * 0.7)
                content
                    .shadow(color: .black, radius: 0, x: d, y: 0).shadow(color: .black, radius: 0, x: -d, y: 0)
                    .shadow(color: .black, radius: 0, x: 0, y: d).shadow(color: .black, radius: 0, x: 0, y: -d)
                    .shadow(color: .black, radius: 0, x: e, y: e).shadow(color: .black, radius: 0, x: -e, y: -e)
                    .shadow(color: .black, radius: 0, x: e, y: -e).shadow(color: .black, radius: 0, x: -e, y: e)
            } else {
                content
            }
        }
    }
}

/// `@State` needs the SwiftUI macro plugin, which the command-line toolchain lacks.
@MainActor private final class SubtitleHover: ObservableObject { @Published var inside = false }

struct SubtitleView: View {
    @ObservedObject var conversation: ConversationModel
    @AppStorage(SubtitlePreferences.style) private var style: SubtitleStyle = .captions
    @AppStorage(SubtitlePreferences.source) private var source: SubtitleSource = .both
    @AppStorage(SubtitlePreferences.textSize) private var textSize = 26.0
    @StateObject private var hover = SubtitleHover()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SubtitleContent(lines: SubtitleLines.latest(conversation.transcript, source: source, limit: style == .captions ? 4 : 200),
                            placeholder: placeholder)
            if hover.inside { options.transition(.opacity) }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hover.inside = inside } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subtitles")
    }

    /// Says which direction the subtitles follow, so an empty overlay is never a mystery.
    private var placeholder: String {
        let followed = [conversation.outgoing, conversation.incoming].enumerated().filter { index, _ in
            source.includes(index == 0 ? .outgoing : .incoming) }.map(\.element)
        if followed.contains(where: \.active) { return "Waiting for translated speech…" }
        if conversation.active {
            return "Subtitles follow \(source.title). Choose Both directions in the options to see the other one."
        }
        return "Start Translate in Speak or Listen to see subtitles."
    }
    private var options: some View {
        Menu {
            Picker("Layout", selection: $style) { ForEach(SubtitleStyle.allCases) { Text($0.title).tag($0) } }
            Picker("Show", selection: $source) { ForEach(SubtitleSource.allCases) { Text($0.title).tag($0) } }
            Divider()
            Button("Larger Text") { textSize = min(64, textSize + 2) }
            Button("Smaller Text") { textSize = max(14, textSize - 2) }
            Divider()
            SubtitleSettingsButton()
            Button("Hide Subtitles") { SubtitleOverlay.shared.hide() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(6)
                .background(.black.opacity(0.55), in: Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(8)
        .accessibilityLabel("Subtitle options")
    }
}

/// Opens Settings › General, where the subtitle appearance is.
struct SubtitleSettingsButton: View {
    var body: some View { OpenSettingsButton(destination: .general, title: "Subtitle Settings…") }
}

/// Settings › General › Subtitles: every appearance option with a live preview.
struct SubtitleSettingsSection: View {
    @ObservedObject private var overlay = SubtitleOverlay.shared
    @AppStorage(SubtitlePreferences.style) private var style: SubtitleStyle = .captions
    @AppStorage(SubtitlePreferences.source) private var source: SubtitleSource = .both
    @AppStorage(SubtitlePreferences.textSize) private var textSize = 26.0
    @AppStorage(SubtitlePreferences.text) private var text: SubtitleText = .translation
    @AppStorage(SubtitlePreferences.font) private var font: SubtitleFont = .system
    @AppStorage(SubtitlePreferences.weight) private var weight: SubtitleWeight = .semibold
    @AppStorage(SubtitlePreferences.color) private var color: SubtitleColor = .white
    @AppStorage(SubtitlePreferences.opacity) private var opacity = 0.72
    @AppStorage(SubtitlePreferences.outline) private var outline = false
    @AppStorage(SubtitlePreferences.outlineWidth) private var outlineWidth = 2.0
    @AppStorage(SubtitlePreferences.shadow) private var shadow = true
    @AppStorage(SubtitlePreferences.lines) private var captionLines = 2
    @AppStorage(SubtitlePreferences.centered) private var centered = true
    @AppStorage(SubtitlePreferences.speakers) private var speakers = true
    @AppStorage(SubtitlePreferences.clickThrough) private var clickThrough = false

    var body: some View {
        Section {
            Toggle("Show subtitles", isOn: Binding(get: { overlay.visible }, set: { if $0 != overlay.visible { overlay.toggle() } })).accessibilityLabel("Show subtitles")
            preview
            Picker("Layout", selection: $style) { ForEach(SubtitleStyle.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            if style == .captions {
                Stepper("Lines: \(captionLines)", value: $captionLines, in: 1...4)
            }
            Picker("Show", selection: $source) { ForEach(SubtitleSource.allCases) { Text($0.title).tag($0) } }
            Picker("Text", selection: $text) { ForEach(SubtitleText.allCases) { Text($0.title).tag($0) } }
            Toggle("Speaker names", isOn: $speakers).accessibilityLabel("Speaker names")
        } header: { Text("Subtitles") }
        Section {
            Picker("Font", selection: $font) { ForEach(SubtitleFont.allCases) { Text($0.title).tag($0) } }
            Picker("Weight", selection: $weight) { ForEach(SubtitleWeight.allCases) { Text($0.title).tag($0) } }
            LabeledContent("Size") {
                HStack {
                    Slider(value: $textSize, in: 14...64, step: 1).frame(maxWidth: 220)
                    Text("\(Int(textSize)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            Picker("Colour", selection: $color) {
                ForEach(SubtitleColor.allCases) { option in
                    Label { Text(option.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(option.color) }.tag(option)
                }
            }
            Picker("Alignment", selection: $centered) {
                Text("Centre").tag(true)
                Text("Left").tag(false)
            }.pickerStyle(.segmented)
            LabeledContent("Background") {
                HStack {
                    Slider(value: $opacity, in: 0...1, step: 0.05).frame(maxWidth: 220)
                    Text(opacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            Toggle("Outline", isOn: $outline).accessibilityLabel("Outline")
            if outline {
                LabeledContent("Outline width") {
                    HStack {
                        Slider(value: $outlineWidth, in: 1...4, step: 0.5).frame(maxWidth: 220)
                        Text(String(format: "%.1f pt", outlineWidth)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Toggle("Shadow", isOn: $shadow).accessibilityLabel("Shadow")
            Toggle("Click through", isOn: $clickThrough).accessibilityLabel("Click through")
                .help("Clicks pass through the subtitles to the window below. Turn this off to move or resize them.")
            Button("Restore Defaults", action: restoreDefaults)
        } header: { Text("Subtitle appearance") }
    }

    private var preview: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.3), Color(red: 0.32, green: 0.36, blue: 0.4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "person.2.fill").font(.system(size: 56)).foregroundStyle(.white.opacity(0.12))
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 28)
            SubtitleContent(lines: Array(SubtitleLines.sample.filter { source.includes($0.direction) }.suffix(style == .captions ? captionLines : 4)),
                            fillsHeight: style == .transcript)
                .frame(width: 560, height: style == .captions ? nil : 140)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 14)
        }
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("Subtitle preview")
    }

    private func restoreDefaults() {
        style = .captions; source = .both; textSize = 26; text = .translation; font = .system; weight = .semibold
        color = .white; opacity = 0.72; outline = false; outlineWidth = 2; shadow = true
        captionLines = 2; centered = true; speakers = true; clickThrough = false
    }
}

/// The floating subtitle window. A borderless, non-activating panel that joins every space.
@MainActor final class SubtitleOverlay: ObservableObject {
    static let shared = SubtitleOverlay()
    @Published private(set) var visible = false
    private var panel: NSPanel?
    private weak var conversation: ConversationModel?
    private var defaultsObserver: AnyCancellable?

    func attach(_ conversation: ConversationModel) { self.conversation = conversation }
    func toggle() { visible ? hide() : show() }
    func show() {
        guard let conversation else { return }
        if panel == nil {
            let window = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 170),
                                       styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isFloatingPanel = true
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.minSize = NSSize(width: 320, height: 90)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let host = NSHostingView(rootView: SubtitleView(conversation: conversation))
            host.sizingOptions = [] // The window keeps its own or saved size; content never resizes it.
            window.contentView = host
            window.setContentSize(NSSize(width: 820, height: 170))
            if !window.setFrameUsingName(SubtitlePreferences.frame), let screen = NSScreen.main?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: screen.midX - 410, y: screen.minY + 60))
            }
            window.setFrameAutosaveName(SubtitlePreferences.frame)
            panel = window
            defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.applyClickThrough() } }
        }
        applyClickThrough()
        panel?.orderFrontRegardless()
        visible = true
    }
    func hide() { panel?.orderOut(nil); visible = false }
    private func applyClickThrough() {
        let clickThrough = UserDefaults.standard.bool(forKey: SubtitlePreferences.clickThrough)
        if panel?.ignoresMouseEvents != clickThrough { panel?.ignoresMouseEvents = clickThrough }
    }
}

private final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct SubtitleToggleButton: View {
    @ObservedObject private var overlay = SubtitleOverlay.shared
    var body: some View { Button(overlay.visible ? "Hide Subtitles" : "Show Subtitles") { overlay.toggle() } }
}
