import AppKit
import SwiftUI
import OboloCore

/// The All screen's search, opened from the lens in the bottom bar or with ⌘F.
///
/// The query filters by name, case-insensitively, across every subscription whatever pill
/// is selected (the ledger's own search). Esc or ✕ clears it and folds the field away;
/// clicking elsewhere folds it only when it is empty.
struct AllSearch: Equatable {
    var isOpen = false
    var query = ""
    /// Set by ⌘F from another screen: the bottom bar opens the field once it shows All.
    var pendingOpen = false

    var isActive: Bool { isOpen && !query.trimmingCharacters(in: .whitespaces).isEmpty }
}

extension AppModel {
    /// Every subscription whose name contains `query`, in the list's sort order.
    func searchRows(_ query: String) -> [SubscriptionSummary] {
        Ledger.matching(query, in: sortedAllRows)
    }
}

// MARK: - ⌘F

extension FocusedValues {
    /// Opens the All search in the focused main window.
    @Entry var openSearch: (() -> Void)?
}

/// Edit › Find (⌘F). Placed before the system's own Find submenu so that its ⌘F answers
/// first. From Home or Calendar it moves to All and opens the search there.
struct SearchCommands: Commands {
    @FocusedValue(\.openSearch) private var openSearch

    var body: some Commands {
        CommandGroup(before: .textEditing) {
            Button("Find") { openSearch?() }
                .keyboardShortcut("f")
                .disabled(openSearch == nil)
        }
    }
}

// MARK: - Bottom bar region

/// The lens and the status line, with the search pill that grows over them.
///
/// Opening: the lens becomes the left end of a pill that widens to just short of Add
/// (0.34 s, cubic(.32,.72,0,1), no bounce), casting a dark edge shadow onto what it is
/// about to cover, which fades to 15% and slides 8pt right before sitting hidden under
/// it. The field fades in after 0.16 s and takes focus. Closing reverses it: the field
/// fades out in 0.12 s, the pill shrinks on a slower, even 0.42 s curve, and the covered
/// items come back about 0.2 s later, once the pill has passed. Reduce Motion drops the width animation and
/// the shadow.
struct SearchBarRegion: View {
    @Bindable var model: AppModel
    let scope: AllScope
    @Binding var search: AllSearch

    @State private var width: CGFloat = 0
    @State private var shadow: ShadowPhase = .none
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum ShadowPhase { case none, edge, settled }

