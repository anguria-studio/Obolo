import Foundation

/// One recurring charge. Everything the user typed and nothing the app worked out —
/// next payment, monthly equivalent and attention state are all derived by `Ledger`
/// from these fields plus a `today`, never written back here.
public struct Subscription: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: Icon
    public var tint: Tint
    public var categoryID: Category.ID
    /// Per billing cycle, as charged: `10.99`, not `9`. Always the **current** price —
    /// what the All list, the totals and the next payment use. Earlier prices live in
    /// `priceChanges`.
    public var price: Decimal
    /// ISO 4217, uppercase. Normalised on the way in by `init`.
    public var currency: String
    /// What this subscription used to cost, oldest first.
    ///
    /// Empty for almost every row. `price(on:calendar:)` is the one place that turns
    /// this list plus `currentPriceSince` into "what did this cost on that day", and
    /// every past figure in the app goes through it.
    ///
    /// Sorted on every write, so the order is an invariant the reader can rely on.
    public var priceChanges: [PriceChange] {
        didSet { priceChanges.sort { $0.effectiveFrom < $1.effectiveFrom } }
    }
    /// The day the current `price` took over.
    ///
    /// `nil` means "since the first payment" — the form's "Same as first payment"
    /// toggle. See `currentPriceStart` for what that resolves to.
    public var currentPriceSince: BillingDay?
    public var cycle: BillingCycle
    /// Any known payment date, past or future. `nil` is a supported state — the
    /// "no date" case: the item still counts in totals, and shows `—` for Next.
    public var anchorDate: BillingDay?
    public var status: Status
    /// The first day on which this subscription no longer billed.
    ///
    /// This is separate from `endsOn`. A cancelled plan can stop billing now but keep
    /// access until the end of the paid period. The ledger uses this date to keep real
    /// past charges and to stop creating future charges.
    public var billingStoppedOn: BillingDay?
    /// When access stops (cancelled) or the trial converts.
    public var endsOn: BillingDay?
    /// Price is a guess. Renders with a `~` prefix and lands in Needs attention.
    public var isEstimate: Bool
    /// `nil` uses the default, zero means on the day, and `noReminder` disables reminders.
    public var reminderLeadDays: Int?
    public static let noReminder = -1
    public var remindersEnabled: Bool { reminderLeadDays != Self.noReminder }
    public var paymentMethod: String
    public var manageURL: URL?
    /// The service's own domain, bare: `netflix.com`, never `https://www.netflix.com/uk`.
    ///
    /// Normalised on every write — see `Subscription.normalizedDomain` — because it is
    /// pasted as often as it is typed, and everything downstream (the logo candidates,
    /// the Google fallback) builds a URL out of it by string concatenation.
    public var website: String? {
        didSet { website = Subscription.normalizedDomain(website) }
    }
    public var notes: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        icon: Icon = .initial,
        tint: Tint = .accent,
        categoryID: Category.ID,
        price: Decimal,
        currency: String,
        priceChanges: [PriceChange] = [],
        currentPriceSince: BillingDay? = nil,
        cycle: BillingCycle,
        anchorDate: BillingDay? = nil,
        status: Status = .active,
        billingStoppedOn: BillingDay? = nil,
        endsOn: BillingDay? = nil,
        isEstimate: Bool = false,
        reminderLeadDays: Int? = nil,
        paymentMethod: String = "",
        manageURL: URL? = nil,
        website: String? = nil,
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.tint = tint
        self.categoryID = categoryID
        self.price = price
        self.currency = Subscription.normalizedCurrency(currency)
        // A property observer does not run for an assignment inside `init`, so the sort
        // is applied by hand here and inherited by every later write.
        self.priceChanges = priceChanges.sorted { $0.effectiveFrom < $1.effectiveFrom }
        self.currentPriceSince = currentPriceSince
        self.cycle = cycle
        self.anchorDate = anchorDate
        self.status = status
        self.billingStoppedOn = billingStoppedOn
        self.endsOn = endsOn
        self.isEstimate = isEstimate
        self.reminderLeadDays = reminderLeadDays
        self.paymentMethod = paymentMethod
        self.manageURL = manageURL
        // Assigned through the normaliser rather than stored raw: a property observer
        // does not run for an assignment inside `init`.
        self.website = Subscription.normalizedDomain(website)
        self.notes = notes
        self.createdAt = createdAt
    }

    /// The letter drawn in the tinted circle when `icon == .initial`.
    public var initial: String {
        let letter = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .map { String($0) } ?? "?"
        return letter.uppercased()
    }

    // MARK: - Price history

    /// The day the current `price` took over, resolved.
    ///
    /// `currentPriceSince` when the user gave one. When they did not, the current price
    /// has applied since the first payment — but an earlier price recorded *after* that
    /// first payment must still have ended somewhere, so the later of the two days
    /// wins. An unset date can therefore never make the history below it unreachable.
    ///
    /// `nil` only for a subscription with no history and no anchor date, where there is
    /// no earlier price for the current one to have replaced.
    public var currentPriceStart: BillingDay? {
        if let currentPriceSince { return currentPriceSince }
        guard let last = priceChanges.last?.effectiveFrom else { return anchorDate }
        guard let anchorDate else { return last }
        return max(anchorDate, last)
    }

    /// What this subscription cost on `date`, and in which currency.
    ///
    /// The rule, in one place, because it decides every past figure in the app:
    ///
    /// 1. **No history** — `priceChanges` is empty — the current `price` and `currency`,
    ///    whatever the date. This is every subscription until someone records a rise.
    /// 2. **On or after `currentPriceStart`** — the current `price` and `currency`.
    /// 3. **Below that** — the entry with the latest `effectiveFrom` on or before
    ///    `date`.
    /// 4. **Before the first entry** — that first entry's price. Obolo knows of no
    ///    earlier price and does not invent one.
    ///
    /// Rule 4 only reads correctly while the first entry really is the oldest price
    /// Obolo knows of. An entry dated in the future would sit below every settled
    /// charge and rewrite all of them, so such an entry is refused where data comes in
    /// — see `droppingFutureHistory(after:keeping:)`.
    ///
    /// Every comparison is at day granularity in `calendar`, so a change dated
    /// 20 January applies to the charge that lands on 20 January and not to the one
    /// before it.
    public func price(on date: Date, calendar: Calendar = .current) -> (price: Decimal, currency: String) {
        guard !priceChanges.isEmpty else { return (price, currency) }

        let day = BillingDay(date, calendar: calendar)
        if let start = currentPriceStart, day >= start {
            return (price, currency)
        }

        // The list is sorted, so the last entry that has started by `day` is the one in
        // force, and a date below the first entry keeps that first entry.
        let match = priceChanges.last { $0.effectiveFrom <= day }
            ?? priceChanges[0]
        return (match.price, match.currency)
    }

    /// New history can start on any day through the cutoff. An edit can also keep
    /// dates already recorded on another device, even when its local day is ahead.
    /// The current price may have a future start date for an announced price change.
    public func droppingFutureHistory(
        after cutoff: BillingDay,
        keeping recordedDays: Set<BillingDay> = []
    ) -> (subscription: Subscription, dropped: Int) {
        var result = self
        let kept = priceChanges.filter { $0.effectiveFrom <= cutoff || recordedDays.contains($0.effectiveFrom) }
        let dropped = priceChanges.count - kept.count
        if dropped > 0 { result.priceChanges = kept }
        return (result, dropped)
    }

    /// The price rise this subscription has been told about but has not reached yet, or
    /// `nil` — which is every subscription nearly all of the time.
    ///
    /// `price` and `currency` are that rise once one is pending: the stored pair is the
    /// *latest known* price, and `currentPriceStart` says when it begins. Until that day
    /// `price(on:)` answers with the last entry in `priceChanges`, so the All list, the
    /// totals and this month's charge all stay on the price actually being paid.
    public func announcedPriceChange(
        on date: Date,
        calendar: Calendar = .current
    ) -> PriceChange? {
        guard !priceChanges.isEmpty, let start = currentPriceStart else { return nil }
        guard start > BillingDay(date, calendar: calendar) else { return nil }
        return PriceChange(effectiveFrom: start, price: price, currency: currency)
    }

    public static func normalizedCurrency(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    // MARK: - Domain

    /// The domain to fetch a logo for: the `website` the user gave, or the host of the
    /// manage link when they only gave that.
    ///
    /// Deriving from `manageURL` is worth doing because the sheet a real list comes from
    /// has one link column, not two — `https://www.netflix.com/youraccount` names the
    /// service just as well as `netflix.com` does.
    public var effectiveDomain: String? {
        if let website, !website.isEmpty { return website }
        return Subscription.normalizedDomain(manageURL?.absoluteString)
    }

    /// `https://www.Netflix.com/browse?x=1` → `netflix.com`.
    ///
    /// Scheme, `www.`, path, query, fragment, port and trailing dot all come off, and
    /// the result is lowercased. Anything left without a dot in it is not a host — a
    /// half-typed "netflix", a note someone put in the wrong column — and becomes `nil`
    /// rather than a URL that cannot resolve.
    public static func normalizedDomain(_ text: String?) -> String? {
        guard let text else { return nil }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorityStart: String.Index
        let prefix: String
        if input.hasPrefix("//") {
            authorityStart = input.index(input.startIndex, offsetBy: 2)
            prefix = "https://"
        } else if let separator = input.firstIndex(where: { ":/?#".contains($0) }),
                  input[separator...].hasPrefix("://") {
            authorityStart = input.index(separator, offsetBy: 3)
            prefix = String(input[..<authorityStart])
        } else {
            authorityStart = input.startIndex
            prefix = "https://"
        }

        // Only authority text can supply a host. Bare addresses cannot include
        // credentials because an email address or an opaque URL can look the same.
        let authority = input[authorityStart...].prefix { !"/?#".contains($0) }
        let authorityParts = authority.split(separator: "@", omittingEmptySubsequences: false)
        guard authorityParts.count == 1 || (authorityParts.count == 2 && authorityStart != input.startIndex),
              !authority.contains(where: \.isWhitespace),
              !authority.contains("\\"),
              authority.last != ":",
              authorityParts.last?.contains("%") == false,
              let components = URLComponents(string: prefix + authority),
              components.rangeOfPort == nil || UInt16(exactly: components.port ?? -1) != nil,
              let host = components.host
        else { return nil }

        var domain = host.lowercased()
        while domain.hasPrefix("www.") { domain = String(domain.dropFirst(4)) }
        if domain.hasSuffix(".") { domain.removeLast() }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, labels.allSatisfy({ label in
            !label.isEmpty && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return nil }
        return domain
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, tint, categoryID, price, currency, priceChanges, currentPriceSince
        case cycle, anchorDate, status, billingStoppedOn
        case endsOn, isEstimate, reminderLeadDays, paymentMethod, manageURL, website, notes
        case createdAt
    }

    /// Decoded field by field with defaults rather than by synthesis. The store file is
    /// a user document that outlives any one build: a field added in 1.1 must not make
    /// a 1.0 file unreadable, and a field dropped in 1.1 must not make a 1.1 file
    /// unreadable by a user who rolled back. Keys this type no longer has are ignored:
    /// older documents carry `calendarEventIdentifier`, which moved to `DeviceState` on
    /// 2026-08-26.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        icon = try container.decodeIfPresent(Icon.self, forKey: .icon) ?? .initial
        tint = try container.decodeIfPresent(Tint.self, forKey: .tint) ?? .accent
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID) ?? Category.unknown.id
        price = try container.decodeIfPresent(Decimal.self, forKey: .price) ?? 0
        currency = Subscription.normalizedCurrency(
            try container.decodeIfPresent(String.self, forKey: .currency) ?? "EUR"
        )
        // A document written before price history existed has neither key, and decodes
        // to a subscription that has always cost what it costs now.
        priceChanges = (try container.decodeIfPresent([PriceChange].self, forKey: .priceChanges) ?? [])
            .sorted { $0.effectiveFrom < $1.effectiveFrom }
        currentPriceSince = try container.decodeIfPresent(BillingDay.self, forKey: .currentPriceSince)
        cycle = try container.decodeIfPresent(BillingCycle.self, forKey: .cycle) ?? .monthly
        anchorDate = try container.decodeIfPresent(BillingDay.self, forKey: .anchorDate)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .active
        billingStoppedOn = try container.decodeIfPresent(BillingDay.self, forKey: .billingStoppedOn)
        endsOn = try container.decodeIfPresent(BillingDay.self, forKey: .endsOn)
        isEstimate = try container.decodeIfPresent(Bool.self, forKey: .isEstimate) ?? false
        reminderLeadDays = try container.decodeIfPresent(Int.self, forKey: .reminderLeadDays)
        paymentMethod = try container.decodeIfPresent(String.self, forKey: .paymentMethod) ?? ""
        manageURL = try container.decodeIfPresent(URL.self, forKey: .manageURL)
        website = Subscription.normalizedDomain(
            try container.decodeIfPresent(String.self, forKey: .website)
        )
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        // A stored `.paused` decodes as `.paused`. The decoder has no clock, so the
        // conversion to cancelled happens in `resolvingLegacyPause(today:calendar:)`.
    }
}

