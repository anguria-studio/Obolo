import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import OboloCore

@main
struct OboloApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    /// A plain `let`, not `@State`: it is created once, never replaced, and it has to
    /// be readable from `init` — which is the last moment early enough to catch a
    /// notification that launched the app.
    private let responder = NotificationResponder()

    @Environment(\.openWindow) private var openWindow

    init() {
        let storeURL: URL
        let deviceStateURL: URL
        let cloudSyncStateURL: URL
        let iconsDirectory: URL
        do {
            storeURL = try AppPaths.storeURL()
            deviceStateURL = try AppPaths.deviceStateURL()
            cloudSyncStateURL = try AppPaths.cloudSyncStateURL()
            iconsDirectory = try AppPaths.iconsDirectory()
        } catch {
            preconditionFailure(
                "Obolo cannot access its App Group container. Check the signing entitlements."
            )
        }

        LogoStore.configureSharedDirectory(iconsDirectory)
        let cloudSyncService = CloudKitSyncService(
            stateStore: CloudSyncStateStore(url: cloudSyncStateURL),
            iconsDirectory: iconsDirectory
        )
        let model = AppModel(
            store: DocumentStore(url: storeURL),
            deviceStateStore: DeviceStateStore(url: deviceStateURL),
            cloudSyncService: cloudSyncService
        )
        _model = State(initialValue: model)
        UNUserNotificationCenter.current().delegate = responder

        // The menu bar item, and the services a launch with no window still needs:
        // reminders and calendar sync are wired here rather than waiting for a scene.
        StatusItemController.shared.install(model: model)
        Self.installServices(model: model)
        // Here, not from a window: a login launch may never build one, and quitting
        // from the status item must still write the pending debounced save. Not before
        // the document is read, when the model holds only the seeded template and a
        // write would put it over the real file.
        AppDelegate.flushBeforeTerminate = { [model] in
            guard model.isLoaded else { return }
            try? await model.flushSave()
        }
        // The one-time dark-logo pass, once the document has been read.
        Task { @MainActor in
            while !model.isLoaded { try? await Task.sleep(for: .milliseconds(100)) }
            await model.fetchDarkLogosOnce()
        }
    }

    /// Plugs the two real implementations into the model's hooks. The model has no
    /// import of `UserNotifications` or `EventKit` and no way to construct these; it
    /// simply calls whatever it is given, and does nothing when given nothing.
    ///
    /// Done in `init`, synchronously, so the hooks are in place before `AppModel.load()`
    /// (a task the model's own `init` enqueues) runs at all: its closing
    /// `notifyServices()` is then the launch's reschedule and calendar pass, with or
    /// without a window.
    private static func installServices(model: AppModel) {
        let scheduler = NotificationScheduler()
        let calendar = CalendarSync(model: model)
        // Twice each, on purpose: the hooks are what the model calls after a mutation,
        // the concrete properties are what the Data and Reminders panes need for the
        // things a one-method protocol has no business carrying.
        model.notificationScheduler = scheduler
        model.scheduler = scheduler
        model.calendarSync = calendar
        model.calendarService = calendar
    }

    // No forced appearance at the scene level. The main window and Settings each set
    // the dark colour scheme on their own content.

    var body: some Scene {
        Window("Obolo", id: OboloWindow.main) {
            // A fixed 640 × 640 window: `MainWindow` sizes itself, and the window takes
            // its size from the content.
            MainWindow(model: model)
                .background(MainWindowIdentityView())
                .modifier(AppWiring(model: model))
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["intent"])
        .commands { commands }

        Settings {
            // `model:` because the Categories & currencies and Data panes edit the
            // document rather than the settings.
            PreferencesView(settings: model.settings, model: model)
        }
        .windowStyle(.hiddenTitleBar)
        // The window's size *is* the pane's: 560 wide, and as tall as the pane on
        // screen measured itself to be, up to the ceiling in `PreferencesView` — past
        // which that pane's `Form` scrolls. Without this AppKit picks a size of its
        // own and the taller panes are cut off at the bottom with nothing to scroll.
        .windowResizability(.contentSize)

        // The menu bar item is `StatusItemController`: a left click opens the window,
        // a right click shows a menu, which SwiftUI's `MenuBarExtra` cannot do.
    }

    // MARK: - Commands

    @CommandsBuilder
    private var commands: some Commands {
        SearchCommands()

        CommandGroup(after: .help) {
            Button("Privacy Policy") {
                NSWorkspace.shared.open(URL(string: "https://github.com/anguria-studio/Obolo/blob/main/docs/privacy.md")!)
            }
        }

        #if OBOLO_DIRECT
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton()
        }
        #endif

        CommandGroup(replacing: .newItem) {
            Button("New Subscription") { model.presentAdd() }
                .keyboardShortcut("n")
                .disabled(model.isFormPresented)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo Delete") { model.undoDelete() }
                .keyboardShortcut("z")
                .disabled(!model.canUndoDelete || model.isFormPresented)
        }

        CommandGroup(replacing: .importExport) {
            Group {
                Button("Import CSV") { importCSV() }
                    .keyboardShortcut("i")
                Button("Export CSV") { exportCSV() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            .disabled(model.isFormPresented)
        }

        CommandMenu("Subscription") {
            Button("Edit") { model.presentEdit(model.selectedID) }
                .keyboardShortcut("e")
                .disabled(model.selectedID == nil || model.isFormPresented)

            Button("Duplicate") { model.presentDuplicate(model.selectedID) }
            .keyboardShortcut("d")
            .disabled(model.selectedID == nil || model.isFormPresented)

            Divider()

            Button(fetchLogosTitle) {
                Task { await model.fetchMissingLogos() }
            }
            // Off while one is running, and off when there is nothing to fetch: every
            // row either has a logo already or has no address to look one up with.
            .disabled(model.isFetchingLogos || model.missingLogoCount == 0 || model.isFormPresented)

            Divider()

            Button("Delete") { model.pendingDelete = model.selectedID }
                .keyboardShortcut(.delete)
                .disabled(model.selectedID == nil || model.isFormPresented)
        }

        CommandGroup(after: .toolbar) {
            Group {
                Button("Home") { model.section = .overview }
                    .keyboardShortcut("1")
                Button("Upcoming") { model.section = .upcoming }
                    .keyboardShortcut("2")
                Button("Calendar") { model.section = .calendar }
                    .keyboardShortcut("3")
                Button("All Subscriptions") { model.section = .all }
                    .keyboardShortcut("4")
                Button("Needs Attention") { model.section = .attention }
                    .keyboardShortcut("5")
            }
            .disabled(model.isFormPresented)
        }
    }

    /// "Fetch Missing Logos" — or the count while a pass is running, because this is
    /// the only place the menu can say that something is happening.
    private var fetchLogosTitle: String {
        guard let progress = model.logoFetchProgress else { return "Fetch Missing Logos" }
        return "Fetching Logos (\(progress.done) of \(progress.total))"
    }

    // MARK: - CSV panels
    //
    // `ImportCoordinator` owns the open panel, the drop-on-window case and the error
    // alert; ⌘I is one of its three doors. The window is opened first because the
    // preview it presents is a sheet, and a sheet needs something to be a sheet on.

    private func importCSV() {
        MainWindowPresenter.present {
            openWindow(id: OboloWindow.main)
        }
        ImportCoordinator.chooseAndPreview(model: model)
    }

    private func exportCSV() {
        CSVExportPanel.run(model: model)
    }
}

