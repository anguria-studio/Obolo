import AppKit
import Observation
import SwiftUI
import OboloCore

/// The preferences window behind ⌘,.
///
/// The Settings scene places the tab row below the window controls. Each pane uses
/// `PrefComponents` for its cards and native controls for editing.
///
/// The window is 640 wide, like the main window, and sizes itself vertically to the
/// pane on screen, between a floor and a ceiling; past the ceiling the pane scrolls.
///
/// Three panes edit the *document* rather than the settings — the category
/// list, the rate table, import and backup all live in `StoreDocument` — so this view
/// needs `AppModel` as well as `SettingsStore`.
struct PreferencesView: View {

    let settings: SettingsStore

    let model: AppModel

    init(settings: SettingsStore, model: AppModel) {
        self.settings = settings
        self.model = model
    }

    @State private var route = PreferencesRoute.shared

    var body: some View {
        VStack(spacing: 0) {
            if let recovery = model.storeRecovery, recovery.newerVersion != nil {
                RecoveryPanel(recovery: recovery, model: model)
            } else {
                // Keep the tabs in place while the window resizes.
                PrefTabBar(selection: $route.tab)
                    .padding(.top, PrefMetrics.tabBarTop)
                    .padding(.bottom, PrefMetrics.tabBarGap)

                pane
                    .id(route.tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // Pinned to the top: while the window grows or shrinks to the next pane, the
        // tabs stay where they are and only the bottom edge moves.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Palette.bg100.ignoresSafeArea())
        .containerBackground(DS.Palette.bg100, for: .window)
        .background(WindowSurface(title: route.tab.title))
        .background(SettingsWindowSizer(height: route.windowHeight))
        .tint(DS.Palette.accent)
        // A pinned width; the height is the window's, which `SettingsWindowSizer` sets to
        // the pane on screen. The content fills it from the top, so while the window
        // changes height only the bottom edge moves, keeping the tabs in place.
        .frame(width: PrefMetrics.width)
        .frame(minHeight: PrefMetrics.minHeight, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var pane: some View {
        switch route.tab {
        case .general: GeneralPane(settings: settings, model: model)
        case .reminders: RemindersPane(settings: settings, model: model)
        case .categories: CategoriesPane(model: model)
        case .currencies: CurrenciesPane(model: model)
        case .data: DataPane(model: model)
        #if OBOLO_DIRECT
        case .updates: UpdatesPane()
        #endif
        }
    }
}

// MARK: - Window height

/// Resizes Settings to fit the selected pane, keeping the top edge fixed. Only
/// subsequent changes in height animate.
private struct SettingsWindowSizer: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> SizerView { SizerView() }

    func updateNSView(_ view: SizerView, context: Context) {
        view.target = height
        view.apply()
    }

    final class SizerView: NSView {
        var target: CGFloat = 0
        private var hasSized = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hasSized = false
            apply()
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, self.target > 0 else { return }
                window.styleMask.remove(.resizable)
                window.titleVisibility = .hidden
                // The pane's height is measured below the title bar; the whole window,
                // title bar strip included, stops at the main window's 640, past which
                // the pane scrolls under the fixed tab row.
                let current = window.contentLayoutRect.height
                let titlebar = window.frame.height - current
                let target = min(self.target, PrefMetrics.maxWindowHeight - titlebar)
                guard abs(current - target) > 0.5 else {
                    self.hasSized = true
                    return
                }
                var frame = window.frame
                let delta = target - current
                frame.size.height += delta
                frame.origin.y -= delta
                let animate = self.hasSized && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                window.setFrame(frame, display: true, animate: animate)
                self.hasSized = true
            }
        }
    }
}

// MARK: - Metrics

/// The few numbers the panes have to agree on.
enum PrefMetrics {
    /// The main window's width.
    static let width: CGFloat = 640
    /// The tab tiles and the gap under them, above every pane.
    static let tabBarTop: CGFloat = 10
    static let tabBarHeight: CGFloat = 48
    static let tabBarGap: CGFloat = 10
    /// A floor, so a short pane is not a letterbox…
    static let minHeight: CGFloat = 360
    /// …and a ceiling for the pane, past which it scrolls…
    static let maxHeight: CGFloat = 720
    /// …and for the whole window: the main window's height.
    static let maxWindowHeight: CGFloat = 640
    /// What the window opens at for the blink before the pane has measured itself.
    static let defaultHeight: CGFloat = 480
    /// How far a pane's content has to grow or shrink before the window is resized.
    /// Sub-point jitter between two layout passes is not a new height, and re-applying
    /// the window frame mid-scroll is what used to throw the scroll position away.
    static let heightEpsilon: CGFloat = 1

}

// MARK: - Pane height

/// How a pane tells the window how tall it wants to be.
///
/// A grouped `Form` on macOS *is* a scroll view, and a scroll view has no natural
/// height to offer — which is why the window would otherwise open at SwiftUI's flat
/// 450 pt and cut the longer panes off with nothing to scroll. So each pane reads the
/// height of its own scrolled content from the inside and hands it to the route, which
/// is what `PreferencesView` sizes the window from. Past the ceiling the number is
/// clamped and the form scrolls the rest.
///
/// What is measured matters, and getting it wrong is a loop. A *frame* inside the
/// scroll view — `frame(in: .scrollView).maxY` on the last row — moves as the user
/// scrolls, so every scroll produced a new "content height", which re-applied the
/// window frame, which reset the scroll position: the content appeared to scroll back
/// up under the user's fingers. A *size* does not move. `ScrollGeometry.contentSize`
/// is the size of the scrolled content itself, so it is the same number at the top of
/// the pane and at the bottom of it, and the same number whether or not the window has
/// been clamped to the ceiling — at 720 the form's visible height is 720 while its
/// content stays as tall as it really is.
extension View {
    /// Applied to the pane's `Form`, which is the scroll view: the height reported is
    /// the form's whole content, not the part of it currently on screen.
    func measuringPaneHeight(_ tab: PreferencesTab) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height
        } action: { _, height in
            PreferencesRoute.shared.recordPaneHeight(height, for: tab)
        }
    }
}

