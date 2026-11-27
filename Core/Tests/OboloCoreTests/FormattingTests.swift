import Foundation
import Testing
@testable import OboloCore

/// A fixed British locale keeps expected strings stable across test machines. The app
/// uses the current locale, so an Italian Mac formats the same values as “14,99 €” and “24 ago”.
@Suite("Formatting")
struct FormattingTests {

    private let locale = Fixed.locale
    private let calendar = Fixed.calendar

    // MARK: - Money

    @Test("Amounts render in their own currency with the locale's symbol placement")
    func amounts() {
        #expect(MoneyFormatting.amount(Fixed.money("14.99"), currency: "EUR", locale: locale) == "€14.99")
        #expect(MoneyFormatting.amount(Fixed.money("2.99"), currency: "EUR", locale: locale) == "€2.99")
        #expect(MoneyFormatting.amount(Fixed.money("1912.08"), currency: "EUR", locale: locale) == "€1,912.08")
        // Narrow presentation, so a dollar price reads "$24.40" and not "US$24.40".
        #expect(MoneyFormatting.amount(Fixed.money("24.40"), currency: "USD", locale: locale) == "$24.40")
    }

    @Test("Whole units drop the cents, rounding half up, for a big figure in a tight spot")
    func wholeUnits() {
        let italian = Locale(identifier: "it_IT")
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(plain(MoneyFormatting.amount(Fixed.money("23456.79"), currency: "EUR", locale: italian, wholeUnits: true)) == "23.457 €")
        #expect(plain(MoneyFormatting.amount(Fixed.money("23456.50"), currency: "EUR", locale: italian, wholeUnits: true)) == "23.457 €")
        // Off by default, and below the ring's 10.000 the caller keeps the cents. (Italian
        // groups thousands only from five digits.)
        #expect(plain(MoneyFormatting.amount(Fixed.money("9999.99"), currency: "EUR", locale: italian)) == "9999,99 €")
    }

    @Test("An estimate carries a tilde wherever it appears")
    func estimatesAreMarked() {
        #expect(MoneyFormatting.amount(Fixed.money("80.00"), currency: "EUR", estimate: true, locale: locale) == "~€80.00")
        #expect(MoneyFormatting.amount(Fixed.money("80.00"), currency: "EUR", estimate: false, locale: locale) == "€80.00")
    }

    @Test("The menu bar's compact form drops the cents")
    func compact() {
        #expect(MoneyFormatting.compact(Fixed.money("159.34"), currency: "EUR", locale: locale) == "€159")
        #expect(MoneyFormatting.compact(Fixed.money("159.74"), currency: "EUR", locale: locale) == "€160")
    }

    @Test("An unknown amount is an em dash, never a zero")
    func unknownIsNotZero() {
        #expect(MoneyFormatting.unknown == "-")
        #expect(MoneyFormatting.amount(Fixed.money("0"), currency: "EUR", locale: locale) == "€0.00")
    }

    @Test("A price's cadence is spelled out after it")
    func perUnitSuffix() {
        #expect(BillingCycle.monthly.perUnitSuffix == "/ month")
        #expect(BillingCycle.everyTwoYears.perUnitSuffix == "/ 2 years")
        #expect(BillingCycle.custom(months: 4).perUnitSuffix == "/ 4 months")
        #expect(BillingCycle.custom(months: 1).perUnitSuffix == "/ month")
    }

    // MARK: - Dates

    @Test("The detail header's short units fit two mono lines of the same width")
    func shortPerUnitSuffix() {
        #expect(BillingCycle.weekly.shortPerUnitSuffix == "/ wk")
        #expect(BillingCycle.monthly.shortPerUnitSuffix == "/ mo")
        #expect(BillingCycle.quarterly.shortPerUnitSuffix == "/ 3 mo")
        #expect(BillingCycle.yearly.shortPerUnitSuffix == "/ yr")
        #expect(BillingCycle.everyTwoYears.shortPerUnitSuffix == "/ 2 yr")
        #expect(BillingCycle.custom(months: 1).shortPerUnitSuffix == "/ mo")
        #expect(BillingCycle.custom(months: 6).shortPerUnitSuffix == "/ 6 mo")
        // The long form stays as it was everywhere else.
        #expect(BillingCycle.monthly.perUnitSuffix == "/ month")
    }

    @Test("Dates within a week are relative, and everything else is absolute")
    func renewalDates() {
        func renewal(_ date: Date) -> String {
            DateFormatting.renewal(date, today: Fixed.today, calendar: calendar, locale: locale)
        }
        #expect(renewal(Fixed.today) == "today")
        #expect(renewal(Fixed.day(2026, 8, 23)) == "tomorrow")
        #expect(renewal(Fixed.day(2026, 8, 24)) == "in 2 days")
        #expect(renewal(Fixed.day(2026, 8, 29)) == "in 7 days")
        // One day past the window, the absolute date takes over.
        #expect(renewal(Fixed.day(2026, 8, 30)) == "30 Aug")
        #expect(renewal(Fixed.day(2026, 9, 17)) == "17 Sep")
        // A different year brings the year with it.
        #expect(renewal(Fixed.day(2027, 1, 2)) == "2 Jan 2027")
        #expect(renewal(Fixed.day(2028, 8, 31)) == "31 Aug 2028")
    }

