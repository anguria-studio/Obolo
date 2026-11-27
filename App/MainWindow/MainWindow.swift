import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OboloCore

/// The main window: a 640 × 640 instrument with one panel.
///
/// Each screen uses the same window layout:
/// the top bar holds the traffic lights and the centred Home · Calendar · All switch,
/// one `bg200` panel sits 8pt in from the window edge, and the bottom bar holds `⋮`,
/// the tools, a mono status line and the one orange button.
///
/// The top bar is the window toolbar with its background and item glass hidden, so
/// macOS still supplies the traffic lights, the drag area and the bar height. A detail
/// column does not fit beside the panel, so a selected subscription replaces it and the
/// top bar gains a back button (`AppModel.isShowingSubscriptionDetail`).
///
/// The window is also the app's drop target: a CSV dropped anywhere on it is the third
/// door into `ImportCoordinator`, alongside ⌘I and the Data pane's button.
struct MainWindow: View {
    @Bindable var model: AppModel

    /// The All screen's pill and category: kept while the window is open, back to
    /// Active and no category on relaunch.
    @State private var allScope = AllScope()
    /// The All search: open or not, and what is typed.
    @State private var search = AllSearch()
    /// The row just added, lit for a moment when All opens on it.
    @State private var flashedRow: Subscription.ID?
    /// Home's ⚠ list.
    @State private var isAttentionOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which Home charts have built in this window. Replaced when the window closes, since
    /// macOS may keep a closed window's views alive and show them again on reopen.
    @State private var homeBuildLog = HomeBuildLog()
    /// Home's identity for this opening of the window; a new one rebuilds Home's state.
    @State private var windowSession = UUID()
    /// The first subscription, just saved: Home fills its empty slab with it before
    /// moving on (see `EmptyHomeView`). Forgotten when the window closes.
    @State private var firstSlab: Subscription.ID?

    private var windowContent: some View {
        VStack(spacing: 0) {
            panel
                .padding(.horizontal, DS.Size.gutter)
                .padding(.bottom, model.storeRecovery == nil ? 0 : DS.Size.gutter)

            if model.storeRecovery == nil {
                WindowBottomBar(
                    model: model,
                    allScope: allScope,
                    search: $search,
                    isAttentionOpen: $isAttentionOpen,
                    onSetDate: { model.presentEdit($0, focus: .firstPayment) }
                )
            }
        }
        .frame(width: DS.Size.window, height: DS.Size.window - DS.Size.topBar)
        .background(DS.Palette.bg100)
        .foregroundStyle(DS.Palette.ink)
        .overlay(alignment: .bottom) { undoToast }
        // The form is a separate overlay. Remove the covered controls from the key loop.
        .disabled(model.isFormPresented)
        .allowsHitTesting(!model.isFormPresented)
        .accessibilityHidden(model.isFormPresented)
    }

