import Foundation
import Testing
@testable import OboloCore

/// The download half of the money: one response from Frankfurter, turned into the
/// numbers `RateTable` stores.
///
/// The direction is the test that matters. Everything else here is a guard on it.
@Suite("Rate refresh")
struct RateRefreshTests {

    /// The real answer for 21 August 2026, byte for byte.
    private static let live = Data("""
    {"amount":1.0,"base":"EUR","date":"2026-08-21","rates":{"CHF":0.9353,"GBP":0.8567,"USD":1.1699}}
    """.utf8)

    private static func body(_ rates: String, base: String = "EUR", date: String = "2026-08-21") -> Data {
        Data(#"{"amount":1.0,"base":"\#(base)","date":"\#(date)","rates":{\#(rates)}}"#.utf8)
    }

    // MARK: - Direction

    @Test("A quote of 1.168 dollars per euro is stored as 0.856164 euros per dollar")
    func inverts() throws {
        let (_, rates) = try RateRefresh.parse(data: Self.body(#""USD":1.168"#), base: "EUR")
        #expect(rates["USD"] == Fixed.money("0.856164"))
    }

    @Test("The stored rate multiplies a foreign charge into the base")
    func multipliesIntoBase() throws {
        let (asOf, rates) = try RateRefresh.parse(data: Self.live, base: "EUR")
        var table = RateTable(base: "EUR")
        table.applyAutomatic(rates, asOf: asOf)

        // $24.40 a month — the one non-euro row in the real list.
        let converted = Normalizer.monthlyInBase(
            price: Fixed.money("24.40"), currency: "USD", cycle: .monthly, rates: table
        )
        #expect(converted == Fixed.money("20.86"))
    }

    // MARK: - Rounding

    @Test("Rates are rounded to six decimal places")
    func roundsToSixPlaces() throws {
        let (_, rates) = try RateRefresh.parse(data: Self.live, base: "EUR")
        // 1 / 1.1699 = 0.8547739123…, 1 / 0.9353 = 1.0691756655…
        #expect(rates["USD"] == Fixed.money("0.854774"))
        #expect(rates["CHF"] == Fixed.money("1.069176"))
        #expect(rates["GBP"] == Fixed.money("1.167270"))
    }

    @Test("A quoted rate is read from its digits, not through a binary float")
    func decimalIsExact() throws {
        let (_, rates) = try RateRefresh.parse(data: Self.body(#""USD":2.0"#), base: "EUR")
        #expect(rates["USD"] == Decimal(string: "0.5"))
    }

    // MARK: - What comes back, and what does not

    @Test("A currency Frankfurter does not cover is simply absent")
    func unsupportedCurrencyIsAbsent() throws {
        // The live server answers `symbols=USD,XYZ` with USD alone.
        let (_, rates) = try RateRefresh.parse(data: Self.body(#""USD":1.1699"#), base: "EUR")
        #expect(rates["XYZ"] == nil)
        #expect(rates.count == 1)
    }

    @Test("The base is never given a rate of its own")
    func baseIsSkipped() throws {
        let (_, rates) = try RateRefresh.parse(data: Self.body(#""EUR":1.0,"USD":1.1699"#), base: "EUR")
        #expect(rates["EUR"] == nil)
    }

    @Test("A zero or negative quote is dropped rather than divided by")
    func nonsenseQuotesAreDropped() throws {
        let (_, rates) = try RateRefresh.parse(data: Self.body(#""USD":0,"GBP":0.8567"#), base: "EUR")
        #expect(rates["USD"] == nil)
        #expect(rates["GBP"] != nil)
    }

    @Test("Malformed JSON throws")
    func malformedThrows() {
        #expect(throws: RateRefresh.ParseError.malformed) {
            try RateRefresh.parse(data: Data("not json at all".utf8), base: "EUR")
        }
        #expect(throws: RateRefresh.ParseError.malformed) {
            // Frankfurter's own 404 body.
            try RateRefresh.parse(data: Data(#"{"message":"not found"}"#.utf8), base: "EUR")
        }
    }

    @Test("An answer about a different base is refused")
    func wrongBaseThrows() {
        #expect(throws: RateRefresh.ParseError.wrongBase(expected: "GBP", got: "EUR")) {
            try RateRefresh.parse(data: Self.live, base: "GBP")
        }
    }

    // MARK: - The day

    @Test("The publication date is a calendar day in UTC")
    func dateIsAUTCDay() throws {
        let (asOf, _) = try RateRefresh.parse(data: Self.live, base: "EUR")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(utc.dateComponents([.year, .month, .day], from: asOf) == DateComponents(year: 2026, month: 8, day: 21))

        // And it still reads as the 21st on the other side of the Atlantic, which is
        // the only reason this stamp exists.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(newYork.component(.day, from: asOf) == 21)
    }

    @Test("A date that is not a day throws")
    func badDateThrows() throws {
        #expect(throws: RateRefresh.ParseError.badDate("yesterday")) {
            try RateRefresh.parse(data: Self.body(#""USD":1.1"#, date: "yesterday"), base: "EUR")
        }
        #expect(RateRefresh.day("2026-13-01") == nil)
        #expect(RateRefresh.day("26-08-21") == nil)
        // The same reader the importer uses, so a day that never existed is refused
        // here too rather than landing three days later.
        #expect(RateRefresh.day("2026-02-31") == nil)
        #expect(RateRefresh.day("2025-02-29") == nil)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let leapDay = try #require(RateRefresh.day("2024-02-29"))
        #expect(utc.dateComponents([.year, .month, .day], from: leapDay)
                == DateComponents(year: 2024, month: 2, day: 29))
    }

    // MARK: - The request

    @Test("One request, base and symbols only")
    func urlCarriesOnlyCodes() throws {
        let url = try #require(RateRefresh.url(base: "eur", symbols: ["usd", "GBP", "EUR", "nonsense"]))
        #expect(url.absoluteString == "https://api.frankfurter.dev/v1/latest?base=EUR&symbols=GBP,USD")
    }

    @Test("Nothing to ask about means no request at all")
    func noSymbolsMeansNoURL() {
        #expect(RateRefresh.url(base: "EUR", symbols: []) == nil)
        #expect(RateRefresh.url(base: "EUR", symbols: ["EUR"]) == nil)
    }
}

// MARK: - Applying them

@Suite("Automatic rates in the table")
struct AutomaticRateTests {

    private let asOf = Fixed.day(2026, 8, 21)

    @Test("An automatic refresh replaces an automatic rate")
    func replacesAutomatic() {
        var table = RateTable(base: "EUR")
        table.applyAutomatic(["USD": Fixed.money("0.9")], asOf: Fixed.day(2026, 8, 14))
        table.applyAutomatic(["USD": Fixed.money("0.854774")], asOf: asOf)

        #expect(table.rate(for: "USD") == Fixed.money("0.854774"))
        #expect(table.source(for: "USD") == .automatic)
        #expect(table.rates["USD"]?.updatedAt == asOf)
    }

    @Test("A rate the user typed is never overwritten")
    func preservesManual() {
        var table = RateTable(base: "EUR")
        table.setRate(Fixed.money("0.90"), for: "USD", updatedAt: Fixed.day(2026, 1, 1))
        table.applyAutomatic(["USD": Fixed.money("0.854774"), "GBP": Fixed.money("1.16727")], asOf: asOf)

        #expect(table.rate(for: "USD") == Fixed.money("0.90"))
        #expect(table.source(for: "USD") == .manual)
        // Not even the timestamp moves: "updated 1 Jan" is what the user did.
        #expect(table.rates["USD"]?.updatedAt == Fixed.day(2026, 1, 1))
        // The rest of the refresh still lands.
        #expect(table.rate(for: "GBP") == Fixed.money("1.16727"))
        #expect(table.source(for: "GBP") == .automatic)
    }

    @Test("Typing over a downloaded rate makes it manual")
    func typingClaimsTheRate() {
        var table = RateTable(base: "EUR")
        table.applyAutomatic(["USD": Fixed.money("0.854774")], asOf: asOf)
        table.setRate(Fixed.money("0.88"), for: "USD", updatedAt: Fixed.today)
        #expect(table.source(for: "USD") == .manual)

        table.applyAutomatic(["USD": Fixed.money("0.854774")], asOf: asOf)
        #expect(table.rate(for: "USD") == Fixed.money("0.88"))
    }

    @Test("A refresh stamps when it happened, even when every rate was manual")
    func stampsAsOf() {
        var table = RateTable(base: "EUR")
        #expect(table.automaticAsOf == nil)
        table.setRate(Fixed.money("0.90"), for: "USD", updatedAt: Fixed.today)
        table.applyAutomatic(["USD": Fixed.money("0.854774")], asOf: asOf)
        #expect(table.automaticAsOf == asOf)
    }

    /// Saturday morning: the newest fixing the ECB has is still Friday's, so the two
    /// stamps are two different days and the pane needs both.
    @Test("A refresh records the ECB day and the moment of the check separately")
    func stampsBothDates() {
        var table = RateTable(base: "EUR")
        #expect(table.lastCheckedAt == nil)

        let checkedAt = Fixed.today.addingTimeInterval(9 * 3600 + 12 * 60)
        table.applyAutomatic(["USD": Fixed.money("0.854774")], asOf: asOf, checkedAt: checkedAt)

        #expect(table.automaticAsOf == asOf)
        #expect(table.lastCheckedAt == checkedAt)
        // The rate itself is stamped with the publication day, not the check.
        #expect(table.rates["USD"]?.updatedAt == asOf)
    }

    @Test("Checking again over the weekend moves the check, not the ECB day")
    func checkMovesWithoutANewRate() {
        var table = RateTable(base: "EUR")
        let saturday = Fixed.today.addingTimeInterval(9 * 3600)
        let sunday = Fixed.day(2026, 8, 23).addingTimeInterval(9 * 3600)
        table.applyAutomatic(["USD": Fixed.money("0.854774")], asOf: asOf, checkedAt: saturday)
        // Same answer, a day later: nothing about the rates changed.
        table.applyAutomatic(["USD": Fixed.money("0.854774")], asOf: asOf, checkedAt: sunday)

        #expect(table.automaticAsOf == asOf)
        #expect(table.lastCheckedAt == sunday)
    }

    @Test("Without a clock, the publication day stands in for the check")
    func checkDefaultsToTheDay() {
        var table = RateTable(base: "EUR")
        table.applyAutomatic(["USD": Fixed.money("0.854774")], asOf: asOf)
        #expect(table.lastCheckedAt == asOf)
    }

    @Test("The base never gets a rate of its own")
    func baseIsSkipped() {
        var table = RateTable(base: "EUR")
        table.applyAutomatic(["EUR": Fixed.money("1.0")], asOf: asOf)
        #expect(table.rates["EUR"] == nil)
    }

    // MARK: What to ask for

    @Test("Every currency in use, minus the base, whether or not it has a rate")
    func currenciesNeedingRates() {
        let document = Fixed.document(
            [
                Fixed.subscription("Spotify Premium", currency: "USD"),
                Fixed.subscription("Netflix", currency: "EUR"),
                Fixed.subscription("Gym", currency: "gbp"),
                Fixed.subscription("Another dollar one", currency: "USD")
            ],
            rates: ["USD": Fixed.money("0.85")]
        )
        // USD is in the list despite already having a rate: a rate from last week is
        // still a rate to refresh.
        #expect(document.rates.currenciesNeedingRates(in: document) == ["GBP", "USD"])
    }

    @Test("An all-euro list asks for nothing")
    func nothingToAsk() {
        let document = Fixed.document([Fixed.subscription("Netflix", currency: "EUR")])
        #expect(document.rates.currenciesNeedingRates(in: document).isEmpty)
    }

    // MARK: Decoding

    @Test("A document written before automatic rates keeps its hand-typed ones")
    func olderDocumentDecodesAsManual() throws {
        let json = Data("""
        {"base":"EUR","rates":{"USD":{"value":0.9,"updatedAt":0}}}
        """.utf8)
        let table = try JSONDecoder().decode(RateTable.self, from: json)
        #expect(table.source(for: "USD") == .manual)
        #expect(table.automaticAsOf == nil)
        #expect(table.lastCheckedAt == nil)
    }

    @Test("A document written before checks were recorded decodes with no check")
    func documentWithoutLastCheckedDecodesNil() throws {
        let json = Data("""
        {"base":"EUR","rates":{"USD":{"value":0.854774,"updatedAt":0,"source":"automatic"}},"automaticAsOf":0}
        """.utf8)
        let table = try JSONDecoder().decode(RateTable.self, from: json)
        #expect(table.automaticAsOf == Date(timeIntervalSinceReferenceDate: 0))
        #expect(table.lastCheckedAt == nil)
    }

    @Test("Sources and the stamps survive a round trip")
    func roundTrips() throws {
        var table = RateTable(base: "EUR")
        let checkedAt = Fixed.today.addingTimeInterval(9 * 3600 + 12 * 60)
        table.setRate(Fixed.money("0.90"), for: "USD", updatedAt: Fixed.today)
        table.applyAutomatic(["GBP": Fixed.money("1.16727")], asOf: asOf, checkedAt: checkedAt)

        let decoded = try JSONDecoder().decode(RateTable.self, from: JSONEncoder().encode(table))
        #expect(decoded == table)
        #expect(decoded.source(for: "USD") == .manual)
        #expect(decoded.source(for: "GBP") == .automatic)
        #expect(decoded.automaticAsOf == asOf)
        #expect(decoded.lastCheckedAt == checkedAt)
    }
}

// MARK: - Deciding to ask

/// Whether a refresh is worth making. The weekend is the case that decides the shape of
/// this: the ECB publishes on working days, so a Saturday answer carries Friday's date,
/// and a throttle that reads that date asks again all weekend for the same numbers.
@Suite("Rate refresh policy")
struct RateRefreshPolicyTests {

    /// Friday 21 August 2026, the day the fixing was published.
    private let quotedOnFriday = Fixed.day(2026, 8, 21)
    /// Saturday morning, when the app last got an answer: Friday's numbers again.
    private let checkedSaturdayMorning = Fixed.day(2026, 8, 22).addingTimeInterval(9 * 3600)

    @Test("A check this morning holds off this evening, and lets go tomorrow morning")
    func weekendThrottleRunsOnTheCheck() {
        let saturdayEvening = Fixed.day(2026, 8, 22).addingTimeInterval(21 * 3600)
        #expect(!RateRefreshPolicy.shouldRefresh(
            lastCheckedAt: checkedSaturdayMorning,
            automaticAsOf: quotedOnFriday,
            now: saturdayEvening,
            force: false,
            hasCurrenciesNeedingRates: true
        ))

        // Sunday morning: a day since the last answer, though the quote is still
        // Friday's. Reading the quote date instead would have asked hours ago.
        let sundayMorning = Fixed.day(2026, 8, 23).addingTimeInterval(9 * 3600)
        #expect(RateRefreshPolicy.shouldRefresh(
            lastCheckedAt: checkedSaturdayMorning,
            automaticAsOf: quotedOnFriday,
            now: sundayMorning,
            force: false,
            hasCurrenciesNeedingRates: true
        ))
    }

    @Test("Never having asked is a reason to ask")
    func noCheckMeansAsk() {
        #expect(RateRefreshPolicy.shouldRefresh(
            lastCheckedAt: nil,
            automaticAsOf: nil,
            now: Fixed.today,
            force: false,
            hasCurrenciesNeedingRates: true
        ))
        // A document written before checks were recorded: rates in hand, no check.
        #expect(RateRefreshPolicy.shouldRefresh(
            lastCheckedAt: nil,
            automaticAsOf: quotedOnFriday,
            now: Fixed.today,
            force: false,
            hasCurrenciesNeedingRates: true
        ))
    }

    @Test("A forced refresh ignores the throttle")
    func forceBypassesTheThrottle() {
        let minutesLater = checkedSaturdayMorning.addingTimeInterval(120)
        #expect(RateRefreshPolicy.shouldRefresh(
            lastCheckedAt: checkedSaturdayMorning,
            automaticAsOf: quotedOnFriday,
            now: minutesLater,
            force: true,
            hasCurrenciesNeedingRates: true
        ))
    }

    @Test("An all-euro list is never worth a request, forced or not")
    func nothingToConvertMeansNoRequest() {
        for force in [false, true] {
            #expect(!RateRefreshPolicy.shouldRefresh(
                lastCheckedAt: nil,
                automaticAsOf: nil,
                now: Fixed.today,
                force: force,
                hasCurrenciesNeedingRates: false
            ))
        }
    }

    @Test("The interval is a parameter, so a caller can ask for a shorter one")
    func intervalIsInjectable() {
        let twoHoursLater = checkedSaturdayMorning.addingTimeInterval(2 * 3600)
        #expect(RateRefreshPolicy.shouldRefresh(
            lastCheckedAt: checkedSaturdayMorning,
            automaticAsOf: quotedOnFriday,
            now: twoHoursLater,
            force: false,
            hasCurrenciesNeedingRates: true,
            minimumInterval: 3600
        ))
        #expect(!RateRefreshPolicy.shouldRefresh(
            lastCheckedAt: checkedSaturdayMorning,
            automaticAsOf: quotedOnFriday,
            now: twoHoursLater,
            force: false,
            hasCurrenciesNeedingRates: true,
            minimumInterval: 3 * 3600
        ))
    }
}
