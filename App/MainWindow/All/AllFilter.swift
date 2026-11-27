import Foundation
import OboloCore

/// The All screen's filter pills: Active, Due soon, Inactive.
///
/// They narrow the All section only. The other list sections (the 30-day Upcoming list,
/// Cancelled) are still reached from the View menu; while one of those is on
/// screen the pills show it instead. A category is no longer a section in the window but
/// `AllScope`'s filter; Needs attention is Home's ⚠ list.
///
/// Active includes billing subscriptions. Due soon uses the same seven-day window
/// as the highlighted renewal date. Inactive includes non-billing subscriptions.
enum AllFilter: String, CaseIterable, Identifiable, Hashable {
    case active, dueSoon, inactive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "Active"
        case .dueSoon: "Due soon"
        case .inactive: "Inactive"
        }
    }

    /// The days ahead that count as due soon: today through a week from today.
    static let dueSoonDays = DateFormatting.relativeWindowDays

    func matches(_ row: SubscriptionSummary) -> Bool {
        switch self {
        case .active:
            return row.status.isBilling
        case .dueSoon:
            guard row.status.isBilling, let days = row.daysUntil else { return false }
            return (0...Self.dueSoonDays).contains(days)
        case .inactive:
            // Cancelled (a paused one left in memory counts with them).
            return !row.status.isBilling
        }
    }
}

/// Everything that narrows the All screen: the pill, and on top of it a category.
///
/// The category narrows the selected list and its footer totals. Search spans all categories
/// and statuses. The category selection lasts until the window closes.
struct AllScope: Equatable {
    var pill: AllFilter = .active
    var category: OboloCore.Category.ID?

    /// Whether anything besides the pill narrows the list.
    var isNarrowed: Bool { category != nil }
}

/// Something about a subscription to fix: Home's ⚠ list.
///
/// An active or trial subscription needs attention if its renewal date or exchange rate is missing.
/// A price marked as an estimate is valid.
enum AttentionIssue: Equatable {
    case noDate
    case missingRate(currency: String)

    var reason: String {
        switch self {
        case .noDate: "No renewal date"
        case .missingRate(let currency): "No \(currency) exchange rate"
        }
    }

    var fix: String {
        switch self {
        case .noDate: "Set date"
        case .missingRate: "Settings"
        }
    }
}

extension SubscriptionSummary {
    /// What needs fixing, if anything.
    var issue: AttentionIssue? {
        guard status.isBilling else { return nil }
        switch attention {
        case .noDate: return .noDate
        case .missingRate: return .missingRate(currency: subscription.currency)
        default: return nil
        }
    }
}

extension AppModel {
    /// The rows the All screen shows: the section's rows, narrowed by the pill and the
    /// category when the section is All itself.
    func allRows(scope: AllScope) -> [SubscriptionSummary] {
        let rows = self.rows
        guard section == .all else { return rows }
        let category = scope.category.flatMap { id in document.categories.contains { $0.id == id } ? id : nil }
        return rows.filter { row in
            scope.pill.matches(row) && (category == nil || row.subscription.categoryID == category)
        }
    }

    /// Every subscription with something to fix, by name.
    var issueRows: [SubscriptionSummary] {
        ledger.summaries
            .filter { $0.issue != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// How many subscriptions need fixing: the ⚠ count in Home's bottom bar.
    var fixableCount: Int { ledger.summaries.count { $0.issue != nil } }

    /// The active (billing) subscriptions in a category, for the dropdown's counts.
    func activeCount(in category: OboloCore.Category.ID) -> Int {
        ledger.summaries.count { $0.status.isBilling && $0.subscription.categoryID == category }
    }

    /// A category's name, or nil when it is gone.
    func categoryName(_ id: OboloCore.Category.ID?) -> String? {
        guard let id else { return nil }
        return document.categories.first { $0.id == id }?.name
    }
}