    var body: some View {
        windowContent
        .toolbar {
            WindowToolbar(
                model: model,
                showsMonthPicker: !model.hasNoSubscriptions && firstSlab == nil
            )
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(model.sectionTitle)
        .containerBackground(DS.Palette.bg100, for: .window)
        // ⌘F: search All. From Home, Calendar or a subscription it moves to All first.
        .focusedSceneValue(\.openSearch, searchAction)
        // Leaving the lists closes the search, so it never reappears half typed.
        .onChange(of: model.section) { _, section in
            if section == .overview || section == .calendar { search = AllSearch() }
        }
        // A reopened window builds Home's charts again: forget what this one played.
        .onDisappear {
            // The shared month starts from the current one when the window reopens.
            model.showCurrentMonth()
            homeBuildLog = HomeBuildLog()
            windowSession = UUID()
            firstSlab = nil
        }
        .background(WindowSurface(hidesWindowButtons: model.isFormPresented))
        // Every sheet (New subscription, Edit, Import CSV) is drawn here, over the
        // dimmed window (see `addFormOverlay`), rather than as a native sheet.
        .overlay { addFormOverlay }
        // Needs attention is Home's ⚠ list and a category is a filter on All, not
        // sections of their own: the View menu and anything else that asks for them
        // lands here.
        .onChange(of: model.section, initial: true) { _, section in
            switch section {
            case .attention:
                model.section = .overview
                isAttentionOpen = model.fixableCount > 0
            case .category(let id):
                allScope.category = id
                model.section = .all
            default:
                break
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.isFormPresented)
        .alert(
            deleteTitle,
            isPresented: deleteAlertPresented,
            presenting: model.pendingDelete
        ) { id in
            Button("Delete", role: .destructive) { model.delete(id) }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: { _ in
            Text("Obolo also removes its calendar events. You can undo this for a few seconds.")
        }
        // Drop a CSV anywhere on the window. The whole window rather than a strip of it:
        // there is no "drop zone" in this design, and aiming at one would be worse than
        // the gesture it replaces.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers, _ in
            ImportCoordinator.handleDrop(providers: providers, model: model)
        }
    }

    private var searchAction: (() -> Void)? {
        guard !model.isFormPresented else { return nil }
        return {
            if model.isShowingSubscriptionDetail { model.closeSubscriptionDetail() }
            if model.section == .overview || model.section == .calendar { model.section = .all }
            search.pendingOpen = true
        }
    }

    // MARK: - Panel

    /// The one panel: the recovery screen, the subscription detail, Home, or Calendar
    /// and All inside the shared `dsPanel` frame.
    @ViewBuilder
    private var panel: some View {
        if let recovery = model.storeRecovery {
            RecoveryPanel(recovery: recovery, model: model)
        } else {
            let showsDetail = model.isShowingSubscriptionDetail
            ZStack {
                if model.section == .overview {
                    // Keep Home mounted so Back restores the legend's exact scroll offset.
                    HomeView(model: model, month: model.isShowingCurrentMonth ? nil : model.shownMonth, firstSlab: $firstSlab)
                        .environment(\.homeBuildLog, homeBuildLog)
                        .id(windowSession)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(showsDetail ? 0 : 1)
                        .disabled(showsDetail)
                        .allowsHitTesting(!showsDetail)
                        .accessibilityHidden(showsDetail)
                } else if !showsDetail {
                    panelContent.dsPanel()
                }

                if showsDetail {
                    SubscriptionDetail(model: model) { id in
                        model.presentEdit(id, focus: .newPriceChange)
                    }
                    .environment(\.homeBuildLog, homeBuildLog)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        let framedContent = content.frame(maxWidth: .infinity, maxHeight: .infinity)
        if #available(macOS 26.0, *) {
            // Keep the calendar pager from tinting the window toolbar.
            framedContent.scrollEdgeEffectHidden(true, for: .top)
        } else {
            framedContent
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .calendar:
            CalendarScreen(model: model)
        default:
            // One list for every list section. The section and the sort happen in
            // `model.rows`; the chip narrows the All section further.
            AllListView(
                model: model,
                scope: $allScope,
                query: search.isActive ? search.query : "",
                flashedRow: flashedRow
            )
        }
    }

    // MARK: - New subscription

    /// The window dims under `#0b0b0c` at 72% and the 580 × 600 sheet sits 20pt from the
    /// top. It fades and scales from 98% in 0.2 s; Reduce Motion keeps only the fade.
    @ViewBuilder
    private var addFormOverlay: some View {
        if model.isFormPresented, let sheet = model.activeSheet {
            ZStack(alignment: .top) {
                // Lighter in light: black at 14% rather than bg000 at 72%.
                DS.Palette.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity)

                formSheet(sheet)
                    .id(sheet.id)
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isModal)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
            // Out to the window's own top edge, under the top bar, so 20pt is measured
            // from the window.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func formSheet(_ sheet: WindowSheet) -> some View {
        switch sheet.content {
        case .add(let prefill):
            subscriptionForm(.add(prefill), sheetID: sheet.id)
        case .duplicate(let copy):
            subscriptionForm(.duplicate(copy), sheetID: sheet.id)
        case .edit(let id, let focus):
            if let subscription = model.subscription(id) {
                subscriptionForm(.edit(subscription, focus: focus), sheetID: sheet.id)
            }
        case .reactivate(let subscription):
            subscriptionForm(.edit(subscription, focus: .name), sheetID: sheet.id)
        case .importPreview(let preview):
            ImportPreviewSheet(preview: preview, model: model, sheetID: sheet.id)
        }
    }

    private func subscriptionForm(_ mode: SubscriptionForm.Mode, sheetID: WindowSheet.ID) -> some View {
        SubscriptionForm(
            model: model,
            mode: mode,
            sheetID: sheetID,
            onAdded: landOnAll,
            onDeleted: {
                model.section = .all
                model.selectSubscriptionRow(nil)
            }
        )
    }

    /// After Add: the sheet closes onto All, the filter that holds the new row, and the
    /// row lit in `bg300` that fades over a second. The very first subscription lands on
    /// Home instead, where the empty slab fills in with it.
    private func landOnAll(_ subscription: Subscription) {
        if model.document.subscriptions.count == 1, model.document.subscriptions.first?.id == subscription.id {
            model.selectSubscriptionRow(nil)
            model.section = .overview
            model.showCurrentMonth()
            firstSlab = subscription.id
            return
        }
        model.section = .all
        model.selectSubscriptionRow(nil)
        search = AllSearch()
        allScope.pill = subscription.status.isBilling ? .active : .inactive
        // The new row must be in view: drop a category that would hide it.
        if allScope.category != subscription.categoryID { allScope.category = nil }
        flashedRow = subscription.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 1.0)) { flashedRow = nil }
        }
    }

    // MARK: - Undo

    /// The five-second promise the delete alert makes, made visible.
    ///
    /// `AppModel` already expires the snapshot on a timer, so this only has to follow
    /// `canUndoDelete`; there is no second clock to keep in step with the first.
    /// After a delete: "Netflix deleted · Undo · ⌘Z" in a pill centred above the
    /// bottom bar. It fades in rising 4pt, stays six seconds (the
    /// clock stops while the pointer is on it), and a new delete replaces it.
    @ViewBuilder
    private var undoToast: some View {
        if model.canUndoDelete, let name = model.lastDeletedName {
            UndoMessage(name: name, onUndo: model.undoDelete, onHover: model.holdUndo)
                .id(model.undoMessageID)
                .padding(.bottom, 72)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 4))
                        .animation(.easeOut(duration: 0.14)),
                    removal: .opacity.animation(.easeOut(duration: 0.2))
                ))
        }
    }

    // MARK: - Delete alert

    private var deleteTitle: String {
        guard let name = model.subscription(model.pendingDelete)?.name else {
            return "Delete subscription?"
        }
        return "Delete “\(name)”?"
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { model.pendingDelete != nil },
            set: { if !$0 { model.pendingDelete = nil } }
        )
    }
}

