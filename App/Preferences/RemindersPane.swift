import AppKit
import EventKit
import SwiftUI
import UserNotifications
import OboloCore

/// Preferences → Reminders: the two channels a renewal can reach the user through, and
/// the two permissions they depend on.
///
/// This pane **reads** system state and asks for access; it schedules nothing. The
/// notification scheduler and the calendar sync live in `App/Services` and run off the
/// document, so everything here is a switch, a status line, or a button that hands the
/// work to one of them. It asks the services rather than the frameworks directly, so
/// one place owns access requests and calendar sorting.
struct RemindersPane: View {

    @Bindable var settings: SettingsStore
    var model: AppModel

    // Probed rather than stored. Both grants can be changed in System Settings while
    // the app is running — that is what the buttons on this pane are for — so the rows
    // re-read them every time the app comes forward instead of trusting launch.
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var notificationProbe = 0
    @State private var calendarStatus = CalendarSync.authorizationStatus

    @State private var calendars: [CalendarChoice] = []
    @State private var isRequestingCalendar = false
    @State private var isResyncing = false
    @State private var isRemovingCalendarReminders = false
    @State private var confirmRemoveCalendarReminders = false
    @State private var calendarActionMessage: String?


    /// What `UNUserNotificationCenter` says it will actually post.
    @State private var pending: [PendingReminder]?

    private struct NotificationRefresh: Equatable {
        let schedule: Task<Void, Never>?
        let probe: Int
    }

    private var notificationRefresh: NotificationRefresh {
        NotificationRefresh(schedule: model.notificationScheduleTask, probe: notificationProbe)
    }

    var body: some View {
        let refresh = notificationRefresh
        PrefPage(tab: .reminders) {
            notifications
            calendar
        }
        .confirmationDialog("Remove all calendar reminders?", isPresented: $confirmRemoveCalendarReminders, titleVisibility: .visible) {
            Button("Remove all reminders", role: .destructive) { removeCalendarReminders() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes calendar events created by Obolo and turns calendar sync off. Your other calendar events and Mac notifications are kept.")
        }
        .task { refreshCalendar() }
        .task(id: refresh) { await refreshNotifications(for: refresh) }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshCalendar()
            notificationProbe += 1
        }
    }

    // MARK: - Notifications

    /// The switch, then — only while it is on — the permission (when it needs the user),
    /// the default lead, the time and what macOS has queued.
    private var notifications: some View {
        PrefSection("Mac notifications") {
            PrefToggleRow("Notify me before a renewal", isOn: $settings.notificationsEnabled)

            if settings.notificationsEnabled {
                // Granted is the quiet case: the row only appears when there is
                // something for the user to do.
                if let notificationStatus, !NotificationScheduler.allowsNotifications(notificationStatus) {
                    StatusRow(
                        tint: notificationTint,
                        title: notificationTitle,
                        description: notificationDescription,
                        actionTitle: notificationActionTitle,
                        action: notificationAction
                    )
                }

                PrefRow("Remind me", "Default for new subscriptions; each one can change it.") {
                    PrefPicker(
                        selection: $settings.defaultReminderLeadDays,
                        options: leadOptions,
                        accessibilityLabel: "Remind me"
                    )
                }

                reminderTimeRow

                scheduledRow
            }
        }
    }

    /// The same words as the status line and empty Home ("1 week before"), with a
    /// capital first letter because each one starts a menu item.
    private var leadOptions: [(value: Int, title: String)] {
        ([0] + OboloCore.Settings.reminderLeadChoices).map { days in
            let text = OboloCore.Settings.reminderLeadText(days: days)
            return (value: days, title: text.prefix(1).uppercased() + text.dropFirst())
        }
    }

    private var notificationTint: Color {
        notificationStatus == .denied ? DS.Palette.danger : DS.Palette.warning
    }

    // The three helpers below feed the status row, which shows only while access is
    // not granted, so they never meet `.authorized`, `.provisional` or `.ephemeral`.

    private var notificationTitle: String {
        switch notificationStatus {
        case .denied: "Notifications denied"
        default: "Notifications not requested yet"
        }
    }

    private var notificationDescription: String {
        switch notificationStatus {
        case .denied:
            "macOS blocks them. Turn Obolo back on in System Settings."
        default:
            "Choose Allow notifications to let Obolo send reminders."
        }
    }

    private var notificationActionTitle: String {
        switch notificationStatus {
        case .denied: "Open System Settings"
        default: "Allow notifications"
        }
    }

