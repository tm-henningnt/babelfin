import AppKit
import SwiftUI
import BridgeCore

/// Subtitles: translated text in a floating window above other apps, also in full-screen
/// meetings. Captions show the latest lines in large text; Transcript shows the running
/// translated text. The window never takes focus, moves by dragging and keeps its frame.
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

enum SubtitlePreferences {
    static let style = "babelfin.subtitles.style"
    static let source = "babelfin.subtitles.source"
    static let textSize = "babelfin.subtitles.textSize"
    static let frame = "BabelfinSubtitles"
}

/// The latest translated lines for the overlay, newest last.
enum SubtitleLines {
    static func latest(_ transcript: MeetingTranscript, source: SubtitleSource, limit: Int) -> [MeetingTranscript.Entry] {
        Array(transcript.entries.lazy.filter { $0.role == .target && source.includes($0.direction)
            && !$0.segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.suffix(limit))
    }
}

struct SubtitleView: View {
    @ObservedObject var conversation: ConversationModel
    @AppStorage(SubtitlePreferences.style) private var style: SubtitleStyle = .captions
    @AppStorage(SubtitlePreferences.source) private var source: SubtitleSource = .meeting
    @AppStorage(SubtitlePreferences.textSize) private var textSize = 26.0

    var body: some View {
        let lines = SubtitleLines.latest(conversation.transcript, source: source, limit: style == .captions ? 3 : 200)
        ZStack(alignment: .topTrailing) {
            Group {
                if lines.isEmpty {
                    Text(conversation.active ? "Waiting for translated speech…" : "Start a direction to see subtitles.")
                        .font(.system(size: textSize * 0.7)).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if style == .captions {
                    VStack(alignment: .leading, spacing: 6) {
                        Spacer(minLength: 0)
                        ForEach(lines) { line(for: $0, emphasized: $0.id == lines.last?.id) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(lines) { line(for: $0, emphasized: false).id($0.id) }
                            }.padding(.trailing, 8)
                        }
                        .onChange(of: lines.last?.id) { last in if let last { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(last, anchor: .bottom) } } }
                        .onAppear { if let last = lines.last?.id { reader.scrollTo(last, anchor: .bottom) } }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Menu {
                Picker("Style", selection: $style) { ForEach(SubtitleStyle.allCases) { Text($0.title).tag($0) } }
                Picker("Show", selection: $source) { ForEach(SubtitleSource.allCases) { Text($0.title).tag($0) } }
                Button("Larger text") { textSize = min(56, textSize + 3) }
                Button("Smaller text") { textSize = max(14, textSize - 3) }
                Divider()
                Button("Hide subtitles") { SubtitleOverlay.shared.hide() }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.white.opacity(0.8)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(6)
                .accessibilityLabel("Subtitle options")
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(style == .captions ? 0.72 : 0.6)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subtitles")
    }

    private func line(for entry: MeetingTranscript.Entry, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if source == .both {
                Text(entry.direction.label).font(.system(size: textSize * 0.55, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            Text(entry.segment.text)
                .font(.system(size: emphasized || style == .transcript ? textSize : textSize * 0.82, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(.white.opacity(emphasized || style == .transcript ? 1 : 0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The floating subtitle window. A borderless, non-activating panel that joins every space.
@MainActor final class SubtitleOverlay: ObservableObject {
    static let shared = SubtitleOverlay()
    @Published private(set) var visible = false
    private var panel: NSPanel?
    private weak var conversation: ConversationModel?

    func attach(_ conversation: ConversationModel) { self.conversation = conversation }
    func toggle() { visible ? hide() : show() }
    func show() {
        guard let conversation else { return }
        if panel == nil {
            let window = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
                                       styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isFloatingPanel = true
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.minSize = NSSize(width: 320, height: 90)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let host = NSHostingView(rootView: SubtitleView(conversation: conversation))
            host.sizingOptions = [] // The window keeps its own or saved size; content never resizes it.
            window.contentView = host
            window.setContentSize(NSSize(width: 760, height: 150))
            if !window.setFrameUsingName(SubtitlePreferences.frame), let screen = NSScreen.main?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: screen.midX - 380, y: screen.minY + 60))
            }
            window.setFrameAutosaveName(SubtitlePreferences.frame)
            panel = window
        }
        panel?.orderFrontRegardless()
        visible = true
    }
    func hide() { panel?.orderOut(nil); visible = false }
}

private final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct SubtitleToggleButton: View {
    @ObservedObject private var overlay = SubtitleOverlay.shared
    var body: some View { Button(overlay.visible ? "Hide Subtitles" : "Show Subtitles") { overlay.toggle() } }
}