// MARK: - Corrections on the way in

extension Subscription {
    /// This subscription with a stop date taken from an end date that has passed.
    ///
    /// A row written before `billingStoppedOn` existed carries no stop date. An end date
    /// that has been reached answers for it: a cancelled plan whose access ran out on
    /// 4 March had stopped billing by 4 March. Nothing else does. An undated
    /// cancellation stays undated, and the ledger reports no paid history for it. The
    /// alternative, stamping today, would hand the user years of charges they never made
    /// on exactly the rows they are least able to check.
    public func inferringBillingStop(today: Date, calendar: Calendar) -> Subscription {
        guard !status.isBilling,
              billingStoppedOn == nil,
              let ended = endsOn,
              ended <= BillingDay(today, calendar: calendar)
        else { return self }
        var result = self
        result.billingStoppedOn = ended
        return result
    }

    /// This subscription with a stored `.paused` status turned into `.cancelled`.
    ///
    /// Pause is gone from the app. A paused row can still arrive from
    /// an older store file, a backup, or a record that another Mac wrote to iCloud.
    /// Every door that takes data in calls this function: `AppModel.apply` for the
    /// store, a restore and the result of a merge, and `SyncMerge` for the records it
    /// merges, so that the corrected record also goes back to iCloud.
    ///
    /// The row ends on the day it was paused, or on its last payment before `today` when
    /// that day was not kept. Then the stop date follows the end date, by the same rule
    /// as `inferringBillingStop(today:calendar:)`. History stays, and Reactivate brings
    /// the row back. Every other row is returned unchanged.
    public func resolvingLegacyPause(today: Date, calendar: Calendar) -> Subscription {
        guard status == .paused else { return self }
        var result = self
        result.status = .cancelled
        if result.endsOn == nil {
            result.endsOn = billingStoppedOn ?? Self.lastPayment(
                anchor: anchorDate, cycle: cycle, today: today, calendar: calendar
            )
        }
        return result.inferringBillingStop(today: today, calendar: calendar)
    }

    /// The latest payment before `today`, or nil before the first one.
    private static func lastPayment(
        anchor: BillingDay?,
        cycle: BillingCycle,
        today: Date,
        calendar: Calendar
    ) -> BillingDay? {
        guard let anchor = anchor?.startOfDay(in: calendar) else { return nil }
        let made = RenewalSchedule.paymentsMade(anchor: anchor, cycle: cycle, today: today, calendar: calendar)
        guard made > 0 else { return nil }
        let date = RenewalSchedule.occurrence(index: made - 1, anchor: anchor, cycle: cycle, calendar: calendar)
        return BillingDay(date, calendar: calendar)
    }
}