    private func notificationAction() {
        switch notificationStatus {
        case .denied:
            open(NotificationScheduler.settingsURL)
        default:
            Task {
                if await NotificationScheduler.requestAuthorization() {
                    model.rescheduleNotifications()
                }
                notificationProbe += 1
            }
        }
    }

    // MARK: - Scheduled reminders

    private var scheduledRow: some View {
        PrefRow("Scheduled reminders", scheduledDescription) {
            if let pending {
                if pending.isEmpty {
                    PrefValue("Nothing queued")
                } else {
                    PrefMenu("\(pending.count) queued", accessibilityLabel: "Scheduled reminders") {
                        ForEach(pending) { reminder in
                            Text("\(reminder.title) · \(reminder.date.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var scheduledDescription: String {
        guard let pending, let notificationStatus else { return "Checking what macOS has queued." }
        guard pending.isEmpty else { return "As macOS holds them. Rescheduled after each change and each day." }
        return Self.emptyQueueDescription(ledger: model.ledger, status: notificationStatus)
    }

    static func emptyQueueDescription(ledger: Ledger, status: UNAuthorizationStatus) -> String {
        if !ledger.document.settings.notificationsEnabled {
            return "Notifications are off."
        }
        if ledger.summaries.allSatisfy({ !$0.status.isBilling || $0.nextPayment == nil }) {
            return "No subscription has a known renewal date."
        }
        switch status {
        case .denied: return "Obolo does not have permission to send notifications on this Mac."
        case .notDetermined: return "Choose Allow notifications to let Obolo send reminders."
        default: return "No reminders are scheduled."
        }
    }

    private func refreshNotifications(for refresh: NotificationRefresh) async {
        await refresh.schedule?.value
        guard !Task.isCancelled, refresh == notificationRefresh else { return }

        let status = await NotificationScheduler.authorizationStatus()
        guard !Task.isCancelled, refresh == notificationRefresh else { return }

        let scheduler = model.scheduler
        if settings.notificationsEnabled,
           let wasAuthorized = scheduler?.wasAuthorized,
           wasAuthorized != NotificationScheduler.allowsNotifications(status),
           model.rescheduleNotifications() {
            return
        }

        let systemQueue = await scheduler?.pending() ?? []
        guard !Task.isCancelled, refresh == notificationRefresh else { return }
        notificationStatus = status
        pending = systemQueue.map(PendingReminder.init)
    }

    // MARK: - Calendar

    /// The switch, then — only while it is on — access (when it is not full), the
    /// calendar, the alert offsets, the sync status and the way out.
    private var calendar: some View {
        PrefSection("Calendar events") {
            PrefToggleRow(
                "Add payments to a calendar",
                "One repeating all-day event per subscription. Obolo only touches its own events.",
                isOn: $settings.calendarSyncEnabled
            )
            .disabled(isResyncing || isRemovingCalendarReminders)

            if settings.calendarSyncEnabled {
                if hasCalendarAccess {
                    calendarPickerRow
                        .disabled(isResyncing || isRemovingCalendarReminders)
                } else {
                    StatusRow(
                        tint: calendarTint,
                        title: calendarTitle,
                        description: calendarDescription,
                        actionTitle: calendarActionTitle,
                        action: calendarAction,
                        isBusy: isRequestingCalendar
                    )
                }

                alertOffsetsRow
                    .disabled(isResyncing || isRemovingCalendarReminders)
                // Calendar alerts use the reminder time too: with notifications off it
                // lives here instead, so it can always be changed while it matters.
                if !settings.notificationsEnabled {
                    reminderTimeRow
                }
                resyncRow
                PrefRow("Remove calendar reminders", "Deletes Obolo’s events and turns sync off.") {
                    if isRemovingCalendarReminders {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Remove") {
                            confirmRemoveCalendarReminders = true
                        }
                        .prefButton(destructive: true)
                        .disabled(model.calendarService == nil || isResyncing)
                    }
                }
            }
        } footer: {
            // Outside the switch: removing turns sync off, and its result (or any
            // sync error) still has to be read once the rows above are gone.
            if let error = model.calendarSyncError {
                PrefFootnote(error, isError: true)
            }
            if let calendarActionMessage, !isResyncing {
                PrefFootnote(calendarActionMessage)
            }
            if settings.calendarSyncEnabled {
                PrefFootnote("Alerts use the reminder time; select no days for no alerts. Delete renewal events you added by hand to avoid duplicate alerts.")
            }
        }
    }

    /// Write-only access can add an event but cannot read one back, so it can neither
    /// list calendars nor reconcile. It is treated as "not connected" for everything
    /// except the sentence that explains why.
    private var hasCalendarAccess: Bool {
        calendarStatus == .fullAccess
    }

    private var calendarTint: Color {
        switch calendarStatus {
        case .denied, .restricted: DS.Palette.danger
        default: DS.Palette.warning
        }
    }

    // The three helpers below feed the status row, which shows only without full
    // access (`hasCalendarAccess`), so they never meet `.fullAccess`.

    private var calendarTitle: String {
        switch calendarStatus {
        case .writeOnly: "Write-only calendar access"
        case .denied: "Calendar access denied"
        case .restricted: "Calendar access restricted"
        default: "Calendar not connected"
        }
    }

    private var calendarDescription: String {
        switch calendarStatus {
        case .writeOnly:
            "Allow full access in System Settings to keep events updated."
        case .denied, .restricted:
            "Allow Obolo in System Settings → Privacy & Security → Calendars."
        default:
            "Obolo asks for access the first time you connect a calendar."
        }
    }

    private var calendarActionTitle: String {
        switch calendarStatus {
        case .denied, .restricted, .writeOnly: "Open System Settings"
        default: "Connect calendar"
        }
    }

    private func calendarAction() {
        switch calendarStatus {
        case .denied, .restricted, .writeOnly:
            open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars")
        default:
            requestCalendarAccess()
        }
    }

    private var calendarPickerRow: some View {
        PrefRow("Calendar", "An iCloud calendar brings events to your other devices.") {
            PrefPicker(
                selection: calendarBinding,
                options: [(String?.none, "None")] + calendars.map { (String?.some($0.id), $0.menuTitle) },
                accessibilityLabel: "Calendar"
            )
        }
    }

    private var calendarBinding: Binding<String?> {
        Binding(
            get: { settings.calendarIdentifier },
            set: { settings.calendarIdentifier = $0 }
        )
    }

    // MARK: - Alert offsets

    /// The time Mac notifications and calendar alerts both use. In the notifications
    /// card while notifications are on; otherwise in the calendar card while calendar
    /// sync is on; hidden only when both are off.
    private var reminderTimeRow: some View {
        PrefRow("Reminder time", "Used for Mac notifications and calendar alerts.") {
            DatePicker(
                "Reminder time",
                selection: $settings.notificationTimeDate,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.field)
            .labelsHidden()
            .accessibilityLabel(Text("Reminder time"))
        }
    }

    /// Multi-select, because a yearly charge and a weekly one want warning at different
    /// distances and the user should not have to choose one rule for both.
    ///
    /// The chips sit on their own line under the title rather than trailing it: five
    /// of them do not fit beside it at the pane's width.
    private var alertOffsetsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrefRowLabel(title: "Alert me")

            HStack(spacing: 6) {
                ForEach(SettingsStore.Defaults.calendarAlertChoices, id: \.self) { days in
                    let isOn = settings.calendarAlertOffsetsDays.contains(days)
                    Button(offsetTitle(days)) { offsetBinding(days).wrappedValue.toggle() }
                        .buttonStyle(PrefChipStyle(isOn: isOn))
                        .dsFocusRing(Capsule())
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Alert me"))
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
    }

    private func offsetTitle(_ days: Int) -> String {
        switch days {
        case 0: "On the day"
        case 1: "1 day"
        case 7: "1 week"
        default: "\(days) days"
        }
    }

    private func offsetBinding(_ days: Int) -> Binding<Bool> {
        Binding(
            get: { settings.calendarAlertOffsetsDays.contains(days) },
            set: { isOn in
                var offsets = settings.calendarAlertOffsetsDays
                if isOn {
                    guard !offsets.contains(days) else { return }
                    offsets.append(days)
                } else {
                    offsets.removeAll { $0 == days }
                }
                settings.calendarAlertOffsetsDays = offsets
            }
        )
    }

    // MARK: - Re-sync

    private var resyncRow: some View {
        PrefRow("Syncing", isResyncing ? "Syncing calendar events" : "\(lastSyncDescription) Re-sync if your calendar doesn’t match.") {
            if isResyncing {
                ProgressView().controlSize(.small)
            } else {
                Button("Re-sync") { resync() }
                    .prefButton()
                    .disabled(model.calendarService == nil || !settings.calendarSyncEnabled || isRemovingCalendarReminders)
            }
        }
    }

    /// Read from the document rather than remembered here, so it survives the settings
    /// window being closed — which is what a user checking "did that work?" tomorrow
    /// would otherwise find blank.
    private var lastSyncDescription: String {
        guard let lastSync = model.lastCalendarSyncAt else {
            return "Not synced yet."
        }
        let calendar = model.calendar
        let when = calendar.isDateInToday(lastSync)
            ? lastSync.formatted(date: .omitted, time: .shortened)
            : lastSync.formatted(date: .abbreviated, time: .shortened)
        return "Last sync: \(when)."
    }

    private func resync() {
        guard let sync = model.calendarService else { return }
        let document = model.document
        isResyncing = true
        model.recordCalendarSyncError(nil)
        calendarActionMessage = "Syncing calendar events"
        Task {
            defer { isResyncing = false }
            do {
                try await sync.syncNow(document: document)
                calendarActionMessage = nil
            } catch {
                calendarActionMessage = nil
                model.recordCalendarSyncError(error.localizedDescription)
            }
        }
    }

    private func removeCalendarReminders() {
        isRemovingCalendarReminders = true
        calendarActionMessage = "Removing calendar reminders"
        model.recordCalendarSyncError(nil)
        Task {
            defer { isRemovingCalendarReminders = false }
            do {
                try await model.removeCalendarReminders()
                calendarActionMessage = "Calendar reminders removed. Calendar sync is off."
            } catch {
                calendarActionMessage = nil
                model.recordCalendarSyncError(error.localizedDescription)
            }
        }
    }

    // MARK: - System state

    private func refreshCalendar() {
        calendarStatus = CalendarSync.authorizationStatus
        loadCalendars()
    }

    private func requestCalendarAccess() {
        isRequestingCalendar = true
        Task {
            _ = await CalendarSync.requestAccess()
            isRequestingCalendar = false
            refreshCalendar()
            // A first grant with nothing chosen should not leave the picker on "None":
            // the default calendar is the one the user already writes to.
            if settings.calendarIdentifier == nil {
                settings.calendarIdentifier = calendars.first?.id
            }
        }
    }

    /// Only enumerated once access is granted — asking an unauthorised store for its
    /// calendars answers with an empty list, and an empty picker reads as "you have no
    /// calendars" rather than "Obolo cannot see them".
    ///
    /// `CalendarSync.calendars()` rather than a store in this pane. The sync saves only
    /// the identifier and resolves it in its background store.
    private func loadCalendars() {
        guard hasCalendarAccess else {
            calendars = []
            return
        }
        calendars = CalendarSync.calendars().map(CalendarChoice.init)
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Parts

/// One queued notification, as a value the view can hold.
private struct PendingReminder: Identifiable, Hashable {
    let title: String
    let date: Date

    /// The pair, not the title: two subscriptions can share a name, and a lead and a
    /// due-today reminder for one subscription are two rows.
    var id: String { "\(date.timeIntervalSinceReferenceDate)-\(title)" }

    init(_ pending: (title: String, date: Date)) {
        self.title = pending.title
        self.date = pending.date
    }
}


/// A writable calendar, reduced to the two strings this pane needs — so no `EKCalendar`
/// has to live in view state or cross an actor boundary. The order is
/// `CalendarSync.calendars()`', which puts iCloud first.
private struct CalendarChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String

    init(_ calendar: EKCalendar) {
        self.id = calendar.calendarIdentifier
        self.title = calendar.title
        self.sourceTitle = calendar.source?.title ?? ""
    }

    var menuTitle: String {
        sourceTitle.isEmpty ? title : "\(title) · \(sourceTitle)"
    }
}

/// A permission status line, shown only while it needs the user: a dot, the row's
/// title and sentence, and the one button that changes it.
private struct StatusRow: View {
    let tint: Color
    let title: String
    let description: String
    let actionTitle: String
    var action: () -> Void
    var isBusy: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                    // Baseline-aligned dots sit on the line rather than under it.
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityHidden(true)
                PrefRowLabel(title: title, description: description)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(actionTitle, action: action)
                    .prefButton()
            }
        }
        .prefRowPadding()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Preview

#Preview("Reminders") {
    RemindersPane(settings: .preview(), model: .handoffPreview())
        .frame(width: PrefMetrics.width, height: 560)
}