// MARK: - Previews

#Preview("Window · Home") {
    MainWindow(model: .handoffPreview())
}

#Preview("Window · Calendar") {
    let model = AppModel.handoffPreview()
    model.section = .calendar
    return MainWindow(model: model)
}

#Preview("Window · All") {
    let model = AppModel.handoffPreview()
    model.section = .all
    return MainWindow(model: model)
}

#Preview("Window · Subscription") {
    let model = AppModel.handoffPreview()
    model.section = .all
    model.selectSubscriptionRow(model.rows.first?.id)
    return MainWindow(model: model)
}

#Preview("Window · Subscription · price changes") {
    // Netflix at 11,99 €, then 12,99 €, then 13,99 €; the next payment is two days out.
    let model = AppModel.handoffPreview { document in
        guard let index = document.subscriptions.firstIndex(where: { $0.name == "Netflix" }) else { return }
        document.subscriptions[index].priceChanges = [
            PriceChange(effectiveFrom: SampleData.billingDay(2025, 2, 24), price: 11.99, currency: "EUR"),
            PriceChange(effectiveFrom: SampleData.billingDay(2025, 9, 24), price: 12.99, currency: "EUR"),
        ]
        document.subscriptions[index].currentPriceSince = SampleData.billingDay(2026, 3, 24)
    }
    model.section = .all
    model.selectSubscriptionRow(model.document.subscriptions.first { $0.name == "Netflix" }?.id)
    return MainWindow(model: model)
}

#Preview("Window · Subscription · one price") {
    let model = AppModel.handoffPreview()
    model.section = .all
    model.selectSubscriptionRow(model.document.subscriptions.first { $0.name == "Spotify Premium" }?.id)
    return MainWindow(model: model)
}