// MARK: - Routing

/// Which tab the window opens on.
enum PreferencesTab: String, Hashable, CaseIterable {
    case general
    case reminders
    case categories
    case currencies
    case data
    #if OBOLO_DIRECT
    case updates
    #endif
}

/// The one piece of state the Settings window shares with the rest of the app.
///
/// `openSettings()` opens the window but says nothing about *where* — and the attention
/// list's fix for a missing rate is only useful if it lands on the currency table. A singleton rather
/// than an environment value because the Settings scene is not inside any view's
/// environment: the caller sets the tab, then opens the window, and the window reads it
/// on the way up.
@MainActor
@Observable
final class PreferencesRoute {
    static let shared = PreferencesRoute()

    var tab: PreferencesTab = .general

    /// How tall each pane's content turned out to be, filled in by
    /// `measuringPaneHeight(_:)` as each pane lays itself out. Per tab, so switching
    /// tabs resizes the window immediately from the remembered number rather than
    /// stepping through the outgoing pane's height first.
    private(set) var paneHeights: [PreferencesTab: CGFloat] = [:]

    /// Takes a fresh measurement from a pane, and ignores it unless it is genuinely a
    /// different height. Every write here can move the window, so the threshold is what
    /// keeps repeated identical measurements — a pane re-laying itself out, a scroll,
    /// a hover — from resizing the window at all.
    func recordPaneHeight(_ height: CGFloat, for tab: PreferencesTab) {
        guard height > 0 else { return }
        if let known = paneHeights[tab], abs(known - height) <= PrefMetrics.heightEpsilon { return }
        paneHeights[tab] = height
    }

    /// The height the window should be for the pane on screen: that pane's content,
    /// floor and ceiling applied. A tab that has not measured itself yet — the blink
    /// before its first layout — opens at the default rather than at the floor.
    var windowHeight: CGFloat {
        guard let measured = paneHeights[tab], measured > 0 else { return PrefMetrics.defaultHeight }
        let height = measured + PrefMetrics.tabBarTop + PrefMetrics.tabBarHeight + PrefMetrics.tabBarGap
        return min(max(height, PrefMetrics.minHeight), PrefMetrics.maxHeight)
    }

    private init() {}
}

// MARK: - Preview

#Preview("Preferences") {
    PreferencesView(settings: .preview(), model: .handoffPreview())
}
