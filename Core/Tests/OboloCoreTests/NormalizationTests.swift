import Foundation
import Testing
@testable import OboloCore

/// Billing-cycle conversions and the exchange rates they use.
///
/// These two together are what makes "one monthly number" honest. The order matters and
/// is asserted below: convert to base *first*, then divide by the cycle.
@Suite("Normalisation and rates")
struct NormalizationTests {

    @Test("Payment frequency for each billing cycle")
    func paymentsPerYear() {
        #expect(BillingCycle.weekly.paymentsPerYear == 52)
        #expect(BillingCycle.monthly.paymentsPerYear == 12)
        #expect(BillingCycle.quarterly.paymentsPerYear == 4)
        #expect(BillingCycle.yearly.paymentsPerYear == 1)
        #expect(BillingCycle.everyTwoYears.paymentsPerYear == 0.5)
        #expect(BillingCycle.custom(months: 4).paymentsPerYear == 3)
    }

    @Test("Months per cycle, with weekly deliberately having none")
    func monthsPerCycle() {
        #expect(BillingCycle.weekly.months == nil)
        #expect(BillingCycle.monthly.months == 1)
        #expect(BillingCycle.quarterly.months == 3)
        #expect(BillingCycle.yearly.months == 12)
        #expect(BillingCycle.everyTwoYears.months == 24)
        #expect(BillingCycle.custom(months: 5).months == 5)
    }

    @Test("Each billing cycle converts to a monthly amount")
    func monthlyEquivalents() {
        let price = Fixed.money("120.00")
        #expect(Normalizer.monthlyEquivalent(price: price, cycle: .monthly) == Fixed.money("120"))
        #expect(Normalizer.monthlyEquivalent(price: price, cycle: .quarterly) == Fixed.money("40"))
        #expect(Normalizer.monthlyEquivalent(price: price, cycle: .yearly) == Fixed.money("10"))
        #expect(Normalizer.monthlyEquivalent(price: price, cycle: .everyTwoYears) == Fixed.money("5"))
        #expect(Normalizer.monthlyEquivalent(price: price, cycle: .custom(months: 4)) == Fixed.money("30"))
        // price × 52 ÷ 12
        #expect(Normalizer.monthlyEquivalent(price: Fixed.money("3.00"), cycle: .weekly) == Fixed.money("13"))
    }

    @Test("Yearly equivalents are the charge times its frequency, not the rounded monthly figure")
    func yearlyEquivalents() {
        // €8.90 a year is €0.74 a month, and €0.74 × 12 is €8.88. The per-item yearly
        // figure has to say €8.90 — that is the number on the invoice.
        let rates = RateTable(base: "EUR")
        #expect(Normalizer.yearlyInBase(price: Fixed.money("8.90"), currency: "EUR", cycle: .yearly, rates: rates)
                == Fixed.money("8.90"))
        #expect(Normalizer.monthlyInBase(price: Fixed.money("8.90"), currency: "EUR", cycle: .yearly, rates: rates)
                == Fixed.money("0.74"))
        #expect(Normalizer.yearlyEquivalent(price: Fixed.money("14.99"), cycle: .monthly) == Fixed.money("179.88"))
        #expect(Normalizer.yearlyEquivalent(price: Fixed.money("2.00"), cycle: .weekly) == Fixed.money("104"))
    }

    @Test("A custom cadence of one, three, twelve or twenty-four months folds onto its named cycle")
    func customFoldsOntoNamedCycles() {
        #expect(BillingCycle.canonical(months: 1) == .monthly)
        #expect(BillingCycle.canonical(months: 3) == .quarterly)
        #expect(BillingCycle.canonical(months: 12) == .yearly)
        #expect(BillingCycle.canonical(months: 24) == .everyTwoYears)
        #expect(BillingCycle.canonical(months: 4) == .custom(months: 4))
    }

    // MARK: - Rates

    @Test("The base currency converts one to one without being in the table")
    func baseCurrencyNeedsNoRate() {
        let table = RateTable(base: "EUR")
        #expect(table.rate(for: "EUR") == 1)
        #expect(table.rate(for: "eur") == 1)
        #expect(table.hasRate(for: "EUR"))
    }

    @Test("A currency with no rate returns nothing rather than one")
    func missingRateIsNil() {
        let table = RateTable(base: "EUR", rates: ["USD": Rate(value: Fixed.money("0.856"), updatedAt: Fixed.today)])
        #expect(table.rate(for: "USD") == Fixed.money("0.856"))
        #expect(table.rate(for: "CHF") == nil)
        #expect(!table.hasRate(for: "CHF"))
        #expect(Normalizer.convert(Fixed.money("10"), from: "CHF", using: table) == nil)
    }

    @Test("Conversion happens on the charge, before the cycle is divided out")
    func convertsBeforeNormalising() {
        // At this exchange rate a $24.40 monthly charge contributes €20.89.
        let table = RateTable(base: "EUR", rates: ["USD": Rate(value: Fixed.money("0.856"), updatedAt: Fixed.today)])
        #expect(Normalizer.monthlyInBase(price: Fixed.money("24.40"), currency: "USD", cycle: .monthly, rates: table)
                == Fixed.money("20.89"))
        // And a yearly foreign plan: $120 × 0.856 = €102.72, ÷ 12 = €8.56.
        #expect(Normalizer.monthlyInBase(price: Fixed.money("120.00"), currency: "USD", cycle: .yearly, rates: table)
                == Fixed.money("8.56"))
    }

    @Test("Currency codes are matched case-insensitively and stored uppercase")
    func currencyCodesNormalise() {
        var table = RateTable(base: "eur")
        table.setRate(Fixed.money("0.856"), for: "usd", updatedAt: Fixed.today)
        #expect(table.base == "EUR")
        #expect(table.rates.keys.contains("USD"))
        #expect(table.rate(for: "Usd") == Fixed.money("0.856"))
        #expect(table.currencies == ["EUR", "USD"])
    }

    @Test("Rounding is half away from zero, at two places")
    func rounding() {
        #expect(Normalizer.rounded(Fixed.money("20.8864")) == Fixed.money("20.89"))
        #expect(Normalizer.rounded(Fixed.money("0.741666666")) == Fixed.money("0.74"))
        #expect(Normalizer.rounded(Fixed.money("1.005")) == Fixed.money("1.01"))
        #expect(Normalizer.rounded(Fixed.money("-1.005")) == Fixed.money("-1.01"))
    }

    @Test("A share of nothing is zero rather than a division by zero")
    func shareOfZero() {
        #expect(Normalizer.share(Fixed.money("10"), of: 0) == 0)
        #expect(Normalizer.share(Fixed.money("50"), of: Fixed.money("200")) == 0.25)
    }

    /// The Spend card's two drawings live behind one setting. A document written before
    /// the By month mode existed must open on the donut, which is the card it was
    /// showing when it was last closed.
    @Test("Settings written without a spend view decode to By category")
    func spendViewBackwardCompatible() throws {
        let json = Data(#"{"baseCurrency":"EUR"}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: json)
        #expect(settings.spendView == .category)

        for view in SpendView.allCases {
            let round = try JSONDecoder().decode(
                Settings.self,
                from: JSONEncoder().encode(Settings(spendView: view))
            )
            #expect(round.spendView == view)
        }
    }
}
