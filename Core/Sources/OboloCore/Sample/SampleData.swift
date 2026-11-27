import Foundation

/// The reference dataset the whole package reconciles against.
///
/// Eleven well-known services at their public list prices, chosen so the app can be
/// demonstrated with real logos and a believable spread of categories. It is sample
/// data, not anybody's list.
///
/// The expected totals are €129.41 a month, €1 552.92 a
/// year, 9 active, 2 due within 7 days totalling €23.40, 2 needing attention, and
/// category totals of €73.49 / €13.99 / €11.99 / €9.41 / €8.70 / €7.00 / €4.83. Tests use
/// these figures to check that the totals agree.
///
/// It is also the eleven edge cases in one list: a foreign currency, a missing date, an
/// estimate, a future anchor, and cancelled items with an end date (Audible was the
/// paused one, until Pause went).
public enum SampleData {

    /// Gregorian in Europe/Rome. Pinned so the dataset means the same thing on every
    /// machine — the anchors below were chosen against these day boundaries.
    public static let referenceCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome") ?? .gmt
        return calendar
    }()

    /// Saturday 22 August 2026 — the dataset's `today`.
    public static let referenceToday = day(2026, 8, 22)

    /// USD → EUR, the rate the sample's $10.99 → €9.41 depends on.
    public static let usdRate = Decimal(string: "0.856")!

    /// Builds the reference document.
    ///
    /// `today` moves only the `createdAt` timestamps, which is all it can honestly move:
    /// the anchors are calendar days chosen so the "Next" column reads exactly as the
    /// published table prints it, and shifting them would break the reconciliation the
    /// dataset exists to demonstrate.
    public static func handoff(today: Date = SampleData.referenceToday) -> StoreDocument {
        let calendar = referenceCalendar
        let categories = Category.seeded
        func categoryID(_ name: String) -> Category.ID {
            categories.first(named: name)?.id ?? Category.unknown.id
        }
        /// Days before `today`, so the ordering of `createdAt` is stable and the values
        /// land on whole seconds (which is what makes the CSV round-trip exact).
        func created(_ daysAgo: Int) -> Date {
            calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: today)) ?? today
        }

        var rates = RateTable(base: "EUR")
        rates.setRate(usdRate, for: "USD", updatedAt: created(30))

        let subscriptions: [Subscription] = [
            Subscription(
                id: id(1), name: "Netflix", icon: .initial, tint: .red,
                categoryID: categoryID("Streaming"),
                price: decimal("13.99"), currency: "EUR", cycle: .monthly,
                // Feb 2025, so 18 payments have landed and the next is Mon 24 Aug 2026.
                anchorDate: billingDay(2025, 2, 24), status: .active,
                paymentMethod: "Credit card", website: "netflix.com", createdAt: created(540)
            ),
            Subscription(
                id: id(2), name: "Spotify Premium", icon: .initial, tint: .green,
                categoryID: categoryID("Music"),
                price: decimal("10.99"), currency: "USD", cycle: .monthly,
                anchorDate: billingDay(2025, 3, 25), status: .active,
                paymentMethod: "PayPal", website: "spotify.com",
                notes: "Billed in USD, converted at the stored rate.", createdAt: created(510)
            ),
            Subscription(
                id: id(3), name: "Adobe Creative Cloud", icon: .initial, tint: .orange,
                categoryID: categoryID("Software"),
                price: decimal("65.49"), currency: "EUR", cycle: .monthly,
                // The no-date case: still counts in the totals, shows "—" for Next.
                anchorDate: nil, status: .active,
                paymentMethod: "Credit card", website: "adobe.com",
                notes: "Renewal day unknown. Add the date.", createdAt: created(120)
            ),
            Subscription(
                id: id(4), name: "Dropbox Plus", icon: .initial, tint: .accent,
                categoryID: categoryID("Cloud storage"),
                price: decimal("11.99"), currency: "EUR", cycle: .monthly,
                anchorDate: billingDay(2024, 9, 17), status: .active,
                paymentMethod: "Credit card", website: "dropbox.com", createdAt: created(700)
            ),
            Subscription(
                id: id(5), name: "Duolingo Super", icon: .initial, tint: .green,
                categoryID: categoryID("Other"),
                price: decimal("83.99"), currency: "EUR", cycle: .yearly,
                anchorDate: billingDay(2023, 11, 4), status: .active,
                paymentMethod: "Apple ID", website: "duolingo.com", createdAt: created(900)
            ),
            Subscription(
                id: id(6), name: "1Password Families", icon: .initial, tint: .purple,
                categoryID: categoryID("Security & VPN"),
                price: decimal("59.88"), currency: "EUR", cycle: .yearly,
                anchorDate: billingDay(2024, 1, 2), status: .active,
                // The per-item reminder override.
                reminderLeadDays: 7, paymentMethod: "Card ••1234", website: "1password.com",
                notes: "59.88 before tax; about €73 with 22% VAT at checkout",
                createdAt: created(800)
            ),
            Subscription(
                id: id(7), name: "Headspace", icon: .initial, tint: .orange,
                categoryID: categoryID("Fitness & health"),
                price: decimal("57.99"), currency: "EUR", cycle: .yearly,
                anchorDate: billingDay(2024, 1, 17), status: .active,
                paymentMethod: "Apple ID", website: "headspace.com", createdAt: created(790)
            ),
            Subscription(
                id: id(8), name: "Notion Plus", icon: .initial, tint: .teal,
                categoryID: categoryID("Software"),
                price: decimal("96.00"), currency: "EUR", cycle: .yearly,
                anchorDate: billingDay(2024, 3, 9), status: .active,
                paymentMethod: "Credit card", website: "notion.so", createdAt: created(760)
            ),
            Subscription(
                id: id(9), name: "NordVPN", icon: .initial, tint: .accent,
                categoryID: categoryID("Security & VPN"),
                price: decimal("89.00"), currency: "EUR", cycle: .everyTwoYears,
                // Paid up front: the anchor is in the future, so it *is* the next
                // payment and "paid so far" is hidden.
                anchorDate: billingDay(2028, 8, 31), status: .active,
                isEstimate: true, website: "nordvpn.com",
                notes: "Estimate. Replace it with the real amount from the account page.",
                createdAt: created(60)
            ),
            Subscription(
                id: id(10), name: "Disney+", icon: .initial, tint: .cyan,
                categoryID: categoryID("Streaming"),
                price: decimal("8.99"), currency: "EUR", cycle: .monthly,
                anchorDate: billingDay(2026, 3, 5), status: .cancelled,
                billingStoppedOn: billingDay(2026, 8, 1),
                endsOn: billingDay(2026, 9, 5),
                paymentMethod: "Apple ID", website: "disneyplus.com",
                notes: "Cancelled. Access expires 5 Sep 2026.",
                createdAt: created(170)
            ),
            Subscription(
                id: id(11), name: "Audible", icon: .initial, tint: .yellow,
                categoryID: categoryID("Music"),
                price: decimal("9.95"), currency: "EUR", cycle: .monthly,
                anchorDate: billingDay(2026, 5, 12), status: .cancelled,
                billingStoppedOn: billingDay(2026, 8, 1), endsOn: billingDay(2026, 8, 1),
                paymentMethod: "Credit card", website: "audible.com",
                notes: "Cancelled. Access ended 1 Aug 2026.", createdAt: created(300)
            )
        ]

        return StoreDocument(
            subscriptions: subscriptions,
            categories: categories,
            rates: rates,
            settings: Settings(baseCurrency: "EUR")
        )
    }

    /// A `Ledger` over `handoff()`, which is what most of the tests and every SwiftUI
    /// preview actually wants.
    public static func handoffLedger(today: Date = SampleData.referenceToday) -> Ledger {
        Ledger(document: handoff(today: today), today: today, calendar: referenceCalendar)
    }

    // MARK: - Helpers

    /// Start of day in `referenceCalendar`.
    public static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return referenceCalendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    public static func billingDay(_ year: Int, _ month: Int, _ day: Int) -> BillingDay {
        BillingDay(self.day(year, month, day), calendar: referenceCalendar)
    }

    private static func decimal(_ literal: String) -> Decimal {
        Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    /// Fixed IDs so the checked-in `sample.csv` stays byte-stable across runs.
    private static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "50000000-0000-4000-B000-%012d", index))!
    }
}