    /// Opening: quick out of the gate, long soft landing.
    private static let curve = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.34)
    /// Closing uses a slower curve so the fold remains visible.
    private static let foldCurve = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.42)
    private static let lens: CGFloat = DS.Size.control
    /// Space left before the Add button (with the bar's 10pt spacing, about 14pt).
    private static let gapBeforeAdd: CGFloat = 4

    private var isOpen: Bool { search.isOpen }

    var body: some View {
        ZStack(alignment: .leading) {
            covered
            pill
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { consumePendingOpen() }
        .onChange(of: search.pendingOpen) { _, _ in consumePendingOpen() }
        .onChange(of: fieldFocused) { _, focused in
            // Focus moving elsewhere (Tab, another field) folds an empty field too.
            if !focused, isOpen, search.query.isEmpty { close() }
        }
    }

    // MARK: Covered items

    private var covered: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Self.lens, height: Self.lens)

            WindowStatusLine(model: model, scope: scope)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
        }
        .animation(reduceMotion ? nil : (isOpen ? .easeOut(duration: 0.2) : .easeOut(duration: 0.25).delay(0.22))) {
            $0.opacity(isOpen ? 0.15 : 1)
        }
        .animation(reduceMotion ? nil : (isOpen ? Self.curve : Self.foldCurve.delay(0.1))) {
            $0.offset(x: isOpen ? 8 : 0)
        }
        // Hidden under the pill: out of reach of the pointer, Tab and VoiceOver.
        .allowsHitTesting(!isOpen)
        .disabled(isOpen)
        .accessibilityHidden(isOpen)
    }

    // MARK: Pill

    private var pill: some View {
        HStack(spacing: 8) {
            Button {
                if isOpen { fieldFocused = true } else { open() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isOpen ? DS.Palette.ink : DS.Palette.inkMuted)
                    .frame(width: Self.lens, height: Self.lens)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .dsFocusRing(Circle())
            .help("Search subscriptions (⌘F)")
            .accessibilityLabel("Search subscriptions")

            if isOpen {
                field
                    .transition(.asymmetric(
                        insertion: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.18).delay(0.16)),
                        removal: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.12))
                    ))
            }
        }
        .padding(.trailing, isOpen ? 6 : 0)
        .frame(width: isOpen ? max(Self.lens, width - Self.gapBeforeAdd) : Self.lens, height: Self.lens, alignment: .leading)
        .background(Capsule().fill(isOpen ? DS.Palette.bg200 : .clear))
        .overlay(Capsule().strokeBorder(isOpen ? DS.Palette.lineStrong : .clear, lineWidth: DS.hairline))
        .clipShape(Capsule())
        .shadow(color: DS.Palette.shadow.opacity(shadowOpacity), radius: shadowRadius, x: shadowX)
        // A click anywhere outside the pill folds it while the field is empty. Watched
        // directly, because clicking empty parts of the window leaves the field focused.
        .background(ClickOutsideMonitor(isActive: isOpen) {
            if search.query.isEmpty { close() }
        })
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("", text: $search.query, prompt: Text("Search subscriptions").foregroundStyle(DS.Palette.inkDisabled))
                .textFieldStyle(.plain)
                .dsStyle(.body)
                .foregroundStyle(DS.Palette.ink)
                .focused($fieldFocused)
                .onExitCommand { close() }
                .accessibilityLabel("Search subscriptions")

            if search.isActive {
                let count = model.ledger.filtered(search: search.query, section: .all).count
                Text("\(count) of \(model.allCount)")
                    .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                    .foregroundStyle(DS.Palette.inkMuted)
                    .fixedSize()
            }

            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Palette.inkMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .dsFocusRing(Circle())
            .help("Close search")
            .accessibilityLabel("Close search")
        }
    }

    // MARK: Shadow

    private var shadowOpacity: Double {
        switch shadow {
        case .none: 0
        case .edge: 0.75
        case .settled: 0.25
        }
    }

    private var shadowRadius: CGFloat { shadow == .edge ? 11 : 5 }
    private var shadowX: CGFloat { shadow == .edge ? 16 : 4 }

    // MARK: Open and close

    private func consumePendingOpen() {
        guard search.pendingOpen else { return }
        search.pendingOpen = false
        open()
    }

    private func open() {
        guard !isOpen else {
            fieldFocused = true
            return
        }
        if model.section != .all { model.section = .all }
        withAnimation(reduceMotion ? nil : Self.curve) { search.isOpen = true }
        if !reduceMotion {
            // The leading edge darkens what it is about to cover, then settles.
            withAnimation(.easeOut(duration: 0.175)) { shadow = .edge }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(175))
                guard search.isOpen else { return }
                withAnimation(.easeOut(duration: 0.325)) { shadow = .settled }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 160))
            if search.isOpen { fieldFocused = true }
        }
    }

    private func close() {
        fieldFocused = false
        withAnimation(reduceMotion ? nil : Self.foldCurve) {
            search.isOpen = false
            search.query = ""
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { shadow = .none }
    }
}

// MARK: - Click outside

/// Calls `onClickOutside` for a mouse-down in the same window outside this view's frame,
/// while `isActive`. The click itself still goes where it was aimed. With `onEscape`, Esc
/// in that window calls it too, and goes no further.
struct ClickOutsideMonitor: NSViewRepresentable {
    let isActive: Bool
    var onEscape: (() -> Void)?
    let onClickOutside: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isActive = isActive && isEnabled
        context.coordinator.onClickOutside = onClickOutside
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var isActive = false
        var onClickOutside: () -> Void = {}
        var onEscape: (() -> Void)?
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return false }
                    if event.type == .keyDown { return self.escape(event) }
                    self.handle(event)
                    return false
                }
                return consumed ? nil : event
            }
        }

        /// Esc in this window while active, when someone listens for it.
        private func escape(_ event: NSEvent) -> Bool {
            guard isActive, let onEscape, event.keyCode == 53,
                  let window = view?.window, event.window === window else { return false }
            onEscape()
            return true
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard isActive, let view, let window = view.window, event.window === window else { return }
            let point = view.convert(event.locationInWindow, from: nil)
            guard !view.bounds.contains(point) else { return }
            // After the click has been delivered, so a button under it still works.
            DispatchQueue.main.async { [onClickOutside] in onClickOutside() }
        }
    }
}
