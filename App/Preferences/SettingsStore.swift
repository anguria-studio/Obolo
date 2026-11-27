import Foundation
import Observation
import ServiceManagement
import struct SwiftUI.Binding
import OboloCore

/// The preferences panes' half of `Settings`.
///
/// Preferences live in the store document, so a backup includes settings such as the reminder time.
/// Each pane binds to individual preferences such as `$settings.baseCurrency`. Changes pass
/// through `onChange` to `AppModel` for saving. The login item also needs to reflect its
/// registration with macOS.
@MainActor
@Observable
final class SettingsStore {

    // MARK: Defaults

    /// The choices the panes offer. The *values* default in `Settings`;
    /// these are the ranges and lists the controls are drawn from, in one place so two
    /// panes cannot disagree about them.
    enum Defaults {
        /// The calendar alert offsets the Reminders pane can toggle.
        static let calendarAlertChoices = [0, 1, 2, 3, 7]
    }

    // MARK: State

    /// The current settings. Assigning any property below assigns this, which fires
    /// `onChange` exactly once.
    private(set) var settings: Settings

    /// Where a change goes. `AppModel` sets this to `updateSettings`; a preview leaves
    /// it alone and the store becomes a scratchpad.
    var onChange: (Settings) -> Void = { _ in }

    /// Previews and tests drive the store without touching the user's login items.
    @ObservationIgnored private let managesLoginItem: Bool
    @ObservationIgnored private var isSyncingLoginItem = false
    /// Whether this launch has already put the switch and the system login item in step.
    @ObservationIgnored private var hasReconciledLoginItem = false

    /// Set when the switch and the system do not agree, and says which way round it is.
    /// The General pane prints the message; nothing else reads it.
    ///
    /// Not persisted. It describes the state of this Mac right now, and the answer is
    /// asked for again on every launch.
    private(set) var loginItemAttention: LoginItemAttention?
    /// True while `apply(_:)` is writing values that came *from* the document, so the
    /// change does not bounce straight back to it.
    @ObservationIgnored private var isApplyingDocument = false

    init(_ settings: Settings = Settings(), managesLoginItem: Bool = true) {
        self.settings = settings
        self.managesLoginItem = managesLoginItem
    }

    // MARK: Writing

    /// The single mutation point. Every property below funnels through here.
    private func write(_ change: (inout Settings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }

        let loginChanged = updated.launchAtLogin != settings.launchAtLogin
        settings = updated
        if loginChanged { syncLoginItem() }
        guard !isApplyingDocument else { return }
        onChange(settings)
    }

    /// Accepts settings that came from the document — a load, a restore, a first-run
    /// completion. Does not call `onChange`: the document is already the source.
    ///
    /// The reconcile does **not** hang off "did anything change". A brand new install
    /// loads a document whose settings are exactly the defaults, so the equality check
    /// that used to guard this whole method returned early and the login item was never
    /// registered at all — the switch said "Open at login" and nothing opened. So the
    /// values are assigned only when they differ, and the reconcile is decided
    /// separately: once per launch, and again the moment first run completes, which is
    /// when the preference the user was shown becomes a preference they have accepted.
    func apply(_ newValue: Settings) {
        let firstRunJustCompleted = newValue.hasCompletedFirstRun && !settings.hasCompletedFirstRun
        if newValue != settings {
            isApplyingDocument = true
            settings = newValue
            isApplyingDocument = false
        }
        guard !hasReconciledLoginItem || firstRunJustCompleted else { return }
        hasReconciledLoginItem = true
        reconcileLoginItem()
    }

    /// A binding to any field, for the panes that need one this file does not name.
    func binding<Value>(_ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(
            get: { [weak self] in (self?.settings ?? Settings())[keyPath: keyPath] },
            set: { [weak self] newValue in self?.write { $0[keyPath: keyPath] = newValue } }
        )
    }

    // MARK: Money

    var baseCurrency: String {
        get { settings.baseCurrency }
        set { write { $0.baseCurrency = newValue } }
    }

    // MARK: Startup and chrome

    /// Mirrors the login item rather than owning it — see `syncLoginItem`.
    var launchAtLogin: Bool {
        get { settings.launchAtLogin }
        set { write { $0.launchAtLogin = newValue } }
    }

    var showInMenuBar: Bool {
        get { settings.showInMenuBar }
        set { write { $0.showInMenuBar = newValue } }
    }

