import AppKit
import SwiftUI

/// The shared look of the main window: pages on a recessed background, content in raised panels
/// with a hairline border, a header with the page's actions, and a status bar.
enum Surface {
    /// The page behind panels: darker than a panel in dark mode, lighter grey in light mode.
    static let page = Color(nsColor: .underPageBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let inset = Color(nsColor: .textBackgroundColor).opacity(0.55)
    static let border = Color(nsColor: .separatorColor)
}

struct PanelModifier: ViewModifier {
    var padding: CGFloat
    var highlight: Color?
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Surface.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(highlight?.opacity(0.7) ?? Surface.border, lineWidth: highlight == nil ? 0.5 : 1))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}

extension View {
    /// A raised panel on the page background. `highlight` colours the border, for a live state.
    func panel(padding: CGFloat = 18, highlight: Color? = nil) -> some View {
        modifier(PanelModifier(padding: padding, highlight: highlight))
    }
}

/// A small uppercase label above a group in a panel.
struct PanelLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

/// The top of a page: its title, one line about it, and its actions.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: () -> Actions
    init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.actions = actions
    }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 12)
            actions().controlSize(.regular)
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 14)
    }
}

/// A page: header, then scrolling content on the recessed background.
struct Page<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    var scrolls = true
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    init(_ title: String, subtitle: String? = nil, scrolls: Bool = true,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.scrolls = scrolls; self.actions = actions; self.content = content
    }
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title, subtitle: subtitle, actions: actions)
            Divider()
            if scrolls {
                ScrollView { content().padding(20).frame(maxWidth: .infinity, alignment: .topLeading) }
            } else {
                content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Surface.page)
    }
}

/// An empty page state: a symbol, what goes here, and how to start.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var action: () -> Action
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            action().controlSize(.large).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