// MARK: - Wiring

/// What the main window does for the rest of the app: it answers the Shortcuts links
/// and the routes an App Intent, the status item or a clicked reminder asked for,
/// because opening a window takes `openWindow`, which only a scene has.
///
/// Launch work that a windowless login launch also needs (the services, the status
/// item) is done in `OboloApp.init` instead, which runs however the app was started.
private struct AppWiring: ViewModifier {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    /// `.onOpenURL` takes the `studio.anguria.obolo://intent` URLs the Shortcuts
    /// actions open the app with. `OboloIntentLink.window`, which
    /// `MainWindowPresenter.open` sends when no window is open, parses to nothing: by
    /// then its route is already queued, and the link was only there to build this
    /// window. It is a scene method, so it belongs on a window
    /// scene's root — the only place this modifier is applied; the menu bar item is an
    /// AppKit status item, not a scene.
    func body(content: Content) -> some View {
        wired(content)
            .onOpenURL { url in
                guard let link = OboloIntentLink(url: url) else { return }
                OboloIntentRouter.shared.request(link.route)
            }
    }

    private func wired(_ content: Content) -> some View {
        content
            .onAppear { openFromIntent() }
            // Fires once now and again when `load()` answers, whichever order those
            // happen in: a route that arrived before the document waits for it.
            .task(id: model.isLoaded) { openFromIntent() }
            .onReceive(NotificationCenter.default.publisher(for: .oboloOpenIntentRoute)) { _ in
                openFromIntent()
            }
            .onChange(of: model.storeRecovery) { _, _ in
                openFromIntent()
            }
            .onChange(of: model.activeSheet?.id) { _, _ in
                openFromIntent()
            }
    }

    /// Opens a route that an App Intent, the status item or a clicked reminder
    /// requested before or after this scene appeared.
    private func openFromIntent() {
        // Wait for the real document. This prevents a cold-launch add action from
        // using the initial EUR template before the app loads the saved base currency.
        guard model.isLoaded, model.storeRecovery == nil else { return }

        while let route = OboloIntentRouter.shared.takePendingRoute(activeSheet: model.activeSheet) {
            switch route {
            case .home:
                model.closeSubscriptionDetail()
                OpenMainWindow(model: model, openWindow: openWindow)(section: .overview)
            case .upcoming:
                OpenMainWindow(model: model, openWindow: openWindow)(section: .upcoming)
            case .addSubscription(let prefill):
                OpenMainWindow(model: model, openWindow: openWindow)()
                model.presentAdd(prefill: prefill)
            case .subscription(let id):
                // A reminder for a subscription deleted since opens the window on the
                // screen behind any open detail: another subscription's detail would
                // read as the answer to the click.
                if model.subscription(id) != nil {
                    OpenMainWindow(model: model, openWindow: openWindow)(selecting: id)
                } else {
                    model.closeSubscriptionDetail()
                    OpenMainWindow(model: model, openWindow: openWindow)()
                }
            }
        }
    }
}