    var menuBarLabel: MenuBarLabelStyle {
        get { settings.menuBarLabel }
        set { write { $0.menuBarLabel = newValue } }
    }

    /// Which of Home's spend drawings is on show. Written from the chart's own header
    /// rather than from a pane — it is a way of reading the chart, not a preference
    /// anyone would go looking for in Settings.
    var spendView: SpendView {
        get { settings.spendView }
        set { write { $0.spendView = newValue } }
    }

    // MARK: Appearance

    /// Dark, Light or Dynamic, for every window (see `AppearanceSetting.nsAppearanceName`).
    var appearance: AppearanceSetting {
        get { settings.appearance }
        set { write { $0.appearance = newValue } }
    }

    // MARK: Logos

    var useGoogleFaviconFallback: Bool {
        get { settings.useGoogleFaviconFallback }
        set { write { $0.useGoogleFaviconFallback = newValue } }
    }

    // MARK: Reminders

    var defaultReminderLeadDays: Int {
        get { settings.defaultReminderLeadDays }
        set { write { $0.defaultReminderLeadDays = max(0, newValue) } }
    }

    /// The notification time as a `Date`, which is what `DatePicker(.hourAndMinute)`
    /// binds to. Only the hour and minute survive the round trip; the day is whatever
    /// the payment date turns out to be.
    var notificationTimeDate: Date {
        get {
            Calendar.current.date(
                bySettingHour: settings.notificationTime.hour ?? 9,
                minute: settings.notificationTime.minute ?? 0,
                second: 0,
                of: Date()
            ) ?? Date()
        }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            write { $0.notificationTime = DateComponents(hour: parts.hour, minute: parts.minute) }
        }
    }

    var notificationsEnabled: Bool {
        get { settings.notificationsEnabled }
        set { write { $0.notificationsEnabled = newValue } }
    }

    // MARK: Calendar

    var calendarSyncEnabled: Bool {
        get { settings.calendarSyncEnabled }
        set { write { $0.calendarSyncEnabled = newValue } }
    }

    var calendarIdentifier: String? {
        get { settings.calendarIdentifier }
        set { write { $0.calendarIdentifier = newValue } }
    }

    var calendarAlertOffsetsDays: [Int] {
        get { settings.calendarAlertOffsetsDays }
        set { write { $0.calendarAlertOffsetsDays = newValue.sorted() } }
    }

    // MARK: View state

    var hasCompletedFirstRun: Bool { settings.hasCompletedFirstRun }

    // MARK: - Login item

    /// Applies the switch to the real login item, and flips the switch back only when
    /// macOS actually refused.
    ///
    /// The distinction is the whole of it. `register()` throwing is a refusal: the app is
    /// unsigned, or the service is blocked, and there is no login item. Registering into
    /// `.requiresApproval` is **not** a refusal — the item exists and is waiting for the
    /// user to allow it in System Settings, and turning the switch off underneath them
    /// both loses the preference they just set and hides the one thing they need to do.
    /// Reading the status straight back is not proof of anything either: it settles a
    /// moment after the call. So only a thrown error moves the switch, and everything
    /// short of "enabled" raises the caption instead.
    ///
    /// A refusal in the other direction gets the same treatment, and used not to. Turning
    /// the switch off returned before any of this ran, so a refused `unregister()` left
    /// the switch drawn as off and the caption cleared while macOS went on opening
    /// Obolo at login every morning — the one state the switch is there to tell the
    /// truth about.
    private func syncLoginItem() {
        guard managesLoginItem, !isSyncingLoginItem else { return }
        let wanted = settings.launchAtLogin
        let outcome = LoginItem.setEnabled(wanted)

        guard wanted else {
            // A refusal is only worth acting on if the login item is really still there.
            // This status is settled, unlike the one read after a call that worked:
            // `unregister()` threw, so nothing changed and this is the state macOS was
            // already in. `.requiresApproval` is not "still opening at login" — the item
            // is on record but macOS is not acting on it — so only `.enabled` counts.
            guard outcome == .refused, LoginItem.status == .enabled else {
                loginItemAttention = nil
                return
            }
            loginItemAttention = .notStopping
            restoreSwitch(to: true)
            return
        }

        loginItemAttention = outcome == .done ? nil : .notOpening
        guard outcome == .refused else { return }
        restoreSwitch(to: false)
    }

    /// Puts the switch back where the system is, without the write bouncing round to
    /// `syncLoginItem` again.
    private func restoreSwitch(to value: Bool) {
        isSyncingLoginItem = true
        settings.launchAtLogin = value
        isSyncingLoginItem = false
        if !isApplyingDocument { onChange(settings) }
    }

    /// Called when a document arrives. Which side wins depends on whether this install
    /// has ever run: before first run the document's default is applied to the system,
    /// exactly once. After that the *system* is the truth, so a login item the user
    /// removed in System Settings turns this switch off rather than being silently put
    /// back — and the change is written to the document so the two agree.
    private func reconcileLoginItem() {
        guard managesLoginItem else { return }

        guard settings.hasCompletedFirstRun else {
            syncLoginItem()
            return
        }

        // Waiting on the user in System Settings is not the user having said no. The
        // preference stands and the pane says what is missing.
        guard LoginItem.status != .requiresApproval else {
            loginItemAttention = settings.launchAtLogin ? .notOpening : nil
            return
        }

        let system = LoginItem.status == .enabled
        loginItemAttention = nil
        if system != settings.launchAtLogin {
            settings.launchAtLogin = system
            onChange(settings)
        } else if system {
            // Re-register on every launch, not just the first: the record points at
            // whichever copy registered it, and someone who ran a development build and
            // later installed the app proper wants login opening the installed copy,
            // which is the one they are running now.
            syncLoginItem()
        }
    }
}

