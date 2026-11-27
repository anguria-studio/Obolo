import Foundation

/// The one place totals are computed.
///
/// A `Ledger` is a **snapshot taken at a `today`**. It holds no clock: every date in it
/// was resolved against the `today` handed to `init`, and nothing inside ever moves. The
/// app is expected to build a fresh one whenever the document changes and whenever the
/// day rolls over (a midnight timer plus `NSCalendarDayChangedNotification`) — that is
/// the whole reason "derived values are never stored" is affordable.
///
/// Two arithmetic decisions are visible from the outside and both come from the
/// published reconciliation:
///
/// - **Per-item monthly figures are rounded to cents before they are summed.** The
///   design prints the category totals next to the €129.41 hero and expects them to
///   add up. Summing unrounded quotients and rounding at the end does not guarantee
///   that; rounding once per item does.
/// - **`yearlyTotal` is `monthlyTotal × 12`**, which is how the sample gets €1 552.92
///   from €129.41. Summing each item's own yearly figure gives €1 552.89 — correct to
///   the cent, and wrong next to a "YEARLY" tile that sits under a monthly hero the
///   user will multiply in their head.
public struct Ledger: Sendable {

    /// The document this was computed from, unchanged.
    public let document: StoreDocument
    /// The instant every derived value was resolved against.
    public let today: Date
    /// The calendar every date computation used, including its time zone.
    public let calendar: Calendar

    public let summaries: [SubscriptionSummary]
    public let monthlyTotal: Decimal
    public let yearlyTotal: Decimal
    public let activeCount: Int
    public let needsAttention: [SubscriptionSummary]
    public let missingRateCount: Int
    public let categoryTotals: [(category: Category, monthly: Decimal, share: Double)]

