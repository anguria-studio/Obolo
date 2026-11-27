import Foundation

/// What the menu bar item says next to the glyph: nothing, the monthly total ("129 €"),
/// or the next payment ("Spotify · today").
///
/// Declaration order is the order the picker offers them in. The raw values are what
/// the document stores, so this list can be reordered or renamed without touching a
/// saved preference; a stored value that is none of these reads as `iconOnly`.
public enum MenuBarLabelStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case iconOnly
    case monthlyTotal
    /// Stored as `nextRenewal`; shown as "Next payment".
    case nextRenewal

    public var displayName: String {
        switch self {
        case .iconOnly: "Icon only"
        case .monthlyTotal: "Monthly total"
        case .nextRenewal: "Next payment"
        }
    }
}

/// Which question the Spend card answers.
///
/// Two readings of the same money: where it goes, and when it leaves. They share one
/// card because they are the same figure seen from two sides, and because a dashboard
/// with a chart for every question is a report, not a dashboard.
public enum SpendView: String, Codable, Hashable, Sendable, CaseIterable {
    case category
    case subscription
    case month

    public var displayName: String {
        switch self {
        case .category: "By category"
        case .subscription: "By subscription"
        case .month: "By month"
        }
    }
}

/// How the list is ordered. Persisted, so the user's choice survives relaunch.
public enum SortOrder: String, Codable, Hashable, Sendable, CaseIterable {
    case nextPayment
    case name
    case amount
    case monthly
    case category

    public var displayName: String {
        switch self {
        case .nextPayment: "Next payment"
        case .name: "Name"
        case .amount: "Amount"
        case .monthly: "Monthly"
        case .category: "Category"
        }
    }

    /// The direction this order reads in when nobody has asked for one: the answer to
    /// "what does a first click on this header mean?".
    ///
    /// Dates, names and categories run forwards, because the soonest payment, the letter
    /// A and the first category in the list are what the user is looking for. Money runs
    /// backwards, because the question behind a click on Amount is "what costs me the
    /// most". A click on the same header again reverses whichever of the two it is.
    public var naturalAscending: Bool {
        switch self {
        case .nextPayment, .name, .category: true
        case .amount, .monthly: false
        }
    }
}

/// Every preference, stored inside the document rather than in `UserDefaults`, so that
/// "Back up" and "Restore" in the Data pane capture the whole app state in one file.
/// The theme for all windows. Dynamic follows the macOS appearance.
public enum AppearanceSetting: String, Codable, CaseIterable, Sendable {
    case dark
    case light
    case auto

    public var displayName: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .auto: "Dynamic"
        }
    }
}

public struct Settings: Codable, Hashable, Sendable {
    public var baseCurrency: String
    /// Payment highlighting uses a fixed seven-day window.
    public static let paymentHighlightWindowDays = 7

    public var defaultReminderLeadDays: Int
    /// Hour and minute only; the day comes from the payment date.
    public var notificationTime: DateComponents
    public var launchAtLogin: Bool
    public var showInMenuBar: Bool
    /// What the status item says beside its glyph. Defaults to `.iconOnly`: the menu
    /// bar is shared with every other app on the Mac, and a glyph that stays one width
    /// is a better neighbour than one that grows a subscription's name. Whoever wants
    /// the number can ask for it.
    public var menuBarLabel: MenuBarLabelStyle
    public var notificationsEnabled: Bool
    public var calendarSyncEnabled: Bool
    public var calendarIdentifier: String?
    public var calendarAlertOffsetsDays: [Int]
    public var sortOrder: SortOrder
    /// Which way `sortOrder` runs, or `nil` for its own natural direction.
    ///
    /// Optional rather than a plain `Bool` so that a document written before the headers
    /// could be reversed still opens in exactly the order it was saved in: "not set" is
    /// the order's own direction, which is what those documents were sorted by.
    public var sortAscending: Bool?
    public var hasCompletedFirstRun: Bool
    /// Which of the two drawings the Spend card shows.
    public var spendView: SpendView
    /// Whether a logo fetch may fall back to Google's icon service when the site itself
    /// serves nothing usable.
    ///
    /// On by default because without it roughly a third of a typical list stays on
    /// letters — a fair number of sites refuse the request that would find their own
    /// icon. It is a switch rather than a fact because it is the one thing in this app
    /// that tells a third party anything: the domain being looked up, and only when the
    /// user asked for a fetch.
    public var useGoogleFaviconFallback: Bool

    /// Whether Obolo may fetch the ECB's daily reference rates for the currencies
    /// this document actually uses.
    ///
    /// On by default because the alternative is a total that is quietly wrong — a rate
    /// typed in once and never touched again drifts a few per cent a year, and a
    /// subscription with no rate at all is silently missing from the monthly figure.
    /// Only the currency codes leave the machine, once a day, and a rate the user typed
    /// is never overwritten.
    public var autoUpdateRates: Bool

    /// Dark by default, with Light and Dynamic appearances available for every window.
    public var appearance: AppearanceSetting

