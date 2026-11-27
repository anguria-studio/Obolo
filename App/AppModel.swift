import AppKit
import Foundation
import Observation
import OboloCore

// MARK: - Service hooks

/// The two things that happen *outside* the app when the document changes, expressed
/// as protocols so `AppModel` can call them without knowing they exist.
///
/// `NotificationScheduler` and `CalendarSync` both need UNUserNotificationCenter /
/// EventKit, both are slow, both can be denied by the user, and neither is needed for
/// the app to run. Keeping them behind two one-method protocols means the model has
/// no import of either framework, previews and tests get a silent app for free, and
/// the agent that writes the real implementations plugs them in by assignment rather
/// than by editing this file.
///
/// Both are `Sendable` with `async` requirements, so an implementation may be an
/// actor, a `@MainActor` class, or neither.
protocol SchedulerHook: Sendable {
    /// Called after every mutation, and after the day rolls over. Implementations are
    /// expected to be idempotent: this reschedules *all* pending reminders.
    func reschedule(ledger: Ledger) async
}

protocol CalendarSyncHook: Sendable {
    /// Called after every mutation. Implementations reconcile the calendar against the
    /// document and must never touch events they did not create.
    func reconcile(document: StoreDocument) async
}

/// The one thing `AppModel` asks the network for on its own: today's reference rates.
///
/// A protocol for the same reason as the two above, plus one more — the queueing in
/// `refreshRates(force:)` is real behaviour with a real bug history, and the only way to
/// prove "a forced refresh is never swallowed by the one already in the air" is to count
/// the requests. A test cannot count requests it has to make to the ECB.
protocol RateFetching: Sendable {
    /// The published day and the rates to multiply by, for the codes that came back.
    func fetch(base: String, symbols: [String]) async throws -> (asOf: Date, ratesToBase: [String: Decimal])
}

extension RateService: RateFetching {}

// MARK: - App model

/// The UI's source of truth.
///
/// Owns the portable `document`, the local `deviceState`, and the derived `ledger`.
/// Everything the UI reads about money, dates, totals and attention comes
/// from the ledger. The app rebuilds it when the document changes and when the day
/// changes.
@MainActor
@Observable
final class AppModel {

    // MARK: Document

    /// The store, as loaded. Mutated only through the methods below so that saving,
    /// recomputation and the service hooks cannot be forgotten at a call site.
    private(set) var document: StoreDocument {
        // Every window follows the Appearance setting, whichever way it changed: an
        // edit in Settings, a load or a restore.
        didSet {
            if document.settings.appearance != oldValue.settings.appearance {
                Self.apply(document.settings.appearance)
            }
        }
    }

    /// Sets the app's appearance, which every window, popover and sheet inherits: `nil`
    /// follows macOS.
    static func apply(_ appearance: AppearanceSetting) {
        NSApplication.shared.appearance = appearance.nsAppearanceName.flatMap(NSAppearance.init(named:))
    }

    /// References to system objects that exist only on this Mac.
    private(set) var deviceState: DeviceState

    /// Every derived figure in the app. Recomputed, never patched.
    private(set) var ledger: Ledger {
        didSet { sortedAllRowsCache = nil }
    }

    @ObservationIgnored private var sortedAllRowsCache: (
        order: OboloCore.SortOrder, ascending: Bool, locale: Locale, rows: [SubscriptionSummary]
    )?

    /// True until `load()` has answered. The window shows its empty state rather than
    /// a momentarily-correct-looking zero.
    private(set) var isLoaded = false

    /// Whether this model reads its document from disk (`autoload`), rather than being
    /// handed one by a preview or a test.
    @ObservationIgnored private var readsFromDisk = true

    /// Nothing in the list, for certain: the document has been read (or was handed in)
    /// and is not a corrupt file waiting on the recovery banner. Home, All and the status
    /// line show their empty states on this, never on the moment before the load.
    var hasNoSubscriptions: Bool {
        document.subscriptions.isEmpty && (isLoaded || !readsFromDisk) && storeRecovery == nil
    }

    /// The last save error, if the disk refused. Surfaced by the Data pane; the app
    /// keeps running on the in-memory document either way.
    private(set) var saveError: String?

    /// The last error from the device-local store. Portable data can still save.
    private(set) var deviceStateError: String?

    /// The last error from the sync boundary. Local work remains available.
    ///
    /// This follows the service: a failed status sets it to that status's message and
    /// any other status clears it. So it never says more than `cloudSyncStatus.message`.
    private(set) var cloudSyncError: String?

    /// The last remote batch that Obolo could not merge or save.
    ///
    /// Kept apart from `cloudSyncError` because the service does not report a failed
    /// status after such a batch (it fetched and sent without error), and its status
    /// must not hide the batch it could not apply. The service keeps the batch, retries
    /// it, and does not record a successful sync until it applies. Only a batch that
    /// applies, or turning sync off, clears this.
    private(set) var cloudSyncRemoteChangesError: String?

    /// The state reported by the CloudKit boundary. The Data pane presents this value
    /// without importing CloudKit or reading its private state file.
    private(set) var cloudSyncStatus: CloudSyncSnapshot = .disabled

    /// The automatic backup from the most recent enable action in this process.
    private(set) var cloudSyncBackupURL: URL?

    // MARK: Corrupt store

    /// What the app knows after a store file it could not read.
    ///
    /// The file is never deleted, and this carries where it is so the banner and the Data
    /// pane can point at it. A `StoreRecovery` in hand also *blocks every save*: the app
    /// is running on an empty document it invented, and writing that over a file the user
    /// may still be able to salvage would finish the job the corruption started.
    struct StoreRecovery: Equatable {

        /// Where the unreadable file ended up.
        enum FileState: Equatable {
            /// Moved to a `.corrupt-` name of its own, with a note beside the store
            /// saying so. The store's own path is free, and Continue may write there.
            case movedAside
            /// Still at the store's own path, because moving it was not possible. There
            /// is no note on disk and none is needed: the next launch fails to read the
            /// same file and arrives back here.
            case leftInPlace
            /// The file belongs to a newer app. Only an update can open it.
            case newerVersion(StoreDocument.NewerVersion)
        }

        /// The unreadable file, wherever it is now.
        let path: URL
        let fileState: FileState
        /// Why it could not be read, for the Data pane's line.
        let error: String

        var newerVersion: StoreDocument.NewerVersion? {
            if case .newerVersion(let version) = fileState { return version }
            return nil
        }
    }

    private(set) var storeRecovery: StoreRecovery?

    /// The two things Obolo refuses to do while a corrupt store is waiting for an
    /// answer, both of them refusals in the user's favour.
    ///
    /// A backup reads the file on disk, and the file on disk is the empty one this app
    /// would write next. Handing the user a backup of nothing, under a name that says
    /// "Obolo 2026-08-24", is worse than refusing: they would keep it and throw the
    /// real file away. And Continue and Restore both write to the store's own path, so
    /// neither may go ahead while the unreadable file is still sitting at it.
    enum RecoveryError: LocalizedError, Equatable {
        case backupUnavailable(path: URL)
        /// Continue was pressed while the unreadable file was still at the store's own
        /// path, and it still cannot be moved out of the way.
        case fileNotMoved(reason: String)

        var errorDescription: String? {
            switch self {
            case .backupUnavailable(let path):
                "Back up is not available while recovery is pending. Restore first, or keep the file at \(path.path(percentEncoded: false))."
            case .fileNotMoved(let reason):
                "Obolo cannot move the unreadable file out of the way, so it is not writing anything over it. \(reason)"
            }
        }
    }

    enum CloudSyncControlError: LocalizedError, Equatable {
        case localSettingsUnavailable

        var errorDescription: String? {
            switch self {
            case .localSettingsUnavailable:
                "Obolo cannot turn on iCloud sync because it cannot read the settings for this Mac."
            }
        }
    }

    /// The "Continue" button on the banner: the user has seen where the old file is and
    /// accepts starting from an empty list. Saving is allowed again from here, and the
    /// note beside the store goes, so the next launch is an ordinary one.
    ///
    /// One thing has to be true first. Saving again means writing the empty document to
    /// the store's own path, so the unreadable file must not be sitting there: on the
    /// in-place path the move that failed at launch is tried once more here. If it fails
    /// again this throws and the banner stays, which is the only defensible answer —
    /// "continue with an empty list" must never mean "write the empty list over the one
    /// copy of your data".
    func continueAfterRecovery() throws {
        guard storeRecovery != nil else { return }
        try makeStorePathWritable()
        storeRecovery = nil
        RecoverySidecar.delete(besideStoreAt: store.url)
        scheduleSave()
    }

    // MARK: Navigation and selection

    var section: Section = .overview {
        didSet {
            guard section != oldValue else { return }
            // Navigation is not a request to open anything. Drop both kinds of subject so
            // a remembered selection cannot open a subscription's detail merely because
            // its view came back on screen. A click-through that means to open something
            // changes the section first, then makes its explicit selection.
            selectedID = nil
            selectedCalendarDay = nil
        }
    }

    /// The subscription the window is about. Selection never writes the document.
    var selectedID: Subscription.ID? {
        didSet { showsHomeSubscriptionDetail = false }
    }

    /// Home opens details from its legend. Selecting a subscription while adding or
    /// undoing a delete on Home still leaves the chart on screen.
    private var showsHomeSubscriptionDetail = false

    var isShowingSubscriptionDetail: Bool {
        guard section != .overview || showsHomeSubscriptionDetail, let selectedID else { return false }
        return subscription(selectedID) != nil
    }

    /// Applies a selection that came from a subscription list.
    ///
    /// A row and its detail are one interaction: selecting a row opens its detail on
    /// the first click, and clearing the selection closes it.
    func selectSubscriptionRow(_ id: Subscription.ID?) {
        selectedID = id
    }

    func openHomeSubscriptionDetail(_ id: Subscription.ID) {
        guard section == .overview, subscription(id) != nil else { return }
        selectSubscriptionRow(id)
        showsHomeSubscriptionDetail = true
    }

    /// Return to the section the detail opened from.
    func closeSubscriptionDetail() {
        selectSubscriptionRow(nil)
    }

    // MARK: Calendar
    //
    // The view state that belongs to the Calendar section and to nothing else: which
    // month is on screen and which day the status line describes. Neither is persisted:
    // the month a person was looking at last Tuesday is not a preference, and a store
    // that carried it would open on a stale month.

    /// The date the month on screen is read from. Set through the methods below rather
    /// than assigned, so the day selection cannot survive a month it does not belong to.
    ///
    /// It is also the window's one month: Home and Calendar both
    /// read it, so picking March on Home opens Calendar on March and the other way
    /// round. All has no month and leaves it alone. It goes back to the current month
    /// when the window reopens (`showCurrentMonth()`) and when the day changes.
    private(set) var calendarMonth: Date

    /// The first day of the shared month (see `calendarMonth`).
    var shownMonth: Date { MonthRange.start(of: calendarMonth, calendar: calendar) }

    /// Whether the shared month is the current one; also the Calendar's Today button's
    /// disabled state.
    var isShowingCurrentMonth: Bool { shownMonth == MonthRange.start(of: today, calendar: calendar) }

    /// Back to the current month: a reopened window, a new day and the Calendar's Today
    /// button start there.
    func showCurrentMonth() { setCalendarAnchor(today) }

