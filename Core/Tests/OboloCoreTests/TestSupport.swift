import Foundation
@testable import OboloCore

/// Fixed inputs, so that a test failing means the code changed and not that the machine
/// did.
///
/// Use a Gregorian calendar in Europe/Rome and the British English locale so dates
/// and formatted amounts are independent of the machine running the tests.
enum Fixed {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome") ?? .gmt
        return calendar
    }()

    static let locale = Locale(identifier: "en_GB")

    /// Start of day in `calendar`.
    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)!
    }

    /// The sample library’s reference date, Saturday 22 August 2026.
    static let today = day(2026, 8, 22)

    static func billingDay(_ year: Int, _ month: Int, _ day: Int) -> BillingDay {
        BillingDay(self.day(year, month, day), calendar: calendar)
    }

    static func money(_ literal: String) -> Decimal {
        Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX"))!
    }

    /// `design/fixtures/`, found from this file rather than from the working directory,
    /// so `swift test` works from anywhere.
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)          // …/Core/Tests/OboloCoreTests/TestSupport.swift
            .deletingLastPathComponent()          // …/Core/Tests/OboloCoreTests
            .deletingLastPathComponent()          // …/Core/Tests
            .deletingLastPathComponent()          // …/Core
            .deletingLastPathComponent()          // …/Obolo
            .appendingPathComponent("design/fixtures", isDirectory: true)
    }

    static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appendingPathComponent(name))
    }

    // MARK: - Building documents

    /// A document with the seeded categories, a EUR base and whatever rates are asked
    /// for — the starting point for every hand-built scenario below.
    static func document(
        _ subscriptions: [Subscription] = [],
        rates: [String: Decimal] = [:],
        settings: Settings = Settings(baseCurrency: "EUR")
    ) -> StoreDocument {
        var table = RateTable(base: settings.baseCurrency)
        for (code, value) in rates {
            table.setRate(value, for: code, updatedAt: today)
        }
        return StoreDocument(
            subscriptions: subscriptions,
            categories: Category.seeded,
            rates: table,
            settings: settings
        )
    }

    static func ledger(
        _ subscriptions: [Subscription],
        rates: [String: Decimal] = [:],
        settings: Settings = Settings(baseCurrency: "EUR"),
        today: Date = Fixed.today
    ) -> Ledger {
        Ledger(
            document: document(subscriptions, rates: rates, settings: settings),
            today: today,
            calendar: calendar
        )
    }

    /// A subscription with everything defaulted except what the test cares about.
    static func subscription(
        _ name: String,
        price: String = "10.00",
        currency: String = "EUR",
        cycle: BillingCycle = .monthly,
        anchor: Date? = nil,
        status: Status = .active,
        billingStoppedOn: BillingDay? = nil,
        endsOn: BillingDay? = nil,
        isEstimate: Bool = false,
        category: String = "Software"
    ) -> Subscription {
        Subscription(
            name: name,
            categoryID: Category.seeded.first(named: category)?.id ?? Category.unknown.id,
            price: money(price),
            currency: currency,
            cycle: cycle,
            anchorDate: anchor.map { BillingDay($0, calendar: calendar) },
            status: status,
            billingStoppedOn: billingStoppedOn,
            endsOn: endsOn,
            isEstimate: isEstimate,
            createdAt: day(2026, 1, 1)
        )
    }
}