    @Test("Recent past dates read as past, not as a negative number of days")
    func pastDates() {
        func renewal(_ date: Date) -> String {
            DateFormatting.renewal(date, today: Fixed.today, calendar: calendar, locale: locale)
        }
        #expect(renewal(Fixed.day(2026, 8, 21)) == "yesterday")
        #expect(renewal(Fixed.day(2026, 8, 19)) == "3 days ago")
        #expect(renewal(Fixed.day(2026, 7, 1)) == "1 Jul")
    }

    @Test("Notification titles get a weekday")
    func weekdays() {
        // "Netflix renews Sunday".
        #expect(DateFormatting.weekday(Fixed.day(2026, 8, 23), calendar: calendar, locale: locale) == "Sunday")
        #expect(DateFormatting.weekday(Fixed.day(2026, 8, 24), calendar: calendar, locale: locale) == "Monday")
    }

    @Test("The form's preview line names the day, which is what makes a clamped date believable")
    func weekdayAndDate() {
        #expect(DateFormatting.weekdayAndDate(Fixed.day(2026, 8, 25), today: Fixed.today, calendar: calendar, locale: locale)
                == "Tue 25 Aug")
        // The punctuation is the locale's, not ours — `en_GB` adds a comma once the year
        // joins in, and an Italian Mac writes "sab 2 gen 2027".
        #expect(DateFormatting.weekdayAndDate(Fixed.day(2027, 1, 2), today: Fixed.today, calendar: calendar, locale: locale)
                == "Sat, 2 Jan 2027")
    }

    @Test("Upcoming groups under a month and year")
    func monthHeaders() {
        #expect(DateFormatting.monthAndYear(Fixed.day(2026, 8, 24), calendar: calendar, locale: locale) == "August 2026")
        #expect(DateFormatting.monthAndYear(Fixed.day(2026, 9, 17), calendar: calendar, locale: locale) == "September 2026")
    }

    @Test("The ISO form is locale-proof, which is what CSV needs")
    func isoDates() {
        #expect(DateFormatting.iso(Fixed.day(2026, 8, 24), calendar: calendar) == "2026-08-24")
        #expect(DateFormatting.iso(Fixed.day(2026, 1, 2), calendar: calendar) == "2026-01-02")
    }

    // MARK: - Attention labels

    @Test("Attention states carry the words the pills show")
    func attentionLabels() {
        #expect(Attention.dueSoon.shortLabel == "due soon")
        #expect(Attention.noDate.shortLabel == "no date")
        #expect(Attention.missingRate.shortLabel == "no rate")
        #expect(Attention.estimate.shortLabel == "estimate")
        // The design's "ends 5 Sep".
        #expect(Attention.endsOn(Fixed.day(2026, 9, 5)).label(today: Fixed.today, calendar: calendar, locale: locale)
                == "ends 5 Sep")
        #expect(Attention.trialEnds(Fixed.day(2026, 8, 25)).label(today: Fixed.today, calendar: calendar, locale: locale)
                == "trial ends in 3 days")
    }

    // MARK: - Cycles

    @Test("Cycle names read as the picker shows them")
    func cycleNames() {
        #expect(BillingCycle.weekly.displayName == "Weekly")
        #expect(BillingCycle.everyTwoYears.displayName == "Every 2 years")
        #expect(BillingCycle.custom(months: 5).displayName == "Every 5 months")
        // A count that has a name of its own gets it, so no picker ever offers both.
        #expect(BillingCycle.canonical(months: 3).displayName == "Quarterly")
    }

    @Test("The compact suffix counts whole years when the months divide by 12", arguments: [
        (BillingCycle.weekly, "/wk"),
        (.monthly, "/mo"),
        (.quarterly, "/3mo"),
        (.yearly, "/yr"),
        (.everyTwoYears, "/2y"),
        (.custom(months: 1), "/mo"),
        (.custom(months: 2), "/2mo"),
        (.custom(months: 12), "/yr"),
        (.custom(months: 18), "/18mo"),
        (.custom(months: 24), "/2y"),
        (.custom(months: 36), "/3y"),
        (BillingCycle.canonical(months: 24), "/2y")
    ])
    func compactSuffix(cycle: BillingCycle, expected: String) {
        #expect(cycle.compactSuffix == expected)
    }

    @Test("A reminder lead time reads in days, a week, or on the day")
    func reminderLeadText() {
        #expect(Settings.reminderLeadText(days: 0) == "on the day")
        #expect(Settings.reminderLeadText(days: 1) == "1 day before")
        #expect(Settings.reminderLeadText(days: 2) == "2 days before")
        #expect(Settings.reminderLeadText(days: 7) == "1 week before")
        #expect(Settings.reminderLeadText(days: 14) == "14 days before")
    }

    @Test("The compact period is the count and unit behind the suffix")
    func compactPeriod() {
        #expect(BillingCycle.weekly.compactPeriod == (1, .week))
        #expect(BillingCycle.quarterly.compactPeriod == (3, .month))
        #expect(BillingCycle.custom(months: 18).compactPeriod == (18, .month))
        #expect(BillingCycle.custom(months: 24).compactPeriod == (2, .year))
        #expect(BillingCycle.everyTwoYears.compactPeriod == (2, .year))
        #expect(BillingCycle.CompactUnit.year.abbreviation == "yr")
    }
}