    /// The day whose charges the status line lists, or `nil` for no selection. Start of
    /// day, in the model's calendar.
    var selectedCalendarDay: Date?

    func showPrevious() { shiftMonth(by: -1) }

    func showNext() { shiftMonth(by: 1) }

    /// Shows the month `date` falls in: Home's month bars and month picker, where the
    /// thing the user hit names a month, and the calendar's pager when a swipe settles
    /// on a page.
    func showMonth(containing date: Date) { setCalendarAnchor(date) }

    /// Picks a day, or clears the selection when the same day is clicked again.
    func selectCalendarDay(_ date: Date?) {
        guard let date else {
            selectedCalendarDay = nil
            return
        }
        let day = calendar.startOfDay(for: date)
        selectedCalendarDay = selectedCalendarDay == day ? nil : day
    }

    private func shiftMonth(by steps: Int) {
        // Stepping from the month's first day rather than from the anchor: adding a
        // month to the 31st clamps to the 28th and never comes back.
        setCalendarAnchor(MonthRange.start(of: calendarMonth, offsetByMonths: steps, calendar: calendar))
    }

    /// Moving clears the day. Carrying "the 14th" across to the next month would be the
    /// app choosing a date the user never clicked, and on a 31st it would have to invent
    /// one — so the selection empties and waits to be told again.
    private func setCalendarAnchor(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        guard MonthRange.start(of: day, calendar: calendar) != shownMonth else { return }
        calendarMonth = day
        selectedCalendarDay = nil
    }

    /// The shared month's count and total: the figure the Calendar's key prints under
    /// the grid.
    var calendarMonthTotal: (charged: Decimal, count: Int, excludedCount: Int) {
        ledger.monthTotal(containing: calendarMonth)
    }

    /// The charges on one day, in the same order the grid stacks their logos.
    func calendarOccurrences(on day: Date) -> [RenewalOccurrence] {
        let start = calendar.startOfDay(for: day)
        return ledger.occurrences(
            from: start,
            to: calendar.date(byAdding: .day, value: 1, to: start) ?? start
        )
    }

    // MARK: Presentation

    private(set) var activeSheet: WindowSheet?

    var isFormPresented: Bool { activeSheet != nil && storeRecovery?.newerVersion == nil }

    /// The subscription awaiting delete confirmation.
    var pendingDelete: Subscription.ID?

    func presentAdd(prefill: SubscriptionFormPrefill = .init()) {
        presentSheet(.add(prefill))
    }

    func presentEdit(_ id: Subscription.ID?, focus: SubscriptionEditorFocus = .name) {
        guard let id, subscription(id) != nil else { return }
        presentSheet(.edit(id, focus: focus))
    }