    public init(
        baseCurrency: String = "EUR",
        defaultReminderLeadDays: Int = 2,
        notificationTime: DateComponents = Settings.defaultNotificationTime,
        launchAtLogin: Bool = true,
        showInMenuBar: Bool = true,
        menuBarLabel: MenuBarLabelStyle = .iconOnly,
        notificationsEnabled: Bool = true,
        calendarSyncEnabled: Bool = false,
        calendarIdentifier: String? = nil,
        calendarAlertOffsetsDays: [Int] = [2],
        sortOrder: SortOrder = .nextPayment,
        sortAscending: Bool? = nil,
        hasCompletedFirstRun: Bool = false,
        spendView: SpendView = .category,
        useGoogleFaviconFallback: Bool = true,
        autoUpdateRates: Bool = true,
        appearance: AppearanceSetting = .dark
    ) {
        self.baseCurrency = Subscription.normalizedCurrency(baseCurrency)
        self.defaultReminderLeadDays = defaultReminderLeadDays
        self.notificationTime = notificationTime
        self.launchAtLogin = launchAtLogin
        self.showInMenuBar = showInMenuBar
        self.menuBarLabel = menuBarLabel
        self.notificationsEnabled = notificationsEnabled
        self.calendarSyncEnabled = calendarSyncEnabled
        self.calendarIdentifier = calendarIdentifier
        self.calendarAlertOffsetsDays = calendarAlertOffsetsDays
        self.sortOrder = sortOrder
        self.sortAscending = sortAscending
        self.hasCompletedFirstRun = hasCompletedFirstRun
        self.spendView = spendView
        self.useGoogleFaviconFallback = useGoogleFaviconFallback
        self.autoUpdateRates = autoUpdateRates
        self.appearance = appearance
    }

    /// 09:00.
    public static let defaultNotificationTime = DateComponents(hour: 9, minute: 0)

    /// The lead times the Reminder picker offers, on top of "Default".
    public static let reminderLeadChoices = [1, 2, 3, 7, 14]

    /// A reminder lead time in words: "on the day", "1 day before", "1 week before",
    /// "3 days before".
    public static func reminderLeadText(days: Int) -> String {
        switch days {
        case ..<1: "on the day"
        case 1: "1 day before"
        case 7: "1 week before"
        default: "\(days) days before"
        }
    }

    /// The lead in days of the reminder that comes before this subscription's payments,
    /// or `nil` when no reminder comes: its own reminder is off, or it no longer bills.
    ///
    /// A cancelled subscription has no next payment, so the Mac notifications skip it and
    /// the calendar sync removes its event and that event's alerts, also while its access
    /// runs to an end date. Its stored lead stays, for when it is reactivated.
    public func reminderLeadDays(for subscription: Subscription) -> Int? {
        guard subscription.remindersEnabled, subscription.status.isBilling else { return nil }
        return subscription.reminderLeadDays ?? defaultReminderLeadDays
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case baseCurrency, defaultReminderLeadDays, notificationTime
        case launchAtLogin, showInMenuBar, menuBarLabel, notificationsEnabled
        case calendarSyncEnabled, calendarIdentifier, calendarAlertOffsetsDays
        case sortOrder, sortAscending, hasCompletedFirstRun
        case spendView, useGoogleFaviconFallback, autoUpdateRates
        case appearance
    }

    /// Key by key with defaults, for the same reason `Subscription` is: this is the
    /// part of the document most likely to gain fields, and a missing one must read as
    /// "not set yet", not as a corrupt file. Keys this type no longer has (older
    /// documents carry `showDockIcon`, `onlyActive`, `lastCalendarSyncAt`,
    /// `showInspector`, `chartStyle`, `categoryPeriod` and `dueSoonWindowDays`) are
    /// ignored. Payment highlighting uses `paymentHighlightWindowDays`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings()
        baseCurrency = Subscription.normalizedCurrency(
            try container.decodeIfPresent(String.self, forKey: .baseCurrency) ?? fallback.baseCurrency
        )
        defaultReminderLeadDays = try container.decodeIfPresent(Int.self, forKey: .defaultReminderLeadDays) ?? fallback.defaultReminderLeadDays
        notificationTime = try container.decodeIfPresent(DateComponents.self, forKey: .notificationTime) ?? fallback.notificationTime
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
        showInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? fallback.showInMenuBar
        // An older or unknown style reads as Icon only rather than failing the settings.
        menuBarLabel = (try? container.decodeIfPresent(String.self, forKey: .menuBarLabel))
            .flatMap { $0 }
            .map { MenuBarLabelStyle(rawValue: $0) ?? .iconOnly }
            ?? fallback.menuBarLabel
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? fallback.notificationsEnabled
        calendarSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarSyncEnabled) ?? fallback.calendarSyncEnabled
        calendarIdentifier = try container.decodeIfPresent(String.self, forKey: .calendarIdentifier)
        calendarAlertOffsetsDays = try container.decodeIfPresent([Int].self, forKey: .calendarAlertOffsetsDays) ?? fallback.calendarAlertOffsetsDays
        sortOrder = try container.decodeIfPresent(SortOrder.self, forKey: .sortOrder) ?? fallback.sortOrder
        // No `??` here: absent is a value of its own, and it means "the natural direction".
        sortAscending = try container.decodeIfPresent(Bool.self, forKey: .sortAscending)
        hasCompletedFirstRun = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedFirstRun) ?? fallback.hasCompletedFirstRun
        spendView = try container.decodeIfPresent(SpendView.self, forKey: .spendView) ?? fallback.spendView
        useGoogleFaviconFallback = try container.decodeIfPresent(Bool.self, forKey: .useGoogleFaviconFallback)
            ?? fallback.useGoogleFaviconFallback
        autoUpdateRates = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateRates)
            ?? fallback.autoUpdateRates
        // Missing and unknown appearance values use the same default as a new document.
        appearance = (try? container.decodeIfPresent(String.self, forKey: .appearance))
            .flatMap(AppearanceSetting.init(rawValue:))
            ?? fallback.appearance
    }
}
