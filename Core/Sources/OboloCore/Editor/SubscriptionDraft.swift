import Foundation

/// A working copy of a subscription with text fields that can hold unfinished input.
public struct SubscriptionDraft: Equatable, Sendable {

    /// One line of the price history editor. The price is text for the same reason
    /// the main price field is: a half-typed "14." has to be allowed to exist.
    public struct PriceChangeRow: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public var date: BillingDay
        public var priceText: String
        public var currency: String

        public init(date: BillingDay, priceText: String, currency: String) {
            self.date = date
            self.priceText = priceText
            self.currency = currency
        }

        public var price: Decimal? { SubscriptionDraft.parsePrice(priceText, currency: currency) }
    }

    public enum PriceSummary: Equatable, Sendable {
        case missingStartingPrice
        case unreadableChange
        case currentPrice(amount: Decimal, currency: String)
    }

    public var name: String
    public var icon: Icon
    public var tint: Tint
    public var categoryID: Category.ID
    /// The price at the **first payment**, as text — the field must let a half-typed
    /// "14." exist.
    ///
    /// Not `Subscription.price`, which is the price *now*. The form reads forward in
    /// time and the store keeps the current price, so the two are the same value
    /// only until a change is recorded; `init` and `subscription()` do the turn.
    public var priceText: String
    public var currency: String
    /// What happened to the price **after** the first payment, oldest first.
    ///
    /// Identified by a `UUID` of their own rather than by their date, because two
    /// rows can hold the same date for as long as it takes to type the second one.
    /// The row with the latest date is the current price.
    public var priceChanges: [PriceChangeRow]
    public var cycle: BillingCycle
    public var hasAnchor: Bool
    public var anchorDate: BillingDay
    public var status: Status
    /// The two halves of `Subscription.billingStoppedOn`, so that "unknown" stays
    /// expressible: a row can be cancelled without anybody remembering when it last
    /// charged, and the app must not fill that in.
    public var hasBillingStop: Bool
    public var billingStopDate: BillingDay
    public var hasEndDate: Bool
    public var endDate: BillingDay
    public var isEstimate: Bool
    public var reminderLeadDays: Int?
    public var paymentMethod: String
    public var manageURLText: String
    /// Text, like the manage link: the field must let a half-typed "basic-" exist,
    /// and normalising happens once, on the way out.
    public var websiteText: String
    public var notes: String
    /// Preserves the subscription's identity, creation time and stored price dates.
    private let original: Subscription

    public var startingPrice: Decimal? { Self.parsePrice(priceText, currency: currency) }

    /// Prices to summarize while editing, even when other fields still prevent saving.
    public var priceSummary: PriceSummary {
        let changes = enteredPriceChanges
        if changes.contains(where: { $0.price == nil }) { return .unreadableChange }
        guard let start = startingPrice, start > 0 else { return .missingStartingPrice }
        if let latest = changes.last, let price = latest.price {
            return .currentPrice(amount: price, currency: latest.currency)
        }
        return .currentPrice(amount: start, currency: currency)
    }

    /// The editor gives each new row a date and currency. Its price text determines
    /// whether it was filled in. Stable sorting keeps rows in editor order on the same day.
    private var enteredPriceChanges: [PriceChangeRow] {
        priceChanges
            .filter { !$0.priceText.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.date < $1.date }
    }

    public init(
        _ subscription: Subscription,
        isNew: Bool,
        prefill: SubscriptionFormPrefill? = nil,
        calendar: Calendar = .current
    ) {
        name = subscription.name
        icon = subscription.icon
        tint = subscription.tint
        categoryID = subscription.categoryID
        // A brand-new row starts with an empty field rather than a literal 0, so
        // the placeholder does the explaining and the first keystroke does not have
        // to delete anything.
        // The store keeps the current price and the prices before it; the form edits
        // the starting price and the changes after it. Laying the whole timeline out
        // in order and splitting it the other way is the turn, and this and
        // `subscription()` are the only two places the shapes meet.
        //
        // Keep the stored starting day even though the form shows the first payment.
        // Editing the first payment moves the starting price with it.
        let createdDay = BillingDay(subscription.createdAt, calendar: calendar)
        original = subscription
        let timeline: [(date: BillingDay, price: Decimal, currency: String)] =
            subscription.priceChanges.map { ($0.effectiveFrom, $0.price, $0.currency) }
            + [(
                subscription.currentPriceStart ?? createdDay,
                subscription.price,
                subscription.currency
            )]

        let start = timeline[0]
        priceText = isNew && start.price == 0 ? "" : Self.format(start.price, currency: start.currency)
        currency = start.currency
        priceChanges = timeline.dropFirst().map {
            PriceChangeRow(
                date: $0.date,
                priceText: Self.format($0.price, currency: $0.currency),
                currency: $0.currency
            )
        }
        cycle = subscription.cycle
        // A new row starts with no date rather than with today. Today is almost
        // never the first payment, and a field that already holds a plausible date
        // is a field people accept: the app then believes the subscription started
        // the day it was typed in, and every past occurrence is lost — the payments
        // so far, the past months on the calendar, the price history. Empty asks the
        // question instead of answering it wrongly.
        hasAnchor = isNew ? false : subscription.anchorDate != nil
        anchorDate = subscription.anchorDate ?? createdDay
        status = subscription.status
        hasBillingStop = subscription.billingStoppedOn != nil
        billingStopDate = subscription.billingStoppedOn ?? createdDay
        hasEndDate = subscription.endsOn != nil
        endDate = subscription.endsOn ?? createdDay
        isEstimate = subscription.isEstimate
        reminderLeadDays = subscription.reminderLeadDays
        paymentMethod = subscription.paymentMethod
        manageURLText = subscription.manageURL?.absoluteString ?? ""
        websiteText = subscription.website ?? ""
        notes = subscription.notes
        if let name = prefill?.name { self.name = name }
        if let price = prefill?.price {
            priceText = Self.format(price, currency: prefill?.currency ?? currency)
        }
        if let currency = prefill?.currency { self.currency = currency }
        if let cycle = prefill?.cycle { self.cycle = cycle }
        if let anchorDate = prefill?.anchorDate {
            hasAnchor = true
            self.anchorDate = anchorDate
        }
    }

    /// An end date only means something for a cancellation or a trial.
    private var showsEndDate: Bool {
        status == .cancelled || status == .trial
    }

    /// A billing stop date only means something for a row that has stopped billing.
    /// Distinct from `showsEndDate`: a cancelled plan often stops charging on one day
    /// and keeps access until another.
    private var showsBillingStop: Bool {
        !status.isBilling
    }

    /// The subscription ready to save, or `nil` if the draft is invalid.
    public func subscription() -> Subscription? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        guard let price = startingPrice, price > 0 else { return nil }
        let code = Subscription.normalizedCurrency(currency)
        guard code.count == 3 else { return nil }

        // The form's timeline, oldest first: the starting price at the first
        // payment, then every change. Sorted here rather than on every keystroke, so
        // rows do not jump under the pointer while a date is being typed into one.
        var timeline: [(date: BillingDay, price: Decimal, currency: String)] = []
        for row in enteredPriceChanges {
            guard let value = row.price, value >= 0 else { return nil }
            let rowCurrency = Subscription.normalizedCurrency(row.currency)
            guard rowCurrency.count == 3 else { return nil }
            timeline.append((row.date, value, rowCurrency))
        }
        // Without a first payment the starting price still has to begin somewhere,
        // and the honest day is the one before everything else in the list: that
        // makes it answer for every charge below the first change, which is what it
        // means, without inventing an anchor date the user did not give.
        let anchor = hasAnchor ? anchorDate : nil
        let retainedStart = anchor == original.anchorDate ? original.priceChanges.first?.effectiveFrom : nil
        let startDate = retainedStart ?? anchor ?? timeline.first?.date ?? anchorDate
        timeline.insert((startDate, price, code), at: 0)

        // The store keeps the *current* price plus everything before it.
        let current = timeline[timeline.count - 1]
        let history = timeline.dropLast().map {
            PriceChange(effectiveFrom: $0.date, price: $0.price, currency: $0.currency)
        }
        let currentPriceSince: BillingDay?
        if history.isEmpty {
            currentPriceSince = original.priceChanges.isEmpty ? original.currentPriceSince : nil
        } else if !original.priceChanges.isEmpty, current.date == original.currentPriceStart, anchor == original.anchorDate {
            currentPriceSince = original.currentPriceSince
        } else {
            currentPriceSince = current.date
        }

        return Subscription(
            id: original.id,
            name: trimmedName,
            icon: icon,
            tint: tint,
            categoryID: categoryID,
            price: current.price,
            currency: current.currency,
            priceChanges: Array(history),
            currentPriceSince: currentPriceSince,
            cycle: cycle,
            anchorDate: anchor,
            status: status,
            billingStoppedOn: showsBillingStop && hasBillingStop ? billingStopDate : nil,
            endsOn: showsEndDate && hasEndDate ? endDate : nil,
            isEstimate: isEstimate,
            reminderLeadDays: reminderLeadDays,
            paymentMethod: paymentMethod.trimmingCharacters(in: .whitespacesAndNewlines),
            manageURL: Self.parseURL(manageURLText),
            website: websiteText,
            notes: notes,
            createdAt: original.createdAt
        )
    }

    /// Plain digits and the locale's decimal separator, padded to the currency's
    /// usual precision. Keep any extra digits so opening and saving preserves prices.
    public static func format(_ value: Decimal, currency: String, locale: Locale = .current) -> String {
        let currencyDigits = MoneyFormatting.fractionDigits(of: currency)
        let valueDigits = max(0, -value.exponent)
        // In a currency that uses fewer than three places, one extra zero keeps
        // a stored three-place fraction distinct from a grouped integer.
        let minimum = currencyDigits < 3 && valueDigits == 3 ? 4 : currencyDigits
        return value.formatted(
            .number
                .locale(locale)
                .grouping(.never)
                .precision(.fractionLength(minimum...max(minimum, valueDigits)))
        )
    }

    /// A price field's text tidied once the person leaves it: "108,8" becomes
    /// "108,80". Text that doesn't read as a price is left as typed.
    public static func tidied(_ text: String, currency: String, locale: Locale = .current) -> String {
        guard let value = parsePrice(text, currency: currency, locale: locale) else { return text }
        return format(value, currency: currency, locale: locale)
    }

    public static func parsePrice(_ text: String, currency: String, locale: Locale = .current) -> Decimal? {
        let separators = [".", ",", "-", locale.decimalSeparator, locale.groupingSeparator].compactMap { $0 }
        guard text.allSatisfy({ $0.isWhitespace || $0.isNumber || separators.contains(String($0)) })
        else { return nil }
        return ValueParsing.decimal(text, currency: currency, locale: locale)
    }

    /// Keep the amounts when switching currencies. The old and new codes may
    /// interpret the same three digits as a fraction or as a thousands group.
    public mutating func setCurrency(_ code: String) {
        if let startingPrice { priceText = Self.format(startingPrice, currency: code) }
        currency = code
        for index in priceChanges.indices {
            if let price = priceChanges[index].price {
                priceChanges[index].priceText = Self.format(price, currency: code)
            }
            priceChanges[index].currency = code
        }
    }

    /// A bare "netflix.com" becomes `https://netflix.com`; anything unparseable
    /// becomes `nil` rather than a broken link.
    private static func parseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://" + trimmed)
    }
}