    /// The add form, pre-filled from the row `id`: the detail's ⋮, a row's menu and ⌘D.
    /// The copy is named "<name> copy" and keeps the original's logo for display. It has
    /// a new id, so it never claims the original's calendar event, which `DeviceState`
    /// keys by id. Nothing is written until Add; `add` gives the copy its own logo file
    /// then. No row, or a row that is not in the list, opens nothing.
    func presentDuplicate(_ id: Subscription.ID?) {
        guard let id, let original = subscription(id) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) copy"
        copy.createdAt = today
        presentSheet(.duplicate(copy))
    }

    func presentImportPreview(_ preview: ImportPreview) {
        presentSheet(.importPreview(preview))
    }

    func dismissSheet(_ id: WindowSheet.ID) {
        guard activeSheet?.id == id else { return }
        activeSheet = nil
    }

    private func presentSheet(_ content: WindowSheet.Content) {
        // Repeating the same request keeps the draft already being edited.
        guard activeSheet?.content != content else { return }
        activeSheet = WindowSheet(content: content)
    }

    /// Closes what is open on a row that has left the document: the edit form, the
    /// subscription detail, the delete alert, and a cancel prompt still waiting for the
    /// detail to open.
    ///
    /// A row can go while any of them is open: a delete from the menu bar, or an iCloud
    /// merge of a delete on another Mac. The form overlay would stay up with nothing on
    /// it and no close control, and the detail would show an empty panel. The delete
    /// alert would ask about a row it cannot name, and its Delete would do nothing. A
    /// waiting cancel prompt has no detail to open in, so it would wait until the row
    /// came back (Undo, a restore), then open on a question nobody asked. Reactivate
    /// edits a prepared copy, but still depends on the stored row. Undo after a delete
    /// puts the row back and selects it, with the form closed.
    ///
    /// The reverse case is the Undo offer: it holds a row that has left the document. If
    /// that row comes back another way (a restored backup), Undo would add it a second
    /// time, and the end of the window would remove the logo and calendar event of a row
    /// that is in the list. The offer goes, and the delete is not finalised.
    private func closeWhatShowsMissingRows() {
        if let id = activeSheet?.editedSubscriptionID, subscription(id) == nil {
            activeSheet = nil
        }
        if let selectedID, subscription(selectedID) == nil {
            self.selectedID = nil
        }
        if let pendingDelete, subscription(pendingDelete) == nil {
            self.pendingDelete = nil
        }
        if let cancelPromptID, subscription(cancelPromptID) == nil {
            self.cancelPromptID = nil
        }
        if let deleted = undoSnapshot?.subscription.id, subscription(deleted) != nil {
            expireUndo()
        }
    }

    // MARK: Persisted view state
    //
    // Store the sort order in the document so it travels with the library.

    var sortOrder: OboloCore.SortOrder {
        get { document.settings.sortOrder }
        set { document.settings.sortOrder = newValue; documentDidChange(recomputeLedger: false, notifyServices: false) }
    }

    /// Which way the sort order runs, or `nil` for its own natural direction. Persisted
    /// beside `sortOrder`, because a user who reversed a column meant it: the second
    /// click on a header is as much a choice as the first.
    var sortAscending: Bool? {
        get { document.settings.sortAscending }
        set { document.settings.sortAscending = newValue; documentDidChange(recomputeLedger: false, notifyServices: false) }
    }

    /// The direction the rows are actually in: the user's choice, or the order's natural
    /// one where there is none. The All list's ↑/↓ reads this.
    var isSortAscending: Bool { sortAscending ?? sortOrder.naturalAscending }

    /// Adopt a header click: the order it names, and the direction it asks for.
    ///
    /// One write rather than two, so the list re-sorts and the document is saved once
    /// for a click that changes both.
    func applySort(_ order: OboloCore.SortOrder, ascending: Bool) {
        guard order != sortOrder || ascending != (sortAscending ?? sortOrder.naturalAscending) else { return }
        document.settings.sortOrder = order
        document.settings.sortAscending = ascending
        documentDidChange(recomputeLedger: false, notifyServices: false)
    }

    // MARK: Settings

    /// The settings wrapper the preference panes bind to. It holds no values of its
    /// own — it reads and writes `document.settings` through the callback wired below.
    let settings: SettingsStore

    // MARK: Services

    /// Assigned at launch by whoever owns the real implementations. `nil` means the
    /// app simply does not schedule anything, which is the correct behaviour in a
    /// preview and an acceptable one when the user has denied permission.
    var notificationScheduler: (any SchedulerHook)?
    var calendarSync: (any CalendarSyncHook)?

    // MARK: Logos

    /// The folder of logo files. Shared with `IconInitial`, which draws them. A test
    /// gives its model a folder of its own.
    @ObservationIgnored var logos = LogoStore.shared {
        didSet { listenForArrivedLogos() }
    }

    /// A new logo that arrives through iCloud comes to `logoDidArrive`.
    private func listenForArrivedLogos() {
        logos.logoDidArrive = { [weak self] id in self?.logoDidArrive(for: id) }
    }

    /// The one thing in this app that opens a network connection, and only when one of
    /// the explicit actions below calls it. A test gives its model one that answers
    /// without a network.
    @ObservationIgnored var logoFetcher: any LogoFetching = LogoFetcher()

    /// `(done, total)` while a "fetch the missing ones" pass is running, `nil` otherwise
    /// — the Data pane's button and the menu item both read it.
    private(set) var logoFetchProgress: (done: Int, total: Int)?

    var isFetchingLogos: Bool { logoFetchProgress != nil }

    /// How many rows a fetch would even try: something to fetch *for* (a website, or a
    /// manage link to take one from) and no usable logo file yet.
    ///
    /// A backup stores an `.image` filename but not the file's bytes. On a different Mac
    /// that reference draws the initial and belongs in this count just as much as an
    /// explicit `.initial` does. Emoji and SF Symbols remain intentional manual icons.
    var missingLogoCount: Int {
        document.subscriptions.count { logoFetchDomain(for: $0) != nil }
    }

    /// The domain to fetch a logo from when `subscription` has a domain and no usable
    /// logo: in logo mode with no file, or a file that has gone missing. `nil` for a
    /// letter, an emoji or a symbol the person chose. Fetch Missing Logos and the form's
    /// Save both go by this.
    func logoFetchDomain(for subscription: Subscription) -> String? {
        guard let domain = subscription.effectiveDomain else { return nil }
        switch subscription.icon {
        case .initial:
            return domain
        case .image(let filename):
            return logos.image(named: filename) == nil ? domain : nil
        case .emoji, .symbol, .letter:
            // Chosen by the person: never replaced by a fetched logo.
            return nil
        }
    }

    // MARK: Exchange rates

    /// What the Settings status line says about the last refresh.
    enum RateRefreshState: Equatable {
        case idle
        case refreshing
        /// Carries the reason, for the tooltip; the line itself stays short.
        case failed(String)
        case updated(Date)
    }

    private(set) var rateRefreshState: RateRefreshState = .idle

    var isRefreshingRates: Bool { rateRefreshState == .refreshing }

    /// The ECB day the automatic rates were published on, `nil` until one has landed.
    var ratesAsOf: Date? { document.rates.automaticAsOf }

    /// When the app last got an answer, whatever that answer said. Over a weekend this
    /// is today while `ratesAsOf` is still Friday, which is the whole point of keeping
    /// the two apart.
    var ratesLastCheckedAt: Date? { document.rates.lastCheckedAt }

    /// Where the rates come from. Injected so a test can count requests, and so a
    /// preview can be handed something that never opens a connection.
    @ObservationIgnored private let rateService: any RateFetching

    /// What one refresh asks for. Two calls that would send the same request have
    /// nothing to gain from being made twice; two that would not are two questions.
    private struct RateRequest: Equatable {
        let base: String
        let symbols: [String]
    }

    /// The run in progress — one at a time, always — and what it is asking for.
    @ObservationIgnored private var rateRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightRateRequest: RateRequest?

    /// The single queued follow-up, and whether it is forced. `nil` is "nothing queued".
    /// One is enough: the follow-up reads the document when it runs, so a second caller
    /// asking for the same thing folds into it rather than adding a request of its own.
    @ObservationIgnored private var queuedRateRefresh: Bool?

    /// The same two objects, concretely typed.
    ///
    /// The model uses the hooks above. The Reminders pane uses these instances to
    /// list pending notifications and sync calendar events on demand.
    var scheduler: NotificationScheduler?
    var calendarService: CalendarSync?

    // MARK: Time

    /// Tests and previews inject a clock to reproduce the sample billing dates.
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private(set) var calendar: Calendar

    var today: Date { clock() }

    // MARK: Storage

    @ObservationIgnored private let store: DocumentStore
    @ObservationIgnored private let deviceStateStore: DeviceStateStore
    @ObservationIgnored private let cloudSyncService: any CloudSyncService
    @ObservationIgnored private let cloudSyncRemoteQueue = CloudSyncRemoteQueue()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// True from `scheduleSave` until its task starts to write, or until something else
    /// writes `document` instead. `applyRemoteChanges` reads it to know whether the save
    /// it cancels still had a local edit to write.
    @ObservationIgnored private var saveIsPending = false
    @ObservationIgnored private var deviceStateSaveTask: Task<Void, Never>?
    @ObservationIgnored private var cloudSyncTask: Task<Void, Never>?
    @ObservationIgnored private var hasStartedCloudSync = false
    @ObservationIgnored private var cloudSyncRemoteRevision = 0
    /// Set when the last remote batch did not apply because the store could not save
    /// it. The next local save that succeeds shows that the store writes again, and asks
    /// the service for one replay (`replayRemoteChangesAfterSave`). A batch that cannot
    /// merge (a newer schema) does not set it: only an update of Obolo can help, and the
    /// next start tries that batch again anyway.
    @ObservationIgnored private var cloudSyncReplaysAfterNextSave = false
    @ObservationIgnored private var deviceStateNeedsSave = false
    @ObservationIgnored private var deviceStateWritesBlocked = false
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var calendarTask: Task<Void, Never>?
    @ObservationIgnored private var midnightTask: Task<Void, Never>?
    /// `nonisolated(unsafe)` because `deinit` is not isolated and the token type is
    /// not `Sendable`. It is written once, on the main actor, and read once, in
    /// `deinit`, which by definition cannot race with anything.
    @ObservationIgnored private nonisolated(unsafe) var dayChangeObservers: [any NSObjectProtocol] = []

    var storeURL: URL { store.url }

    // MARK: Lifecycle

    init(
        store: DocumentStore,
        deviceStateStore: DeviceStateStore? = nil,
        document: StoreDocument = .initial(),
        calendar: Calendar = .autoupdatingCurrent,
        clock: @escaping @Sendable () -> Date = { Date() },
        rateService: any RateFetching = RateService(),
        cloudSyncService: any CloudSyncService = DisabledCloudSyncService(),
        autoload: Bool = true
    ) {
        self.store = store
        self.deviceStateStore = deviceStateStore ?? DeviceStateStore(
            url: store.url.deletingLastPathComponent().appending(path: DeviceStateStore.fileName)
        )
        self.document = document
        self.deviceState = .initial()
        self.calendar = calendar
        self.clock = clock
        self.rateService = rateService
        self.cloudSyncService = cloudSyncService
        self.ledger = Ledger(document: document, today: clock(), calendar: calendar)
        self.settings = SettingsStore(document.settings)
        // Use the injected clock so previews and the live app both open on their current month.
        self.calendarMonth = MonthRange.start(of: clock(), calendar: calendar)
        // The store writes back through this rather than owning a copy: one document,
        // one writer. Weak, because the store is a stored property of this object.
        settings.onChange = { [weak self] updated in
            self?.updateSettings(updated)
        }

        observeDayChanges()
        scheduleMidnightRecompute()
        listenForArrivedLogos()
        // The document's own Appearance; a load that brings another one applies it then.
        Self.apply(document.settings.appearance)

        // Loading here rather than from a scene's `.task`: a login launch may present
        // no window at all, and the menu bar item still has to know what it owes.
        // Previews and tests pass `autoload: false` and supply their own document.
        readsFromDisk = autoload
        if autoload {
            Task { await self.load() }
        }
    }

    deinit {
        saveTask?.cancel()
        deviceStateSaveTask?.cancel()
        cloudSyncTask?.cancel()
        scheduleTask?.cancel()
        calendarTask?.cancel()
        midnightTask?.cancel()
        rateRefreshTask?.cancel()
        for observer in dayChangeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Reads the store. A missing file is not an error — it is a first launch, and
    /// `DocumentStore` answers with the seeded document.
    func load() async {
        var normalizedOnLoad = false
        await loadDeviceState()
        do {
            let loaded = try await store.load()
            // A missing canonical file with a note beside it is not a new install: it is
            // last launch's corrupt file, moved aside, with nobody having answered the
            // banner yet. `DocumentStore` cannot tell the two apart — both are "no file"
            // — so the note is what tells them apart, and the banner comes back with the
            // saves still blocked.
            if let pending = pendingRecovery() {
                _ = apply(.initial())
                storeRecovery = pending
            } else {
                // The file reads. Anything left over from an older recovery describes a
                // state that is finished with, so it goes quietly.
                RecoverySidecar.delete(besideStoreAt: store.url)
                normalizedOnLoad = apply(loaded)
            }
        } catch let error as StoreDocument.NewerVersion {
            storeRecovery = StoreRecovery(path: store.url, fileState: .newerVersion(error), error: error.localizedDescription)
            isLoaded = true
            return
        } catch {
            // A corrupt file is the one case worth interrupting for. The file is moved
            // out of the way under a name that says what it is — never deleted — the app
            // starts from an empty document, and every save is blocked until the user
            // answers the banner. Restoring a backup is the way out; carrying on with an
            // empty list is the other.
            let description = error.localizedDescription
            let recovery: StoreRecovery = switch quarantineStoreFile(reason: description) {
            case .moved(let destination):
                StoreRecovery(path: destination, fileState: .movedAside, error: description)
            case .nothingToMove, .failed:
                // The file stays where it is, and so does the banner's promise about it.
                StoreRecovery(path: store.url, fileState: .leftInPlace, error: description)
            }
            _ = apply(.initial())
            storeRecovery = recovery
        }

        isLoaded = true
        // Only when `apply` actually rewrote something. A launch that read a document it
        // agreed with writes nothing.
        if normalizedOnLoad { scheduleSave() }
        if !normalizedOnLoad { await startCloudSyncIfSafe(with: document) }
        notifyServices()
        // After the first ledger, never before it: the window shows the totals it has
        // and improves them a moment later, rather than waiting on a network round trip
        // to show anything at all.
        Task { await refreshRates() }
    }

    private func loadDeviceState() async {
        do {
            deviceState = try await deviceStateStore.load()
            deviceStateError = nil
            deviceStateWritesBlocked = false
        } catch {
            // This file contains only local system references. Keep the portable
            // document available, but do not replace an unreadable local file.
            deviceState = .initial()
            deviceStateError = "Obolo cannot read the settings for this Mac. \(error.localizedDescription)"
            deviceStateWritesBlocked = true
        }
    }

    /// Replaces the whole document — used by `load()`, by Restore, and by an import
    /// that rewrote everything.
    ///
    /// Three corrections happen on the way in, and none of them invents a number. A
    /// value this build cannot work out stays unknown, and the app says `—` rather than
    /// printing a figure it made up.
    ///
    /// Returns whether anything was rewritten, so the caller can save the corrected
    /// document once instead of correcting it again on every launch.
    @discardableResult
    private func apply(_ newDocument: StoreDocument) -> Bool {
        var normalized = newDocument
        var changed = false
        let now = self.today
        let today = calendar.startOfDay(for: now)
        let latestHistoryDay = BillingDay.latestWorldwide(at: now)

        for index in normalized.subscriptions.indices {
            let stored = normalized.subscriptions[index]

            // Pause is gone: a paused row from an older file or backup becomes cancelled.
            // A row written before `billingStoppedOn` existed takes its stop date from an
            // end date that has passed, and from nothing else.
            // A backup or synced record can already contain today's history from UTC+14.
            let subscription = stored
                .resolvingLegacyPause(today: today, calendar: calendar)
                .inferringBillingStop(today: today, calendar: calendar)
                .droppingFutureHistory(after: latestHistoryDay)
                .subscription

            guard subscription != stored else { continue }
            normalized.subscriptions[index] = subscription
            changed = true
        }

        document = normalized
        settings.apply(normalized.settings)
        recomputeLedger()
        closeWhatShowsMissingRows()
        return changed
    }

    // MARK: - Mutations
    //
    // Every one of these ends in `documentDidChange()`: recompute the ledger, debounce
    // a save, then let the notification scheduler and the calendar catch up.

    /// Adds the row and selects it. Returns the row as stored.
    @discardableResult
    func add(_ subscription: Subscription, copyingHistoryFrom copy: Subscription? = nil) -> Subscription {
        var normalized = normalizedForWrite(subscription, recordedHistory: copy?.priceChanges ?? [])
        // A logo file is named after the row that owns it. A new row that shows another
        // row's logo (a duplicate) gets its own copy of the file, written only now, on
        // Add. Without a file to copy it shows the initial.
        if let filename = normalized.icon.imageFilename,
           filename != LogoStore.filename(for: normalized.id) {
            normalized.icon = logos.copy(filename, to: normalized.id).map { Icon.image($0) } ?? .initial
        }
        document.subscriptions.append(normalized)
        markFirstRunComplete()
        selectedID = normalized.id
        documentDidChange()
        refreshRatesForNewCurrencies()
        return normalized
    }

    /// Replaces the stored row with the same id. A row that is not in the list is not
    /// added back: an edit that outlived its row (a delete elsewhere, an iCloud merge)
    /// writes nothing.
    func update(_ subscription: Subscription) {
        guard let index = document.subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        let stored = document.subscriptions[index]
        let subscription = normalizedForWrite(
            subscription, recordedHistory: stored.priceChanges, wasBilling: stored.status.isBilling
        )
        // An edit that dropped the logo — "Use initial" in the form — leaves a file
        // nothing references. A re-fetch does not: the file is named after the
        // subscription, so the new one has already replaced the old one in place.
        if let previous = stored.icon.imageFilename,
           previous != subscription.icon.imageFilename {
            logos.delete(filename: previous)
        }
        document.subscriptions[index] = subscription
        documentDidChange()
        refreshRatesForNewCurrencies()
    }

    /// Marks a subscription cancelled, optionally recording the day access actually
    /// ends — which is usually *after* the cancellation, and is what the list shows.
    func cancel(_ id: Subscription.ID, endsOn: BillingDay? = nil) {
        mutate(id) { subscription in
            subscription.status = .cancelled
            subscription.billingStoppedOn = BillingDay(today, calendar: calendar)
            subscription.endsOn = endsOn
        }
    }

    /// Every status change, in one place: what changing the status *means*
    /// depends on which way it moves.
    ///
    /// Two of the moves have to ask a question before they can be carried out.
    /// Cancelling has to know when access actually ends, so it opens the cancel prompt;
    /// bringing a stopped subscription back has to know the next renewal date, because
    /// the old anchor has almost always drifted into the past. Neither writes anything
    /// until the user answers — which is why the stored status stands
    /// if they close the prompt or the form instead.
    func setStatus(_ status: Status, for id: Subscription.ID) {
        // Pause is gone. A request for it writes nothing.
        guard status != .paused,
              var subscription = subscription(id),
              subscription.status != status else { return }

        switch (subscription.status, status) {
        case (_, .cancelled):
            requestCancel(id)

        case (let current, .active) where !current.isBilling:
            // Bringing a stopped subscription back asks for the next renewal date,
            // because the old anchor has almost always drifted into the past. The end
            // date goes too: a subscription that is charging again does not stop on a
            // day in the past.
            subscription.status = .active
            subscription.billingStoppedOn = nil
            subscription.endsOn = nil
            if subscription.anchorDate == nil { subscription.anchorDate = BillingDay(today, calendar: calendar) }
            presentSheet(.reactivate(subscription))

        default:
            // Trial to active, and active back to trial: the same row on the same
            // schedule, so there is nothing to ask.
            subscription.status = status
            subscription.billingStoppedOn = status.isBilling
                ? nil
                : BillingDay(today, calendar: calendar)
            subscription.endsOn = nil
            update(subscription)
        }
    }

    /// Newly entered history uses the local day. An edit or duplicate can carry forward
    /// a date already recorded in a time zone ahead of this device.
    ///
    /// On an update, `wasBilling` records whether this is a transition from billing to
    /// cancelled. If that transition has no stop date, it gets today's date. Other
    /// cancelled rows keep their stop date, even when it is unknown. Billing rows have
    /// no stop date.
    private func normalizedForWrite(
        _ subscription: Subscription,
        recordedHistory: [PriceChange],
        wasBilling: Bool = false
    ) -> Subscription {
        let recordedDays = Set(recordedHistory.map(\.effectiveFrom))
        var result = subscription
            .droppingFutureHistory(after: BillingDay(today, calendar: calendar), keeping: recordedDays)
            .subscription
        if result.status.isBilling {
            result.billingStoppedOn = nil
        } else if result.billingStoppedOn == nil, wasBilling {
            result.billingStoppedOn = BillingDay(today, calendar: calendar)
        }
        return result
    }

    // MARK: Delete and undo

    /// What `undoDelete()` puts back: the row and where it sat.
    private struct DeletedRow {
        let subscription: Subscription
        let index: Int
    }

    @ObservationIgnored private var undoSnapshot: DeletedRow?
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?

    /// True while the undo window is open. Drives the ⌘Z menu item and the message.
    private(set) var canUndoDelete = false

    /// The name in the undo message: "Netflix deleted".
    private(set) var lastDeletedName: String?
    /// Changes with every delete, so a new message replaces the last one.
    private(set) var undoMessageID = UUID()

    /// Time allowed for Undo after a deletion. Hovering over the message pauses the timer.
    static let undoWindow: Duration = .seconds(6)
    @ObservationIgnored private var undoDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var undoHeldRemaining: Duration?

    /// The pointer is on the message: the clock stops until it leaves.
    func holdUndo(_ held: Bool) {
        guard canUndoDelete else { return }
        if held {
            guard let deadline = undoDeadline else { return }
            undoHeldRemaining = max(.zero, deadline - .now)
            undoExpiry?.cancel()
            undoExpiry = nil
        } else if let remaining = undoHeldRemaining {
            undoHeldRemaining = nil
            // A moment to move to Undo after leaving it, however little was left.
            scheduleUndoExpiry(after: max(remaining, .seconds(1.5)))
        }
    }

    private func scheduleUndoExpiry(after delay: Duration) {
        undoExpiry?.cancel()
        undoDeadline = .now + delay
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.finaliseDelete()
        }
    }

    /// "Mark as cancelled" asked from outside the detail (a row's right-click menu): the
    /// detail opens and its ⋮ menu opens on the question.
    var cancelPromptID: Subscription.ID?

    func requestCancel(_ id: Subscription.ID) {
        // A row that is gone has no detail to ask in. `closeWhatShowsMissingRows`
        // clears the question if the row goes after it was asked.
        guard subscription(id) != nil else { return }
        if section == .overview { section = .all }
        selectSubscriptionRow(id)
        cancelPromptID = id
    }

    func delete(_ id: Subscription.ID) {
        guard let index = document.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        // One undo at a time: a delete still waiting on its window becomes permanent now,
        // its logo and calendar event with it, before this one takes the message.
        if undoSnapshot != nil { finaliseDelete() }
        let removed = document.subscriptions.remove(at: index)

        undoSnapshot = DeletedRow(subscription: removed, index: index)
        canUndoDelete = true
        lastDeletedName = removed.name
        undoMessageID = UUID()
        if selectedID == id { selectedID = nil }
        if pendingDelete == id { pendingDelete = nil }

        // After the window the row is gone and the calendar event with it, so the offer
        // has to expire as well as the snapshot.
        undoHeldRemaining = nil
        scheduleUndoExpiry(after: Self.undoWindow)

        documentDidChange()
    }

    func undoDelete() {
        guard let snapshot = undoSnapshot else { return }
        let index = min(snapshot.index, document.subscriptions.count)
        document.subscriptions.insert(snapshot.subscription, at: index)
        selectedID = snapshot.subscription.id
        expireUndo()
        documentDidChange()
    }

    /// The delete becoming permanent: only now is the logo file removed, and only now is
    /// the calendar event. Removing either with the row would mean Undo brought the
    /// subscription back without its icon, or without the event the user still sees.
    private func finaliseDelete() {
        if let filename = undoSnapshot?.subscription.icon.imageFilename {
            logos.delete(filename: filename)
        }
        // Not gated on `calendarSyncEnabled`. A row that carries an event identifier has
        // an event out there whatever the switch says now, and the delete alert promises
        // that Obolo removes it. Best effort: with access revoked there is nothing
        // this can do, and nothing worth telling the user about a row they just deleted.
        if let subscriptionID = undoSnapshot?.subscription.id {
            let eventID = calendarEventIdentifier(for: subscriptionID)
            recordCalendarEventIdentifier(nil, for: subscriptionID)
            if let eventID, let calendarService {
                Task { await calendarService.removeManagedEvent(identifier: eventID) }
            }
        }
        expireUndo()
    }

    private func expireUndo() {
        undoExpiry?.cancel()
        undoExpiry = nil
        undoDeadline = nil
        undoHeldRemaining = nil
        undoSnapshot = nil
        canUndoDelete = false
        lastDeletedName = nil
    }

    // MARK: CSV

    /// Reads a file into a preview without touching the document. The sheet shows what
    /// would happen; nothing is applied until `importCSV(_:createMissingCategories:)`.
    ///
    /// Parsed against the *live* document, not a fresh one: category names in the file
    /// are matched against the categories the user actually has, so re-importing the
    /// same sheet twice does not offer to create "AI tools" a second time.
    func previewImport(data: Data) throws -> ImportPreview {
        try CSVImporter.preview(
            data: data,
            document: document,
            calendar: calendar,
            locale: .current,
            now: today
        )
    }

    func previewImport(url: URL) throws -> ImportPreview {
        var preview = try previewImport(data: try Data(contentsOf: url))
        preview.sourceName = url.lastPathComponent
        return preview
    }

    @discardableResult
    func importCSV(_ preview: ImportPreview, createMissingCategories: Bool) -> ImportResult {
        let result = CSVImporter.apply(
            preview, to: &document, createMissingCategories: createMissingCategories
        )
        if result.inserted > 0 { markFirstRunComplete() }
        documentDidChange()
        // A file is the fastest way to put a currency the app has never seen into the
        // list. Without this the imported rows sit outside every total, under a footnote,
        // until tomorrow's refresh.
        refreshRatesForNewCurrencies()
        return result
    }

    func exportCSV() -> Data {
        CSVExporter.export(document)
    }

    // MARK: Logos
    //
    // Three doors, all of them a deliberate act: the form's "Fetch logo", the menu's and
    // the Data pane's "Fetch Missing Logos", and the import sheet's toggle. Nothing here
    // runs on a timer or after an edit; the one launch-time pass is
    // `fetchDarkLogosOnce`, which runs a single time per Mac. A logo fetched on another
    // Mac arrives through iCloud without its dark version, which only the site has;
    // `logoDidArrive` asks the site for that one, and only for that one.

    /// Fetches and applies one subscription's logo. `false` means the domain had nothing
    /// usable, which is not an error worth alerting about.
    @discardableResult
    func fetchLogo(for id: Subscription.ID) async -> Bool {
        guard let domain = subscription(id)?.effectiveDomain else { return false }
        let found = await logoFetcher.fetchWithDarkVariant(
            domain: domain,
            allowGoogleFallback: document.settings.useGoogleFaviconFallback
        )
        guard let data = found.logo else { return false }
        return applyLogo(data, dark: found.dark, to: id)
    }

    /// A logo fetched but not stored: the form's "Fetch logo" holds one until Save, so
    /// Cancel leaves the stored subscription and the icon store as they were.
    struct FetchedLogo: Equatable {
        let logo: Data
        let dark: Data?
    }

    /// Fetches `domain`'s logo (and its dark version) without applying it. `nil` means
    /// the domain had nothing usable.
    func fetchLogoData(domain: String) async -> FetchedLogo? {
        let found = await logoFetcher.fetchWithDarkVariant(
            domain: domain,
            allowGoogleFallback: document.settings.useGoogleFaviconFallback
        )
        guard let logo = found.logo else { return nil }
        return FetchedLogo(logo: logo, dark: found.dark)
    }

    /// Every subscription that has a domain and no usable logo file, four at a time.
    ///
    /// Four because these are ten-odd requests to ten-odd different hosts, several of
    /// which will sit on the connection for the full eight seconds before refusing:
    /// serially that is a minute of waiting, and all at once it is a burst that looks
    /// like something it is not. Each result is written as it lands rather than at the
    /// end, so the All list fills in while the pass runs.
    @discardableResult
    func fetchMissingLogos() async -> (fetched: Int, failed: Int) {
        guard !isFetchingLogos else { return (0, 0) }

        let targets: [(id: Subscription.ID, domain: String)] = document.subscriptions.compactMap {
            guard let domain = logoFetchDomain(for: $0) else { return nil }
            return ($0.id, domain)
        }
        guard !targets.isEmpty else { return (0, 0) }

        let allowGoogleFallback = document.settings.useGoogleFaviconFallback
        let fetcher = logoFetcher
        var fetched = 0
        var failed = 0
        logoFetchProgress = (0, targets.count)

        await withTaskGroup(of: (Subscription.ID, Data?, Data?).self) { group in
            var pending = targets.makeIterator()
            func addNext() {
                guard let target = pending.next() else { return }
                group.addTask {
                    let found = await fetcher.fetchWithDarkVariant(domain: target.domain, allowGoogleFallback: allowGoogleFallback)
                    return (target.id, found.logo, found.dark)
                }
            }
            for _ in 0..<min(4, targets.count) { addNext() }

            for await (id, data, dark) in group {
                if let data, applyLogo(data, dark: dark, to: id) { fetched += 1 } else { failed += 1 }
                logoFetchProgress = (fetched + failed, targets.count)
                addNext()
            }
        }

        logoFetchProgress = nil
        return (fetched, failed)
    }

    /// Whether this Mac has had its one dark-logo catch-up.
    nonisolated static let darkLogoCatchUpKey = "didFetchDarkLogoVersions"

    /// Once per Mac: logos saved before dark versions were fetched
    /// get the site's own dark icon beside them, where the site has one. The logos
    /// themselves are left as they are, and a logo that already has a dark version is
    /// skipped. Every fetch from then on brings the dark version with it, so this never
    /// needs to run again; a pass cut short by quitting runs again next launch.
    func fetchDarkLogosOnce(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: Self.darkLogoCatchUpKey) else { return }
        let targets: [(filename: String, domain: String)] = document.subscriptions.compactMap {
            guard case .image(let filename) = $0.icon,
                  logos.image(named: filename) != nil,
                  logos.darkImage(for: filename) == nil,
                  let domain = $0.effectiveDomain
            else { return nil }
            return (filename, domain)
        }

        let fetcher = logoFetcher
        await withTaskGroup(of: (String, Data?).self) { group in
            var pending = targets.makeIterator()
            func addNext() {
                guard let target = pending.next() else { return }
                group.addTask { (target.filename, await fetcher.fetchDarkVersion(domain: target.domain)) }
            }
            // Four at a time, as `fetchMissingLogos` does and for the same reasons.
            for _ in 0..<min(4, targets.count) { addNext() }
            for await (filename, dark) in group {
                if let dark { try? logos.storeDark(imageData: dark, besideLogo: filename) }
                addNext()
            }
        }

        guard !Task.isCancelled else { return }
        defaults.set(true, forKey: Self.darkLogoCatchUpKey)
    }

    /// Logos that arrived through iCloud and still wait for their dark version, in the
    /// order they came.
    @ObservationIgnored private var arrivedLogos: [Subscription.ID] = []

    /// Works through `arrivedLogos`, one site at a time; `nil` when there is nothing
    /// to do. Tests wait on it.
    @ObservationIgnored private(set) var arrivedLogosTask: Task<Void, Never>?

    /// A new logo arrived through iCloud (`LogoStore.storeArrived`). iCloud does not
    /// carry the dark version, so it is fetched here, as the fetch on the other Mac
    /// would have: one home-page request, and that icon's file where the site declares
    /// one. One site at a time, so a first sync that brings every logo at once is not a
    /// burst.
    func logoDidArrive(for id: Subscription.ID) {
        guard !arrivedLogos.contains(id) else { return }
        arrivedLogos.append(id)
        guard arrivedLogosTask == nil else { return }
        arrivedLogosTask = Task { [weak self] in
            while let id = self?.nextArrivedLogo() {
                await self?.fetchDarkVersion(ofArrivedLogo: id)
            }
        }
    }

    private func nextArrivedLogo() -> Subscription.ID? {
        guard !arrivedLogos.isEmpty else {
            arrivedLogosTask = nil
            return nil
        }
        return arrivedLogos.removeFirst()
    }

    /// The dark version of the logo now on disk for `id`, when the site has one. A logo
    /// that already has one, or a row that is gone or shows no logo, asks for nothing.
    func fetchDarkVersion(ofArrivedLogo id: Subscription.ID) async {
        guard let subscription = subscription(id),
              case .image(let filename) = subscription.icon,
              logos.image(named: filename) != nil,
              logos.darkImage(for: filename) == nil,
              let domain = subscription.effectiveDomain
        else { return }
        guard let dark = await logoFetcher.fetchDarkVersion(domain: domain) else { return }
        // The row can change while the site answers. The dark version goes only beside
        // a logo of the same site, and never over one that arrived in the meantime.
        guard let current = self.subscription(id),
              current.icon == .image(filename),
              current.effectiveDomain == domain,
              logos.darkImage(for: filename) == nil
        else { return }
        try? logos.storeDark(imageData: dark, besideLogo: filename)
    }

    /// Writes the bytes to the icon store and points the subscription at the file; with
    /// `dark`, the site's own dark-mode version goes beside it.
    @discardableResult
    func applyLogo(_ data: Data, dark: Data? = nil, to id: Subscription.ID) -> Bool {
        guard let index = document.subscriptions.firstIndex(where: { $0.id == id }),
              let filename = try? logos.store(imageData: data, for: id)
        else { return false }
        if let dark { try? logos.storeDark(imageData: dark, besideLogo: filename) }
        document.subscriptions[index].icon = .image(filename)
        // Neither the notification nor the calendar cares what a row looks like.
        documentDidChange(recomputeLedger: true, notifyServices: false)
        return true
    }

    // MARK: iCloud sync and backup

    var isCloudSyncEnabled: Bool { deviceState.cloudSyncEnabled }

    /// Makes a recoverable local copy before this Mac contacts the private database.
    /// The opt-in flag is saved only after that copy succeeds.
    func enableCloudSync() async throws {
        guard !deviceState.cloudSyncEnabled else {
            guard !hasStartedCloudSync,
                  let localDocument = await writeDocumentForCloudSyncStart() else { return }
            await startCloudSyncIfSafe(with: localDocument)
            return
        }
        guard !deviceStateWritesBlocked else {
            throw CloudSyncControlError.localSettingsUnavailable
        }

        cloudSyncStatus = CloudSyncSnapshot(phase: .preparing)
        let backupURL = try makeCloudSyncBackupURL()
        do {
            try await backup(to: backupURL, notifyCloudSync: false)
            var updatedState = deviceState
            updatedState.cloudSyncEnabled = true
            try await deviceStateStore.save(updatedState)
            deviceState = updatedState
            deviceStateNeedsSave = false
            deviceStateError = nil
            cloudSyncBackupURL = backupURL
            await startCloudSyncIfSafe(with: document)
        } catch {
            cloudSyncStatus = CloudSyncSnapshot(
                phase: .failed,
                message: "Obolo did not turn on iCloud sync. \(error.localizedDescription)"
            )
            cloudSyncError = cloudSyncStatus.message
            throw error
        }
    }

    /// Stops CloudKit work. It keeps both the local document and the private iCloud
    /// records, so a later enable action can continue from the durable sync state.
    func disableCloudSync() async {
        cloudSyncTask?.cancel()
        cloudSyncTask = nil
        await cloudSyncService.stop()
        hasStartedCloudSync = false

        deviceState.cloudSyncEnabled = false
        do {
            try await deviceStateStore.save(deviceState)
            deviceStateNeedsSave = false
            deviceStateError = nil
        } catch {
            deviceStateError = "Obolo cannot save the settings for this Mac. \(error.localizedDescription)"
        }
        cloudSyncStatus = .disabled
        cloudSyncError = nil
        cloudSyncRemoteChangesError = nil
        cloudSyncReplaysAfterNextSave = false
    }

    /// One line under the iCloud section of the Data pane.
    struct CloudSyncNote: Equatable {
        let text: String
        let isError: Bool
    }

    /// The lines the Data pane shows about sync, from the service's status and from the
    /// errors this model recorded itself.
    var cloudSyncNotes: [CloudSyncNote] {
        Self.cloudSyncNotes(
            status: cloudSyncStatus,
            errors: [cloudSyncError, cloudSyncRemoteChangesError]
        )
    }

    /// Whether the Data pane's Status row says "Needs attention".
    var cloudSyncNeedsAttention: Bool {
        Self.cloudSyncNeedsAttention(
            status: cloudSyncStatus,
            remoteChangesError: cloudSyncRemoteChangesError
        )
    }

    /// The status message first, then each error that does not repeat a line already
    /// there. An error is never dropped because the status looks healthy, and a status
    /// message that is also an error shows once, as an error.
    static func cloudSyncNotes(
        status: CloudSyncSnapshot,
        errors: [String?]
    ) -> [CloudSyncNote] {
        let errors = errors.compactMap { $0 }
        var notes: [CloudSyncNote] = []
        if let message = status.message {
            notes.append(CloudSyncNote(
                text: message,
                isError: status.phase == .failed || errors.contains(message)
            ))
        }
        for error in errors where !notes.contains(where: { $0.text == error }) {
            notes.append(CloudSyncNote(text: error, isError: true))
        }
        return notes
    }

    /// A failed status needs attention. So does a remote batch that did not apply while
    /// the service says it is syncing or up to date: those words would be untrue. A
    /// paused or preparing session keeps its own word.
    static func cloudSyncNeedsAttention(
        status: CloudSyncSnapshot,
        remoteChangesError: String?
    ) -> Bool {
        switch status.phase {
        case .failed: true
        case .syncing, .current: remoteChangesError != nil
        case .disabled, .preparing, .paused: false
        }
    }

    func resolveCloudSyncConflict(
        _ recordID: SyncRecordID,
        choice: SyncConflictChoice
    ) async {
        guard deviceState.cloudSyncEnabled else { return }
        await cloudSyncService.resolveConflict(recordID, choice: choice)
    }

    /// Starts a new session from the document on disk. If the store cannot write it, the
    /// current session stays as it is.
    func retryCloudSync() async {
        guard deviceState.cloudSyncEnabled,
              let localDocument = await writeDocumentForCloudSyncStart() else { return }
        cloudSyncTask?.cancel()
        cloudSyncTask = nil
        await cloudSyncService.stop()
        hasStartedCloudSync = false
        await startCloudSyncIfSafe(with: localDocument)
    }

    /// Makes a new local backup before this Mac starts a session for a changed
    /// iCloud account or a replaced private zone.
    func approveCurrentCloudSyncAccount() async throws {
        guard deviceState.cloudSyncEnabled,
              cloudSyncStatus.requiresAccountApproval else { return }
        let backupURL = try makeCloudSyncBackupURL()
        do {
            try await backup(to: backupURL, notifyCloudSync: false)
            cloudSyncBackupURL = backupURL
            cloudSyncStatus = CloudSyncSnapshot(phase: .preparing)
            await cloudSyncService.approveCurrentAccount(
                localDocument: SyncedDocument(document: document)
            )
        } catch {
            cloudSyncStatus = CloudSyncSnapshot(
                phase: .failed,
                message: "Obolo did not continue iCloud sync. \(error.localizedDescription)",
                requiresAccountApproval: true
            )
            cloudSyncError = cloudSyncStatus.message
            throw error
        }
    }

    private func makeCloudSyncBackupURL() throws -> URL {
        let directory = store.url.deletingLastPathComponent().appending(
            path: AppPaths.cloudSyncBackupsDirectoryName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let filename = "Obolo before iCloud \(formatter.string(from: today)) \(UUID().uuidString.prefix(8)).json"
        return directory.appending(path: filename, directoryHint: .notDirectory)
    }

    func backup(to url: URL, notifyCloudSync: Bool = true) async throws {
        // `DocumentStore.backup` copies what is on disk, and while recovery is pending
        // what is on disk is nothing at all. Refusing, with the path of the file that
        // still holds the data, is the only honest answer.
        if let storeRecovery {
            if let newerVersion = storeRecovery.newerVersion { throw newerVersion }
            throw RecoveryError.backupUnavailable(path: storeRecovery.path)
        }
        try await flushSave(notifyCloudSync: notifyCloudSync)
        try await store.backup(to: url)
    }

    func restore(from url: URL) async throws {
        // Restoring writes to the store's own path, which is exactly where an unreadable
        // file may still be sitting. It is moved aside first, and if it cannot be moved,
        // nothing is written over it.
        try makeStorePathWritable()
        let restored = try await store.restore(from: url)
        // A restore *is* the answer to the banner: the backup has been written to the
        // canonical path, so there is a readable store file again and nothing left to
        // recover. Clearing this here rather than waiting for a Continue means the one
        // action that fixes the problem also finishes with it.
        if storeRecovery != nil {
            storeRecovery = nil
            RecoverySidecar.delete(besideStoreAt: store.url)
        }
        apply(restored)
        documentDidChange()
        // A backup can contain missing or old rates. Missing rates bypass the throttle.
        // Existing rates use the normal age check.
        refreshRatesAfterRestore()
    }

    // MARK: Settings, categories, rates

    /// Adding the first subscription or answering a setup prompt completes first run.
    /// After that, the login item follows the system setting.
    ///
    /// Part of the mutation that called it: the caller's own `documentDidChange()`
    /// saves it and tells the services once, with the new subscription in the ledger.
    private func markFirstRunComplete() {
        guard !document.settings.hasCompletedFirstRun else { return }
        document.settings.hasCompletedFirstRun = true
        settings.apply(document.settings)
    }

    /// The single writer for `Settings`. `SettingsStore` calls this; so do the empty
    /// Home's set-up steps.
    func updateSettings(_ newSettings: Settings) {
        guard document.settings != newSettings else { return }
        let previousBase = document.settings.baseCurrency
        let wasAutoUpdating = document.settings.autoUpdateRates
        let previousCalendarID = document.settings.calendarIdentifier
        let wasSyncing = document.settings.calendarSyncEnabled
        document.settings = newSettings
        // Keeps the wrapper in step when the change came from somewhere else — the
        // empty Home's set-up steps, a restored backup. `apply` does not call back.
        settings.apply(newSettings)
        // A new base is a new set of rates: every downloaded number was "how much of
        // the *old* base is this worth", which is meaningless now, so those go and are
        // refetched. Hand-entered ones stay exactly as typed — that is what the pane
        // promises, and re-deriving somebody's negotiated rate is not this app's call.
        if newSettings.baseCurrency != previousBase {
            rebaseRates(to: newSettings.baseCurrency)
        }
        // The ledger reads `baseCurrency`, and the scheduler
        // reads the lead time and the notification hour, so every settings change is
        // potentially both. Recomputing a ledger is cheap; getting this wrong means a
        // reminder at the old time.
        // Turning sync off, or pointing it at a different calendar, has to clean up after
        // itself. Reconcile cannot: it is the wrong side of the switch by the time it
        // runs, and the calendar it would have to tidy is one the settings no longer
        // name. So the old calendar is emptied of our events here, before the new
        // arrangement takes over.
        let syncStopped = wasSyncing && !newSettings.calendarSyncEnabled
        let calendarMoved = wasSyncing && newSettings.calendarIdentifier != previousCalendarID
        let teardown = (syncStopped || calendarMoved) ? calendarService : nil

        // A delayed reconcile still carries the old settings. Stop it before teardown,
        // or it can recreate events after the user turns sync off.
        if teardown != nil {
            calendarTask?.cancel()
            calendarTask = nil
        }

        // The two have to be *ordered*, not merely both started. The teardown removes
        // the events the stored identifiers name, and a reconcile that got in first would
        // have pointed those identifiers at brand new events in the new calendar — which
        // the teardown would then delete. So the services are told nothing yet, and the
        // teardown tells them when it is finished.
        documentDidChange(notifyServices: teardown == nil)
        if let teardown {
            Task {
                await teardown.removeAllManagedEvents(from: previousCalendarID)
                notifyServices()
            }
        }

        if newSettings.baseCurrency != previousBase || (newSettings.autoUpdateRates && !wasAutoUpdating) {
            Task { await refreshRates(force: true) }
        }
    }

    /// Deletes a category and re-homes what was in it.
    ///
    /// The rule about which categories may go, and where their subscriptions land, is
    /// `StoreDocument.removeCategory` — the app neither repeats it nor checks names.
    /// `false` means the document refused, which the pane's own button state prevents.
    @discardableResult
    func removeCategory(id: OboloCore.Category.ID) -> Bool {
        guard document.removeCategory(id: id) else { return false }
        documentDidChange()
        return true
    }

    /// Forgets every calendar event identifier in one write. Called by `CalendarSync`
    /// after it has emptied a calendar: the events are gone, so the identifiers name
    /// nothing, and a later re-enable must create rather than hunt for them.
    func clearCalendarEventIdentifiers() {
        guard !deviceState.allCalendarEventIdentifiers.isEmpty else { return }
        deviceState.removeAllCalendarEventIdentifiers()
        scheduleDeviceStateSave()
    }

    /// Records the event that belongs to one subscription.
    ///
    /// CalendarSync has already reconciled this row. The app must save the identifier
    /// without starting another reconcile.
    func recordCalendarEventIdentifier(_ identifier: String?, for id: Subscription.ID) {
        // A non-nil identifier must belong to a live row. Clearing is also valid after
        // the row was deleted, when the Undo period ends.
        guard identifier == nil || document.subscription(id: id) != nil else { return }
        guard deviceState.calendarEventIdentifier(for: id) != identifier else { return }
        deviceState.setCalendarEventIdentifier(identifier, for: id)
        scheduleDeviceStateSave()
    }

    func calendarEventIdentifier(for id: Subscription.ID) -> String? {
        deviceState.calendarEventIdentifier(for: id)
    }

    var allCalendarEventIdentifiers: [String] {
        deviceState.allCalendarEventIdentifiers
    }

    func updateCategories(_ categories: [OboloCore.Category]) {
        document.categories = categories
        // Deleting a category moves its subscriptions to Other rather than orphaning
        // them. `StoreDocument` owns that rule — and guarantees Other exists — so the
        // pane can hand over any list it likes.
        document.repairDanglingCategories()
        documentDidChange()
    }

    func updateRates(_ rates: RateTable) {
        document.rates = rates
        documentDidChange()
    }

    /// Drops the currency's own rate and lets the next refresh supply it — the "Use
    /// automatic" action on a row the user had typed over.
    func useAutomaticRate(for currency: String) {
        var rates = document.rates
        rates.removeRate(for: currency)
        document.rates = rates
        documentDidChange()
        Task { await refreshRates(force: true) }
    }

    // MARK: Refreshing the rates

    /// Fetches today's ECB reference rates for the currencies this document actually
    /// uses, and folds them in without touching anything the user typed.
    ///
    /// Silent by design. It runs on launch, when the day rolls over, when a currency
    /// appears that has no rate, and when the base changes; a failure leaves the last
    /// rates in place and says so in one line in Settings, because the alternative —
    /// an alert about a currency conversion — is not worth interrupting anybody for.
    ///
    /// `force` skips the once-a-day check, not the switch: a user who turned automatic
    /// rates off has turned them off.
    ///
    /// A launch, a day change and an edit can arrive within a second of each other, and
    /// a second caller that wants exactly what is already in the air simply waits for it.
    /// A caller that wants something *else* does not: a forced refresh — the user pressed
    /// Update, or typed a rate away — and a request for a different base or a different
    /// set of currencies both queue one more pass to run when the first one is finished.
    /// Waiting for somebody else's request and calling that an answer is how "Update
    /// rates" came to do nothing at all when it was pressed a moment after launch.
    ///
    /// One pass is queued, never a pile of them. The queued pass reads the document when
    /// it runs, so it answers everybody waiting behind it, and every caller here waits
    /// until its own question has been asked.
    func refreshRates(force: Bool = false) async {
        let request = RateRequest(
            base: document.settings.baseCurrency,
            symbols: document.rates.currenciesNeedingRates(in: document)
        )

        if let inFlight = rateRefreshTask {
            if force || request != inFlightRateRequest {
                queuedRateRefresh = (queuedRateRefresh ?? false) || force
            }
            await inFlight.value
            return
        }

        // Recorded before the task starts, so a caller that arrives in the meantime can
        // tell "the same request" from a different one.
        inFlightRateRequest = request

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var force = force
            repeat {
                await performRateRefresh(force: force)
                // Any pass after the first takes its own answer from the queue.
                force = false
            } while queuedRateRefresh != nil
            rateRefreshTask = nil
            inFlightRateRequest = nil
        }
        rateRefreshTask = task
        await task.value
    }

    /// One request, from the throttle to the rates being folded in.
    ///
    /// Everything up to the fetch itself runs without suspending, which is what makes the
    /// queue above safe: a caller that arrived before this pass reached the network is
    /// answered *by* this pass, and one that arrives after it gets a pass of its own.
    private func performRateRefresh(force: Bool) async {
        let force = force || (queuedRateRefresh ?? false)
        queuedRateRefresh = nil
        guard shouldRefreshRates(force: force) else { return }

        let base = document.settings.baseCurrency
        let symbols = document.rates.currenciesNeedingRates(in: document)
        inFlightRateRequest = RateRequest(base: base, symbols: symbols)
        rateRefreshState = .refreshing

        do {
            let result = try await rateService.fetch(base: base, symbols: symbols)
            // The user may have changed the base while the request was in the air;
            // rates to a base nobody is using any more would be worse than none.
            guard document.settings.baseCurrency == base else { return }
            var rates = document.rates
            // The moment the answer arrived, not the day it names: on a Monday
            // morning those are three days apart, and Settings says both.
            rates.applyAutomatic(result.ratesToBase, asOf: result.asOf, checkedAt: today)
            document.rates = rates
            documentDidChange()
            rateRefreshState = .updated(result.asOf)
        } catch {
            rateRefreshState = .failed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    /// Whether there is anything worth asking for, and whether it has been asked
    /// recently enough.
    ///
    /// The switch is the app's own business; everything after it is `RateRefreshPolicy`,
    /// which throttles on `lastCheckedAt` — the moment an answer last came back, not the
    /// day the rates in hand were published. The two are three days apart over a weekend,
    /// and throttling on the publication day is what made the app ask again every hour
    /// all Saturday for the same Friday number.
    private func shouldRefreshRates(force: Bool) -> Bool {
        guard document.settings.autoUpdateRates else { return false }
        return RateRefreshPolicy.shouldRefresh(
            lastCheckedAt: document.rates.lastCheckedAt,
            automaticAsOf: document.rates.automaticAsOf,
            now: today,
            force: force,
            hasCurrenciesNeedingRates: !document.rates.currenciesNeedingRates(in: document).isEmpty
        )
    }

    /// A currency that is in the list with nothing to convert it with — worth a request
    /// of its own, rather than waiting for tomorrow.
    ///
    /// Asked of the whole document rather than of one row, because a currency arrives
    /// through four doors and only one of them hands over a single code: an edit, an
    /// intent, a CSV import of a hundred rows, and a restored backup. The forced refresh
    /// still passes through `shouldRefreshRates`, so "Update rates automatically" being
    /// off is still the last word.
    private func refreshRatesForNewCurrencies() {
        let missing = document.rates.currenciesNeedingRates(in: document)
            .contains { !document.rates.hasRate(for: $0) }
        guard missing else { return }
        Task { await refreshRates(force: true) }
    }

    /// Refreshes a restored rate table. A missing rate needs an immediate request.
    /// An existing rate uses the normal age limit.
    private func refreshRatesAfterRestore() {
        let missing = document.rates.currenciesNeedingRates(in: document)
            .contains { !document.rates.hasRate(for: $0) }
        Task { await refreshRates(force: missing) }
    }

    /// Re-points the table at a new base. Downloaded rates go — they answered a
    /// question nobody is asking any more — and typed ones stay.
    private func rebaseRates(to newBase: String) {
        let code = Subscription.normalizedCurrency(newBase)
        let kept = document.rates.rates.filter { $0.key != code && $0.value.source == .manual }
        document.rates = RateTable(base: code, rates: kept)
        rateRefreshState = .idle
    }

    /// Disable future sync before removing events, so queued work cannot recreate them.
    func removeCalendarReminders() async throws {
        guard let calendarService else { return }
        let running = calendarTask
        running?.cancel()
        calendarTask = nil
        let identifier = document.settings.calendarIdentifier
        document.settings.calendarSyncEnabled = false
        settings.apply(document.settings)
        documentDidChange(notifyServices: false)
        await running?.value
        try await calendarService.removeAllManagedEventsReporting(from: identifier)
    }

    private(set) var calendarSyncError: String?

    func recordCalendarSyncError(_ message: String?) {
        calendarSyncError = message
    }

    /// Records when the calendar was last reconciled. Called by `CalendarSync` itself,
    /// so it notifies no service: the one notified would be the one that just wrote
    /// this value, and it would reconcile and stamp again with no end. Nothing derived
    /// depends on the stamp, so the ledger is left alone; only the save is scheduled.
    func recordCalendarSync(at date: Date?) {
        calendarSyncError = nil
        guard deviceState.lastCalendarSyncAt != date else { return }
        deviceState.lastCalendarSyncAt = date
        scheduleDeviceStateSave()
    }

    var lastCalendarSyncAt: Date? { deviceState.lastCalendarSyncAt }

    // MARK: - Reads

    func subscription(_ id: Subscription.ID?) -> Subscription? {
        guard let id else { return nil }
        return document.subscription(id: id)
    }

    func summary(_ id: Subscription.ID?) -> SubscriptionSummary? {
        guard let id else { return nil }
        return ledger.summary(id: id)
    }

    func category(_ id: OboloCore.Category.ID) -> OboloCore.Category? {
        document.category(id: id)
    }

    /// What the add form starts from: the base currency, a monthly cadence, today's
    /// date and the next tint in the round-robin, so two subscriptions added in a row
    /// do not come out the same colour.
    func newSubscriptionTemplate() -> Subscription {
        Subscription(
            name: "",
            tint: Tint.roundRobin(document.subscriptions.count),
            categoryID: document.fallbackCategoryID,
            price: 0,
            currency: document.settings.baseCurrency,
            cycle: .monthly,
            anchorDate: BillingDay(today, calendar: calendar),
            createdAt: today
        )
    }

    /// Offer the base currency first, followed by currencies with rates, currencies in use,
    /// and the common defaults EUR, USD, GBP and CHF. Each code appears once.
    var currencyChoices: [String] {
        var seen = Set<String>()
        var result: [String] = []
        let candidates = [document.settings.baseCurrency]
            + document.rates.currencies
            + document.subscriptions.map(\.currency)
            + ["EUR", "USD", "GBP", "CHF"]
        for code in candidates {
            let normalized = Subscription.normalizedCurrency(code)
            guard normalized.count == 3, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    /// The rows the current section and sort order add up to. The one place the All
    /// list, its status line and the menu bar's reveal agree on what is on screen.
    ///
    /// `search:` stays in the ledger's signature — it is how the All search slices the
    /// list — but this passes none, so every section shows everything it holds; the
    /// search (`searchRows`) and the pills (`allRows(scope:)`) narrow from there.
    var rows: [SubscriptionSummary] {
        let section = section
        if section == .all { return sortedAllRows }
        return ledger.sorted(sortOrder, search: "", section: section, ascending: sortAscending)
    }

    /// All, its footer and search share the same order until the ledger or sort changes.
    var sortedAllRows: [SubscriptionSummary] {
        let ledger = ledger
        let order = sortOrder
        let ascending = sortAscending ?? order.naturalAscending
        let locale = Locale.current
        if let cached = sortedAllRowsCache,
           cached.order == order, cached.ascending == ascending, cached.locale == locale {
            return cached.rows
        }
        let rows = Ledger.sort(ledger.summaries, by: order, ascending: ascending)
        sortedAllRowsCache = (order, ascending, locale, rows)
        return rows
    }

    /// The `.navigationTitle`. `Section` resolves a category's name from the document,
    /// so the title, the All list's chip and its status line cannot drift apart.
    var sectionTitle: String { section.title(in: document) }

    /// The All category dropdown's rows: every category that something is filed under,
    /// in `sortOrder`.
    ///
    /// A category with no subscriptions at all is a row that leads to an empty list, so
    /// it is left out. Membership, not money, is the test: a category holding only
    /// cancelled items still has something to show, and the dropdown counts it 0.
    var dropdownCategories: [OboloCore.Category] {
        let occupied = Set(document.subscriptions.map(\.categoryID))
        return document.categories
            .filter { occupied.contains($0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var allCount: Int { document.subscriptions.count }

    // MARK: - Plumbing

    private func mutate(_ id: Subscription.ID, _ change: (inout Subscription) -> Void) {
        guard let index = document.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        change(&document.subscriptions[index])
        documentDidChange()
    }

    /// The one path out of every mutation.
    private func documentDidChange(recomputeLedger shouldRecompute: Bool = true, notifyServices shouldNotify: Bool = true) {
        closeWhatShowsMissingRows()
        if shouldRecompute { recomputeLedger() }
        scheduleSave()
        if shouldNotify { notifyServices() }
    }

    private func recomputeLedger() {
        ledger = Ledger(document: document, today: today, calendar: calendar)
    }

    // MARK: Saving

    /// The recovery this launch inherits, if the last one left the store quarantined.
    ///
    /// Both halves have to hold: no canonical file, and a note beside where it should
    /// be. A note on its own is stale — the user put a file back by hand — and a file on
    /// its own is an ordinary launch.
    private func pendingRecovery() -> StoreRecovery? {
        guard !FileManager.default.fileExists(atPath: store.url.path(percentEncoded: false)),
              let sidecar = RecoverySidecar.read(besideStoreAt: store.url)
        else { return nil }
        // A note only ever exists for a file that really was moved: the writer deletes it
        // again if the move does not happen.
        return StoreRecovery(path: sidecar.movedTo, fileState: .movedAside, error: sidecar.error)
    }

    /// Frees the store's own path, so that what is written there next cannot land on top
    /// of a file the user may still be able to salvage.
    ///
    /// Only a recovery that left the file in place has anything in the way. The move that
    /// failed at launch is tried again, because the reason it failed — a full disk — is
    /// exactly the kind of thing that stops being true; and if it worked, the recovery is
    /// updated to point at where the file went, so the banner and the Data pane stay
    /// truthful even if the write that follows this fails.
    private func makeStorePathWritable() throws {
        if let newerVersion = storeRecovery?.newerVersion { throw newerVersion }
        guard let recovery = storeRecovery, recovery.fileState == .leftInPlace else { return }
        switch quarantineStoreFile(reason: recovery.error) {
        case .moved(let destination):
            storeRecovery = StoreRecovery(
                path: destination, fileState: .movedAside, error: recovery.error
            )
        case .nothingToMove:
            break
        case .failed(let reason):
            throw RecoveryError.fileNotMoved(reason: reason)
        }
    }

    /// What became of the unreadable file.
    private enum QuarantineResult {
        /// It is at this path now, with a note beside the store that says so.
        case moved(URL)
        /// There was nothing at the store's path to move.
        case nothingToMove
        /// It is still at the store's path, and no note claims otherwise.
        case failed(reason: String)
    }

    /// Moves an unreadable store file next to itself as
    /// `obolo.json.corrupt-<yyyyMMdd-HHmmss>`, leaving the note that records where it
    /// went — in that order, which is the whole point of this method.
    ///
    /// A move, never a delete: the file is the user's data, and even a file this app
    /// cannot decode may be readable by a text editor or salvageable by hand. A second
    /// launch that fails the same way gets its own stamp, so nothing overwrites anything.
    ///
    /// **The note is written first, and the file is moved only if that worked.** The
    /// state this must never reach is a moved file with nothing recording where it went:
    /// the next launch would find no `obolo.json` and no note, read that as a first
    /// install, and start writing an empty document beside a `.corrupt-` file that
    /// nothing on screen mentions. Writing the note afterwards cannot give that
    /// guarantee, because the realistic reason a 200-byte note fails to write is a full
    /// disk, and a disk that is full after the move was full before it too.
    ///
    /// So both failure paths end in the same safe place: the file stays exactly where it
    /// is, and the caller keeps the recovery in memory. Nothing is at risk there. Saving
    /// is blocked for as long as a recovery is in hand, and the next launch reads the
    /// same unreadable file and comes back to the same banner.
    private func quarantineStoreFile(reason: String) -> QuarantineResult {
        let source = store.url
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { return .nothingToMove }

        // A fixed pattern, in a fixed locale: this is a file name, not something a person
        // reads in their own format.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var stamp = formatter.string(from: Date())

        let folder = source.deletingLastPathComponent()
        let base = source.lastPathComponent
        var destination = folder.appending(path: "\(base).corrupt-\(stamp)", directoryHint: .notDirectory)
        var attempt = 2
        while manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            stamp = "\(stamp)-\(attempt)"
            destination = folder.appending(path: "\(base).corrupt-\(stamp)", directoryHint: .notDirectory)
            attempt += 1
        }

        do {
            try RecoverySidecar(movedTo: destination, error: reason, at: Date())
                .write(besideStoreAt: source)
        } catch {
            return .failed(reason: error.localizedDescription)
        }

        do {
            try manager.moveItem(at: source, to: destination)
            return .moved(destination)
        } catch {
            // The note now describes something that did not happen. A note naming a file
            // that is not there is worse than no note at all, so it goes with the move.
            RecoverySidecar.delete(besideStoreAt: source)
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Debounced 250 ms. Typing in the form's name field is a mutation per keystroke,
    /// and an atomic write per keystroke would be a rename storm for no benefit.
    private func scheduleSave() {
        // Nothing is written while a corrupt file is waiting to be answered for.
        guard storeRecovery == nil else { return }
        let snapshot = document
        let remoteRevision = cloudSyncRemoteRevision
        saveTask?.cancel()
        saveIsPending = true
        saveTask = Task { [store] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // From here a cancel does not stop the write.
            self.saveIsPending = false
            await Self.write(snapshot, to: store, afterRemoteRevision: remoteRevision, reportingTo: self)
        }
    }

    /// Saves state that is valid only on this Mac. This write is independent from the
    /// portable document, but it uses the same short debounce.
    private func scheduleDeviceStateSave() {
        guard !deviceStateWritesBlocked else { return }
        deviceStateNeedsSave = true
        let snapshot = deviceState
        deviceStateSaveTask?.cancel()
        deviceStateSaveTask = Task { [deviceStateStore] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: deviceStateStore, reportingTo: self)
        }
    }

    /// Writes now and waits — for `applicationWillTerminate`, and before a backup.
    ///
    /// Sync hears about the value this call wrote, as the debounced path does with its
    /// `snapshot`. An edit made while the store writes is not on disk yet: its own
    /// save writes it and then tells sync.
    func flushSave(notifyCloudSync: Bool = true) async throws {
        deviceStateSaveTask?.cancel()
        deviceStateSaveTask = nil
        let remoteRevision = cloudSyncRemoteRevision
        guard let snapshot = try await writeDocumentNow() else { return }
        if deviceStateNeedsSave, !deviceStateWritesBlocked {
            try await deviceStateStore.save(deviceState)
            deviceStateNeedsSave = false
            deviceStateError = nil
        }
        if notifyCloudSync { await cloudSyncAfterSave(snapshot, afterRemoteRevision: remoteRevision) }
    }

    /// Writes `document` now in place of the debounced save, and returns the value it
    /// wrote. Nil while store recovery blocks writes: quitting is not an answer to the
    /// banner, as an unread store file survives the relaunch untouched, and the banner
    /// comes back with it.
    private func writeDocumentNow() async throws -> StoreDocument? {
        saveTask?.cancel()
        saveTask = nil
        saveIsPending = false
        guard storeRecovery == nil else { return nil }
        let snapshot = document
        try await store.save(snapshot)
        saveError = nil
        return snapshot
    }

    /// The document for a session that the user asks for (Try Again, a repeated enable):
    /// written first, so that the session starts from what the store holds, like a
    /// session that a save starts (`cloudSyncAfterSave`). An edit can still wait for its
    /// debounced save, or be only in memory after a save failed.
    ///
    /// Nil when the write fails or store recovery blocks it, and then no session starts.
    /// The failure shows as `saveError`. A debounced save that the write replaced is
    /// scheduled again, as after a failed merged write (`applyRemoteChanges`).
    private func writeDocumentForCloudSyncStart() async -> StoreDocument? {
        let cancelledPendingSave = saveIsPending
        do {
            return try await writeDocumentNow()
        } catch {
            saveError = "Obolo cannot save the document. \(error.localizedDescription)"
            if cancelledPendingSave, !saveIsPending { scheduleSave() }
            return nil
        }
    }

    private static func write(
        _ document: StoreDocument,
        to store: DocumentStore,
        afterRemoteRevision remoteRevision: Int,
        reportingTo model: AppModel
    ) async {
        do {
            try await store.save(document)
            await MainActor.run {
                model.saveError = nil
            }
            await model.cloudSyncAfterSave(document, afterRemoteRevision: remoteRevision)
        } catch {
            await MainActor.run {
                model.saveError = "Obolo cannot save the document. \(error.localizedDescription)"
            }
        }
    }

    private static func write(
        _ state: DeviceState,
        to store: DeviceStateStore,
        reportingTo model: AppModel
    ) async {
        do {
            try await store.save(state)
            await MainActor.run {
                if model.deviceState == state {
                    model.deviceStateNeedsSave = false
                }
                model.deviceStateError = nil
            }
        } catch {
            await MainActor.run {
                model.deviceStateError = "Obolo cannot save the settings for this Mac. \(error.localizedDescription)"
            }
        }
    }

    // MARK: Services

    /// Starts sync or adds a saved projection to its queue.
    ///
    /// The task chain preserves disk-save order. The service never receives a document
    /// while store recovery is active.
    private func cloudSyncAfterSave(_ savedDocument: StoreDocument, afterRemoteRevision remoteRevision: Int) async {
        guard storeRecovery == nil,
              deviceState.cloudSyncEnabled,
              remoteRevision == cloudSyncRemoteRevision else { return }
        if !hasStartedCloudSync {
            // A start replays a kept batch itself.
            await startCloudSyncIfSafe(with: savedDocument)
            return
        }
        // Read before the wait: a batch that fails while this save is queued waits for
        // a save that comes after it.
        let replayIsDue = cloudSyncReplaysAfterNextSave

        let snapshot = CloudSyncLocalSnapshot(
            document: SyncedDocument(document: savedDocument), remoteRevision: remoteRevision
        )
        await queueCloudSyncWork { await $0.localDocumentDidSave(snapshot) }.value
        if replayIsDue { replayRemoteChangesAfterSave() }
    }

    /// Runs `work` after the sync work already in `cloudSyncTask`, and becomes that
    /// task. The chain is what keeps the service's calls in disk-save order; once it is
    /// cancelled (sync turned off, or a retry), the queued work does not run.
    private func queueCloudSyncWork(
        _ work: @escaping @MainActor @Sendable (any CloudSyncService) async -> Void
    ) -> Task<Void, Never> {
        let previous = cloudSyncTask
        let service = cloudSyncService
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await work(service)
        }
        cloudSyncTask = task
        return task
    }

    /// Asks the service for one replay of the batch that the store could not save.
    ///
    /// The replay is queued after the work already in `cloudSyncTask`, so the service
    /// has the saved document first. It then runs the same path as a start or a fetch:
    /// `CloudSyncRemoteQueue`, then `applyRemoteChanges`. It is not awaited, so a save
    /// (also the one before quit) does not wait for a merge. Nothing is asked during
    /// store recovery, or while sync is off, paused, or waiting for approval: the flag
    /// stays set for a later save, and a start or a continue replays the batch anyway.
    /// If the replay fails to save again, `applyRemoteChanges` sets the flag again, so
    /// each successful save asks once at most. Nothing repeats by itself.
    private func replayRemoteChangesAfterSave() {
        guard cloudSyncReplaysAfterNextSave,
              storeRecovery == nil,
              deviceState.cloudSyncEnabled,
              hasStartedCloudSync,
              !cloudSyncStatus.requiresAccountApproval,
              cloudSyncStatus.phase != .paused,
              cloudSyncStatus.phase != .disabled
        else { return }
        cloudSyncReplaysAfterNextSave = false
        _ = queueCloudSyncWork { await $0.replayRemoteChanges() }
    }

    /// Starts one sync session after the local store is safe to use.
    private func startCloudSyncIfSafe(with localDocument: StoreDocument) async {
        guard storeRecovery == nil,
              deviceState.cloudSyncEnabled,
              !hasStartedCloudSync else { return }
        hasStartedCloudSync = true

        let projection = SyncedDocument(document: localDocument)
        // Holds `self` strongly, as this task always has; the session's callbacks
        // below hold it weakly.
        await queueCloudSyncWork { [self] service in
            await service.start(
                localDocument: projection,
                receiveRemoteChanges: { [weak self, cloudSyncRemoteQueue] baseDocument, remoteDocument in
                    await cloudSyncRemoteQueue.perform { [weak self] in
                        guard let self else { return nil }
                        return await self.applyRemoteChanges(
                            baseDocument: baseDocument,
                            remoteDocument: remoteDocument
                        )
                    }
                },
                reportStatus: { [weak self] snapshot in
                    await MainActor.run {
                        guard let self else { return }
                        self.cloudSyncStatus = snapshot
                        self.cloudSyncError = snapshot.phase == .failed
                            ? snapshot.message
                            : nil
                    }
                }
            )
        }.value
    }

    /// Merges and saves remote data without letting the sync service write the store.
    private func applyRemoteChanges(
        baseDocument: SyncedDocument,
        remoteDocument: SyncedDocument
    ) async -> CloudSyncAppliedMerge? {
        while storeRecovery == nil {
            let localDocument = document
            let result: SyncMergeResult
            do {
                result = try SyncMerge.merge(
                    base: baseDocument,
                    local: SyncedDocument(document: localDocument),
                    remote: remoteDocument,
                    today: today,
                    calendar: calendar
                )
            } catch {
                // A save cannot help this batch, so no save asks for it again.
                cloudSyncReplaysAfterNextSave = false
                cloudSyncRemoteChangesError = "Obolo cannot merge the iCloud changes. Update Obolo and try again."
                return nil
            }

            let mergedDocument = result.document.applying(to: localDocument)
            // The merged document contains the local edit that a pending save would
            // write, so this write replaces that save.
            let cancelledPendingSave = saveIsPending
            saveTask?.cancel()
            saveTask = nil
            saveIsPending = false
            do {
                try await store.save(mergedDocument)
            } catch {
                saveError = "Obolo cannot save the document. \(error.localizedDescription)"
                // The next local save that succeeds asks for this batch again.
                cloudSyncReplaysAfterNextSave = true
                cloudSyncRemoteChangesError = "Obolo cannot save the iCloud changes on this Mac. Obolo tries again when it saves your next change."
                // The cancelled save did not happen, so the local edit is only in memory.
                // Schedule it again. Only a save that this write cancelled comes back: a
                // replay with no pending save schedules nothing, so a store that keeps
                // failing does not start a loop. A user edit during the write scheduled
                // its own save of the newest document, which is enough.
                if cancelledPendingSave, !saveIsPending { scheduleSave() }
                return nil
            }

            // A user edit can run while the actor waits for the store. Merge again with
            // that newer value instead of replacing it with the earlier calculation.
            guard document == localDocument else { continue }

            _ = apply(mergedDocument)
            cloudSyncRemoteRevision += 1
            saveError = nil
            cloudSyncError = nil
            cloudSyncRemoteChangesError = nil
            cloudSyncReplaysAfterNextSave = false
            notifyServices()
            refreshRatesForNewCurrencies()
            return CloudSyncAppliedMerge(result: result, remoteRevision: cloudSyncRemoteRevision)
        }
        return nil
    }

    /// Reminders waits for this pass before reading back the system queue.
    var notificationScheduleTask: Task<Void, Never>? {
        access(keyPath: \.notificationScheduleTask)
        return scheduleTask
    }

    @discardableResult
    func rescheduleNotifications() -> Bool {
        guard storeRecovery?.newerVersion == nil, let notificationScheduler else { return false }
        let ledger = ledger
        let previous = scheduleTask
        previous?.cancel()
        withMutation(keyPath: \.notificationScheduleTask) {
            scheduleTask = Task {
                // A cancelled pass may still be writing to macOS. Let it finish before
                // replacing its requests, and skip any superseded passes that never ran.
                await previous?.value
                guard !Task.isCancelled else { return }
                await notificationScheduler.reschedule(ledger: ledger)
            }
        }
        return true
    }

    /// Tells the scheduler and the calendar that the document moved. Calendar work
    /// waits briefly so a burst of related edits produces one reconcile.
    func notifyServices() {
        guard storeRecovery?.newerVersion == nil else { return }
        rescheduleNotifications()
        calendarTask?.cancel()
        calendarTask = nil
        if let calendarSync, document.settings.calendarSyncEnabled, !deviceStateWritesBlocked {
            let document = document
            calendarTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await calendarSync.reconcile(document: document)
            }
        }
    }

    // MARK: The day rolling over
    //
    // Every figure in this app is relative to "today": days-until, due-soon, the
    // upcoming list, the menu bar label. An app left open overnight would show
    // yesterday's answers, and the one the user checks in the morning is exactly the
    // one that has gone stale.

    private func observeDayChanges() {
        dayChangeObservers = [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dayDidChange()
                }
            }
        }
    }

    /// A belt-and-braces timer beside the notification: `NSCalendarDayChanged` is not
    /// delivered while the machine is asleep, and it is the notification that is
    /// missing exactly when the app has been sitting open all night.
    private func scheduleMidnightRecompute() {
        midnightTask?.cancel()
        guard let next = calendar.nextDate(
            after: today,
            matching: DateComponents(hour: 0, minute: 0, second: 5),
            matchingPolicy: .nextTime
        ) else { return }

        let interval = next.timeIntervalSince(today)
        guard interval > 0 else { return }
        midnightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.dayDidChange()
        }
    }

    private func dayDidChange() {
        // The shared month starts again from the current one.
        showCurrentMonth()
        recomputeLedger()
        notifyServices()
        scheduleMidnightRecompute()
        // Yesterday's rates are as stale as yesterday's dates.
        Task { await refreshRates() }
    }
}
