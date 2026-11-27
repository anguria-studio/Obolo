import Foundation

/// How often a subscription charges.
///
/// `CaseIterable` covers the five fixed cadences only — `allCases` cannot enumerate
/// `custom(months:)`, so a picker offers `allCases` plus a "Custom" entry that
/// supplies its own month count. `fixedCases` is the same list under a name that says
/// what it is.
public enum BillingCycle: Hashable, Sendable, CaseIterable {
    case weekly
    case monthly
    case quarterly
    case yearly
    case everyTwoYears
    case custom(months: Int)

    /// The five cadences a picker can list without asking a follow-up question.
    public static let fixedCases: [BillingCycle] = [.weekly, .monthly, .quarterly, .yearly, .everyTwoYears]

    public static var allCases: [BillingCycle] { fixedCases }

    /// Length of one cycle in months. `nil` for `weekly`, which is the one cadence that
    /// does not divide the calendar — every other computation branches on that `nil`
    /// rather than pretending a week is 0.23 months.
    public var months: Int? {
        switch self {
        case .weekly: nil
        case .monthly: 1
        case .quarterly: 3
        case .yearly: 12
        case .everyTwoYears: 24
        case .custom(let months): max(1, months)
        }
    }

    /// Charges per year: 52 · 12 · 4 · 1 · 0.5 · 12/n.
    public var paymentsPerYear: Double {
        switch self {
        case .weekly: 52
        case .monthly: 12
        case .quarterly: 4
        case .yearly: 1
        case .everyTwoYears: 0.5
        case .custom(let months): 12.0 / Double(max(1, months))
        }
    }

    public var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .yearly: "Yearly"
        case .everyTwoYears: "Every 2 years"
        case .custom(let months):
            months == 1 ? "Monthly" : "Every \(max(1, months)) months"
        }
    }

    /// The suffix that follows an amount: "€14.99 **/ month**".
    public var perUnitSuffix: String {
        switch self {
        case .weekly: "/ week"
        case .monthly: "/ month"
        case .quarterly: "/ quarter"
        case .yearly: "/ year"
        case .everyTwoYears: "/ 2 years"
        case .custom(let months):
            months == 1 ? "/ month" : "/ \(max(1, months)) months"
        }
    }

    /// The short suffix for the detail header's price, where the amounts and units sit
    /// in two aligned columns of mono text: "€14.99 **/ mo**", "€57.99 **/ yr**".
    /// Only that block uses it; everywhere else keeps `perUnitSuffix`.
    public var shortPerUnitSuffix: String {
        switch self {
        case .weekly: "/ wk"
        case .monthly: "/ mo"
        case .quarterly: "/ 3 mo"
        case .yearly: "/ yr"
        case .everyTwoYears: "/ 2 yr"
        case .custom(let months):
            months == 1 ? "/ mo" : "/ \(max(1, months)) mo"
        }
    }

    /// The unit of `compactPeriod`.
    public enum CompactUnit: Hashable, Sendable {
        case week, month, year

        /// "wk", "mo", "yr".
        public var abbreviation: String {
            switch self {
            case .week: "wk"
            case .month: "mo"
            case .year: "yr"
            }
        }
    }

    /// One cycle as a count of one unit: weekly is 1 week, quarterly 3 months, every two
    /// years 2 years. A month count that divides by 12 is whole years, any other is
    /// months, so a custom 24-month cycle is 2 years wherever it shows.
    public var compactPeriod: (count: Int, unit: CompactUnit) {
        guard let months else { return (1, .week) }
        return months % 12 == 0 ? (months / 12, .year) : (months, .month)
    }

    /// The short suffix that follows an amount where space is tight: "/wk", "/mo",
    /// "/3mo", "/yr", "/2y". A count of one is left out; a count of years takes "y".
    public var compactSuffix: String {
        let (count, unit) = compactPeriod
        guard count != 1 else { return "/\(unit.abbreviation)" }
        return "/\(count)\(unit == .year ? "y" : unit.abbreviation)"
    }

    /// Flat string form shared by JSON and CSV: `weekly` · `monthly` · `quarterly` ·
    /// `yearly` · `every2Years` · `custom:3`.
    public var encoded: String {
        switch self {
        case .weekly: "weekly"
        case .monthly: "monthly"
        case .quarterly: "quarterly"
        case .yearly: "yearly"
        case .everyTwoYears: "every2Years"
        case .custom(let months): "custom:\(max(1, months))"
        }
    }

    /// Parses `encoded` plus everything a human or a spreadsheet plausibly writes:
    /// "Every 2 years", "every 3 months", "3 months", "annual", "biweekly"…
    ///
    /// Returns `nil` rather than guessing at monthly — an unreadable cadence is a
    /// row-level import error, and silently filing a yearly €80 charge as €80 a month
    /// would be a 12× lie in the totals.
    public init?(parsing text: String) {
        let normalised = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
        guard !normalised.isEmpty else { return nil }

        if let value = normalised.dropPrefixIfPresent("custom:"), let months = Int(value.trimmingCharacters(in: .whitespaces)) {
            self = BillingCycle.canonical(months: months)
            return
        }

        switch normalised {
        case "weekly", "week", "every week", "1 week", "every 1 week":
            self = .weekly
            return
        case "monthly", "month", "every month", "1 month", "every 1 month", "per month":
            self = .monthly
            return
        case "quarterly", "quarter", "every quarter", "3 months", "every 3 months":
            self = .quarterly
            return
        case "yearly", "year", "annual", "annually", "every year", "12 months", "every 12 months", "per year":
            self = .yearly
            return
        case "every2years", "every 2 years", "2 years", "biennial", "biennially", "24 months", "every 24 months":
            self = .everyTwoYears
            return
        default:
            break
        }

        // "every 4 months" / "4 months" / "every 4 month"
        let words = normalised.split(separator: " ").map(String.init)
        if let months = words.compactMap({ Int($0) }).first,
           normalised.contains("month") {
            self = BillingCycle.canonical(months: months)
            return
        }
        return nil
    }

    /// Folds a month count onto a named cadence when one exists, so `custom(months: 12)`
    /// never coexists with `.yearly` and confuses `Equatable`, pickers and sorting.
    public static func canonical(months: Int) -> BillingCycle {
        switch max(1, months) {
        case 1: .monthly
        case 3: .quarterly
        case 12: .yearly
        case 24: .everyTwoYears
        case let other: .custom(months: other)
        }
    }
}

extension BillingCycle: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let cycle = BillingCycle(parsing: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognised billing cycle \(raw.debugDescription)")
            )
        }
        self = cycle
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoded)
    }
}