// MARK: - Login item

/// What the General pane says when the switch and the system login item disagree.
///
/// Two states, not one flag, because the two sentences send the user to System Settings
/// for opposite reasons: to allow something that is not happening, or to remove something
/// that is.
enum LoginItemAttention: Equatable {

    /// The switch is on and macOS is not opening Obolo at login.
    case notOpening
    /// The switch was turned off and macOS kept the login item.
    case notStopping

    var message: String {
        switch self {
        case .notOpening:
            "macOS did not allow Obolo to open at login. Check Login Items in System Settings."
        case .notStopping:
            "macOS did not allow Obolo to stop opening at login. Check Login Items in System Settings."
        }
    }
}

/// The `Open at login` switch's other half.
enum LoginItem {

    /// What `setEnabled` achieved.
    enum Outcome {
        /// The request was carried out: macOS is opening Obolo at login, or has
        /// stopped doing so.
        case done
        /// The item is registered and waiting for the user to allow it in System
        /// Settings. A success, not a failure.
        case requiresApproval
        /// macOS refused. The only outcome that may turn the preference off.
        case refused
    }

    @MainActor
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Registers or unregisters, and reports what happened.
    ///
    /// "Already in the state you asked for" is not a refusal. `reconcileLoginItem` calls
    /// this on every launch of an app that is opening at login exactly as it should, and
    /// `register()` on a service macOS already has on record throws
    /// `kSMErrorAlreadyRegistered` — which the old code read as "macOS said no", raised
    /// the warning caption, and on the next write turned the preference off underneath a
    /// login item that was working. So the already-registered call is not made at all
    /// when the status says so, and the error, if it arrives anyway, means done.
    @MainActor
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Outcome {
        guard enabled else {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                // The mirror of the above: unregistering something that is not registered
                // has achieved what was asked of it.
                guard (error as NSError).code == kSMErrorJobNotFound else { return .refused }
            }
            return .done
        }

        // Asking for a registration that already exists is the false refusal this guard
        // exists to prevent. Reading the status *before* the call is sound in a way that
        // reading it after is not: this is the state macOS has settled on since the last
        // launch, not a value that is still catching up with a call microseconds old.
        guard status != .enabled else { return .done }

        do {
            try SMAppService.mainApp.register()
        } catch {
            guard (error as NSError).code == kSMErrorAlreadyRegistered else { return .refused }
            return .done
        }

        switch status {
        case .enabled:          return .done
        case .requiresApproval: return .requiresApproval
        default:
            // Registered without complaint, but the status has not caught up yet — it is
            // read back within microseconds of the call. Trust the call, not the poll.
            return .done
        }
    }
}

// Not under `#if DEBUG`: the `#Preview` bodies that call this still compile in
// Release, so the helper must exist there too.
extension SettingsStore {
    /// A throwaway store for `#Preview`, which never touches the real login item.
    static func preview(_ configure: (inout Settings) -> Void = { _ in }) -> SettingsStore {
        var settings = Settings()
        configure(&settings)
        return SettingsStore(settings, managesLoginItem: false)
    }
}