    public init(document: StoreDocument, today: Date, calendar: Calendar) {
        self.document = document
        self.today = today
        self.calendar = calendar

        let rates = document.rates
        let categoriesByID = Dictionary(document.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let summaries = document.subscriptions.map { subscription -> SubscriptionSummary in
            Ledger.summarise(
                subscription,
                category: categoriesByID[subscription.categoryID] ?? Category.unknown,
                rates: rates,
                today: today,
                calendar: calendar
            )
        }
        self.summaries = summaries

        let counted = summaries.filter(\.countsInTotals)
        let monthly = counted.reduce(Decimal.zero) { $0 + ($1.monthlyInBase ?? 0) }
        self.monthlyTotal = monthly
        self.yearlyTotal = monthly * 12

        self.activeCount = summaries.count { $0.status.isBilling }

        let window = Settings.paymentHighlightWindowDays

        self.needsAttention = summaries.filter { summary in
            if summary.attention.isFixable { return true }
            // A dated warning counts as attention while the date is near enough to act
            // on and has not gone past: "access ends 5 Sep" is worth a place in the list
            // this week, and worth nothing at all in 2027 about a plan that ended in
            // 2019. Only the fixable states stay listed indefinitely, because they can
            // still be fixed.
            guard let date = summary.attention.date else { return false }
            let days = RenewalSchedule.daysUntil(date, today: today, calendar: calendar)
            return days >= 0 && days <= window
        }

        self.missingRateCount = summaries.count { $0.status.isBilling && $0.monthlyInBase == nil }

        var totalsByCategory: [Category.ID: Decimal] = [:]
        for summary in counted {
            totalsByCategory[summary.category.id, default: 0] += summary.monthlyInBase ?? 0
        }
        self.categoryTotals = totalsByCategory
            .compactMap { id, total -> (category: Category, monthly: Decimal, share: Double)? in
                guard total != 0, let category = categoriesByID[id] else { return nil }
                return (category: category, monthly: total, share: Normalizer.share(total, of: monthly))
            }
            .sorted { left, right in
                left.monthly == right.monthly
                    ? left.category.name.localizedCaseInsensitiveCompare(right.category.name) == .orderedAscending
                    : left.monthly > right.monthly
            }
    }

    // MARK: - One subscription

    static func summarise(
        _ subscription: Subscription,
        category: Category,
        rates: RateTable,
        today: Date,
        calendar: Calendar
    ) -> SubscriptionSummary {
        // What it costs **today**, which is not always `subscription.price`: that field
        // is the latest *known* price, and an announced rise has not started yet. Every
        // "what am I paying" answer below goes through this pair.
        let current = subscription.price(on: today, calendar: calendar)
        let hasRate = rates.hasRate(for: current.currency)
        let isBilling = subscription.status.isBilling

        // Paused and cancelled items have no next payment: a paused plan is not going to
        // charge, and a cancelled one shows its end date instead.
        let nextPayment: Date? = {
            guard isBilling, let anchor = subscription.anchorDate?.startOfDay(in: calendar) else { return nil }
            return RenewalSchedule.nextPayment(
                anchor: anchor, cycle: subscription.cycle, today: today, calendar: calendar
            )
        }()
        let daysUntil = nextPayment.map { RenewalSchedule.daysUntil($0, today: today, calendar: calendar) }

        // The amount that will actually leave the account on `nextPayment` — a rise
        // announced for the first of the month is already in force for a payment on the
        // fifth, and every place that prints an amount beside that date says so.
        let nextCharge = nextPayment.map { date -> PricePoint in
            let charge = subscription.price(on: date, calendar: calendar)
            return PricePoint(price: charge.price, currency: charge.currency)
        }
        let announcedPriceChange = subscription.announcedPriceChange(on: today, calendar: calendar)

        let countsInTotals = isBilling && hasRate
        let monthlyInBase = countsInTotals
            ? Normalizer.monthlyInBase(price: current.price, currency: current.currency, cycle: subscription.cycle, rates: rates)
            : nil
        let yearlyInBase = countsInTotals
            ? Normalizer.yearlyInBase(price: current.price, currency: current.currency, cycle: subscription.cycle, rates: rates)
            : nil
        // "What leaves the account on the next payment", so it follows `nextCharge`
        // where there is one and today's price where there is not.
        let charge = nextCharge.map { (price: $0.price, currency: $0.currency) } ?? current
        let chargeInBase = Normalizer.convert(charge.price, from: charge.currency, using: rates)
            .map { Normalizer.rounded($0) }

        let attention = AttentionEvaluator.evaluate(
            subscription: subscription,
            nextPayment: nextPayment,
            hasRate: hasRate,
            dueSoonWindowDays: Settings.paymentHighlightWindowDays,
            today: today,
            calendar: calendar
        )

        // "Paid so far" is in the subscription's own currency: it is a record of charges
        // that already happened, and converting eighteen months of them at today's rate
        // would be a made-up number.
        //
        // With a price history it is a sum rather than a multiplication: eighteen
        // payments at three different prices are not eighteen times the current one.
        // Without one — every row until somebody records a rise — the multiplication
        // gives the same answer for a fraction of the work.
        // A row that has stopped billing needs the day it stopped before any of this can
        // be answered. Without one, "how much have you paid" has no honest answer at all
        // — inventing a stop date would print months of charges nobody made — so the
        // figure is missing, and the Detail shows `–` for it.
        let paidSoFar: PaidHistory? = {
            guard let anchor = subscription.anchorDate?.startOfDay(in: calendar) else { return nil }
            let paidThrough: Date
            if subscription.status.isBilling {
                paidThrough = today
            } else {
                guard let stopped = subscription.billingStoppedOn?.startOfDay(in: calendar) else { return nil }
                paidThrough = min(today, stopped)
            }
            let count = RenewalSchedule.paymentsMade(
                anchor: anchor, cycle: subscription.cycle, today: paidThrough, calendar: calendar
            )
            guard count > 0 else { return nil }
            guard !subscription.priceChanges.isEmpty else {
                return PaidHistory(
                    count: count,
                    totalsByCurrency: [
                        subscription.currency: Normalizer.rounded(subscription.price * Decimal(count))
                    ]
                )
            }
            var chargedByCurrency: [String: Decimal] = [:]
            for date in RenewalSchedule.occurrences(
                anchor: anchor, cycle: subscription.cycle,
                from: anchor, to: paidThrough, calendar: calendar
            ) {
                let charge = subscription.price(on: date, calendar: calendar)
                chargedByCurrency[charge.currency, default: 0] += charge.price
            }
            return PaidHistory(
                count: count,
                totalsByCurrency: chargedByCurrency.mapValues { Normalizer.rounded($0) }
            )
        }()

        return SubscriptionSummary(
            subscription: subscription,
            category: category,
            price: current.price,
            currency: current.currency,
            nextCharge: nextCharge,
            announcedPriceChange: announcedPriceChange,
            nextPayment: nextPayment,
            daysUntil: daysUntil,
            monthlyInBase: monthlyInBase,
            yearlyInBase: yearlyInBase,
            chargeInBase: chargeInBase,
            countsInTotals: countsInTotals,
            attention: attention,
            paidSoFar: paidSoFar
        )
    }

    // MARK: - Queries

    public func summary(id: Subscription.ID) -> SubscriptionSummary? {
        summaries.first { $0.id == id }
    }

    /// Billing items renewing within `days`, soonest first. The Upcoming section asks
    /// for 30; the menu-bar label asks for 365 and takes the first.
    public func upcoming(within days: Int) -> [SubscriptionSummary] {
        summaries
            .filter { $0.status.isBilling }
            .compactMap { summary -> (SubscriptionSummary, Int)? in
                guard let until = summary.daysUntil, until >= 0, until <= days else { return nil }
                return (summary, until)
            }
            .sorted { left, right in
                left.1 == right.1
                    ? left.0.name.localizedCaseInsensitiveCompare(right.0.name) == .orderedAscending
                    : left.1 < right.1
            }
            .map(\.0)
    }

    // MARK: - Occurrences

    /// Every charge that lands in `[from, to)`, sorted by date and then by name.
    ///
    /// Backwards as well as forwards. The Calendar section shows a past month as what
    /// was *paid* in it, not as an empty grid, and `nextPayment` cannot answer that —
    /// so this walks the whole sequence over the window rather than picking one date
    /// off each subscription.
    ///
    /// An item with no date has nothing to place on a square. Active items can occur
    /// throughout the requested range. Paused and cancelled items can occur only up to
    /// `billingStoppedOn`, which is exclusive: the day billing stopped is the first day
    /// with no charge on it. The anchor remains the floor.
    ///
    /// A row that stopped billing on a day nobody recorded lists nothing. The date is
    /// what separates "this plan charged you until March" from "this plan was cancelled
    /// at some point", and the app is not entitled to guess which: a guess of today
    /// would fill the grid with charges the user never paid, and every one of them would
    /// look like a fact.
    public func occurrences(from: Date, to: Date) -> [RenewalOccurrence] {
        var rows: [(occurrence: RenewalOccurrence, name: String)] = []

        for summary in summaries {
            guard let anchor = summary.subscription.anchorDate?.startOfDay(in: calendar) else { continue }
            let upperBound: Date
            if summary.status.isBilling {
                upperBound = to
            } else {
                guard let stopped = summary.subscription.billingStoppedOn?.startOfDay(in: calendar) else { continue }
                upperBound = min(to, stopped)
            }
            guard from < upperBound else { continue }
            let dates = RenewalSchedule.occurrences(
                anchor: anchor, cycle: summary.cycle, from: from, to: upperBound, calendar: calendar
            )
            // A row with no history charged the same amount on every one of those days,
            // so the summary's own figures answer for all of them and the conversion is
            // done once. A row with one goes through `price(on:)` per day.
            let hasHistory = !summary.subscription.priceChanges.isEmpty
            for date in dates {
                let amount: Decimal
                let currency: String
                let amountInBase: Decimal?
                if hasHistory {
                    (amount, currency) = summary.subscription.price(on: date, calendar: calendar)
                    amountInBase = Normalizer.convert(amount, from: currency, using: document.rates)
                        .map { Normalizer.rounded($0) }
                } else {
                    amount = summary.price
                    currency = summary.currency
                    // The charge converted, which is `nil` exactly when the currency has
                    // no rate — the case the header counts separately.
                    amountInBase = summary.chargeInBase
                }
                rows.append((
                    RenewalOccurrence(
                        subscriptionID: summary.id,
                        date: date,
                        amount: amount,
                        currency: currency,
                        amountInBase: amountInBase
                    ),
                    summary.name
                ))
            }
        }

        return rows
            .sorted { left, right in
                left.occurrence.date == right.occurrence.date
                    ? left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                    : left.occurrence.date < right.occurrence.date
            }
            .map(\.occurrence)
    }

    /// What the month holding `date` costs: the sum of every charge in it, how many
    /// there are, and how many of those the sum had to leave out.
    ///
    /// `excludedCount` is the honest-numbers rule applied to a month rather than to the
    /// hero: a charge in a currency with no rate is counted as a payment and left out of
    /// the money, and the header says so instead of quietly adding zero.
    public func monthTotal(containing date: Date) -> (charged: Decimal, count: Int, excludedCount: Int) {
        let month = MonthRange.bounds(of: date, calendar: calendar)
        let rows = occurrences(from: month.start, to: month.end)
        return (
            charged: rows.reduce(Decimal.zero) { $0 + ($1.amountInBase ?? 0) },
            count: rows.count,
            excludedCount: rows.count { $0.amountInBase == nil }
        )
    }

    // MARK: - Menu bar

    /// The user's choice is the whole answer. Nothing overrides it: a menu bar that
    /// says one thing on most days and something else on the four days a month
    /// something happens to renew is a menu bar the user cannot read at a glance, and
    /// "Icon only" that shows text is not icon only. Renewals falling today are still
    /// said where there is room to say them properly — the main window, and the
    /// notification that morning.
    public func menuBarLabel(style: MenuBarLabelStyle, locale: Locale = .current) -> MenuBarLabelState {
        guard !document.subscriptions.isEmpty else { return .empty }

        switch style {
        case .iconOnly:
            return .iconOnly
        case .monthlyTotal:
            // Whole units, as the locale writes them: "129 €", "€129".
            return .text(MoneyFormatting.compact(monthlyTotal, currency: document.settings.baseCurrency, locale: locale))
        case .nextRenewal:
            // "Spotify · today", "Netflix · in 2 days", "Dropbox · 17 Dec".
            guard let next = upcoming(within: 365).first, let date = next.nextPayment else { return .iconOnly }
            let when = DateFormatting.renewal(date, today: today, calendar: calendar, locale: locale)
            return .text("\(Self.menuBarName(next.name)) · \(when)")
        }
    }

    /// A name short enough for the menu bar: past 14 characters, cut with an ellipsis.
    static func menuBarName(_ name: String) -> String {
        name.count > 14 ? String(name.prefix(13)).trimmingCharacters(in: .whitespaces) + "…" : name
    }

    // MARK: - Filtering and sorting

    public func sorted(
        _ order: SortOrder,
        search: String,
        section: Section,
        ascending: Bool? = nil
    ) -> [SubscriptionSummary] {
        Ledger.sort(
            filtered(search: search, section: section),
            by: order,
            ascending: ascending
        )
    }

    /// Section filter, then search — in that order, so that "no results for x" only
    /// ever means the search.
    public func filtered(search: String, section: Section) -> [SubscriptionSummary] {
        let rows: [SubscriptionSummary]
        switch section {
        // Calendar sits with Overview, which is Home: neither draws this list. Asked
        // for it anyway, through `AppModel.rows`, the answer is
        // "everything you have".
        case .overview, .calendar, .all:
            rows = summaries
        case .upcoming:
            rows = upcoming(within: Section.upcomingWindowDays)
        case .attention:
            rows = needsAttention
        case .pausedCancelled:
            rows = summaries.filter { !$0.status.isBilling }
        case .category(let id):
            rows = summaries.filter { $0.subscription.categoryID == id }
        }

        return Ledger.matching(search, in: rows)
    }

    /// Name search preserves the order of the supplied rows.
    public static func matching(_ search: String, in rows: [SubscriptionSummary]) -> [SubscriptionSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The rules from the API contract:
    ///
    /// - `nextPayment` — soonest first, **no-date items last**.
    /// - `name` — localized, case-insensitive.
    /// - `amount` — the price **as charged**, not converted, biggest first. Comparing
    ///   converted amounts would reorder the list when a rate changes, which is not
    ///   what "sort by amount" means to someone scanning their own numbers.
    /// - `monthly` — `monthlyInBase`, biggest first, excluded items last.
    /// - `category` — the categories' own order, then name.
    ///
    /// Name is the tiebreaker throughout, so the order is total and the All list never
    /// shuffles between renders.
    ///
    /// `ascending` is the direction the user asked for, or `nil` for the order's own
    /// natural one (`SortOrder.naturalAscending`) — which is what every caller that has
    /// never been told otherwise passes. **Reversing flips the primary comparison and
    /// nothing else.** The rules above are not a direction, they are what the column
    /// *means*: an item with no date has no place at the top of a reversed date column
    /// either, and an item left out of the totals is still the least informative row on
    /// the page. So they hold in both directions, and so does the name tiebreaker, which
    /// is what keeps the order total whichever way it runs.
    public static func sort(
        _ rows: [SubscriptionSummary],
        by order: SortOrder,
        ascending: Bool? = nil
    ) -> [SubscriptionSummary] {
        let reversed = (ascending ?? order.naturalAscending) != order.naturalAscending
        switch order {
        case .nextPayment:
            return rows.sorted { left, right in
                switch (left.nextPayment, right.nextPayment) {
                case (nil, nil): return byName(left, right)
                case (nil, _): return false
                case (_, nil): return true
                case (let a?, let b?): return a == b ? byName(left, right) : (reversed ? a > b : a < b)
                }
            }
        case .name:
            return rows.sorted { left, right in
                reversed ? byName(right, left) : byName(left, right)
            }
        case .amount:
            return rows.sorted { left, right in
                left.price == right.price
                    ? byName(left, right)
                    : (reversed ? left.price < right.price : left.price > right.price)
            }
        case .monthly:
            return rows.sorted { left, right in
                switch (left.monthlyInBase, right.monthlyInBase) {
                case (nil, nil): return byName(left, right)
                case (nil, _): return false
                case (_, nil): return true
                case (let a?, let b?): return a == b ? byName(left, right) : (reversed ? a < b : a > b)
                }
            }
        case .category:
            return rows.sorted { left, right in
                if left.category.id == right.category.id { return byName(left, right) }
                if left.category.sortOrder != right.category.sortOrder {
                    return reversed
                        ? left.category.sortOrder > right.category.sortOrder
                        : left.category.sortOrder < right.category.sortOrder
                }
                // Two different categories sharing a position: fall through to their
                // names, and then to the rows' own, so the order stays total.
                switch left.category.name.localizedCaseInsensitiveCompare(right.category.name) {
                case .orderedSame: return byName(left, right)
                case .orderedAscending: return !reversed
                case .orderedDescending: return reversed
                }
            }
        }
    }

    private static func byName(_ left: SubscriptionSummary, _ right: SubscriptionSummary) -> Bool {
        let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
        return comparison == .orderedSame ? left.id.uuidString < right.id.uuidString : comparison == .orderedAscending
    }
}
