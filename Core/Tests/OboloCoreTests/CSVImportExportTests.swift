import Foundation
import Testing
@testable import OboloCore

/// Import and export, against both files the app has to handle: a Google Sheets export
/// and the app's own.
@Suite("CSV import and export")
struct CSVImportExportTests {

    private let calendar = Fixed.calendar

    // MARK: - Header matching

    @Test("Header aliases from the contract all resolve")
    func headerAliases() {
        #expect(CSVField.matching(header: "Name") == .name)
        #expect(CSVField.matching(header: "  BILLING   CYCLE ") == .cycle)
        #expect(CSVField.matching(header: "Cost") == .price)
        #expect(CSVField.matching(header: "Price") == .price)
        #expect(CSVField.matching(header: "Amount") == .price)
        #expect(CSVField.matching(header: "A payment date (past or future)") == .anchorDate)
        #expect(CSVField.matching(header: "Renews on") == .anchorDate)
        #expect(CSVField.matching(header: "Next payment") == .anchorDate)
        #expect(CSVField.matching(header: "Anchor date") == .anchorDate)
        #expect(CSVField.matching(header: "First payment") == .anchorDate)
        #expect(CSVField.anchorDate.exportHeader == "First payment")
        #expect(CSVField.matching(header: "Active") == .active)
        #expect(CSVField.matching(header: "Status") == .status)
        #expect(CSVField.matching(header: "Billing stopped on") == .billingStoppedOn)
        #expect(CSVField.matching(header: "Payment method") == .paymentMethod)
        #expect(CSVField.matching(header: "Reminder lead days") == .reminderLeadDays)
        #expect(CSVField.matching(header: "Website") == .website)
        #expect(CSVField.matching(header: "Domain") == .website)
        #expect(CSVField.matching(header: "URL") == .website)
        // "Manage URL" is still its own column, and still wins its own header.
        #expect(CSVField.matching(header: "Manage URL") == .manageURL)
        #expect(CSVField.matching(header: "Sparkle") == nil)
    }

    // MARK: - Value parsing

    @Test("Prices survive whatever separators and symbols a spreadsheet used")
    func priceParsing() {
        #expect(ValueParsing.decimal("13.99") == Fixed.money("13.99"))
        #expect(ValueParsing.decimal("€13,99") == Fixed.money("13.99"))
        #expect(ValueParsing.decimal("$ 10.99") == Fixed.money("10.99"))
        #expect(ValueParsing.decimal("1,234.56") == Fixed.money("1234.56"))
        #expect(ValueParsing.decimal("1.234,56") == Fixed.money("1234.56"))
        #expect(ValueParsing.decimal("1 234") == Fixed.money("1234"))
        #expect(ValueParsing.decimal("96") == Fixed.money("96"))
        #expect(ValueParsing.decimal("") == nil)
        #expect(ValueParsing.decimal("free") == nil)
    }

    @Test("Third-party CSV prices use each currency and the import locale")
    func threePlaceLocalizedPrices() throws {
        let csv = """
        Name,Price,Currency,Price history
        Localized,"€1.234",EUR,"2026-01-01=2,345 KWD;2026-02-01=1.000 EUR"
        Fraction,"1,234",KWD,2026-01-01=0.567
        Both,"1.234,567",KWD,
        """
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8), document: .initial(), calendar: calendar,
            locale: Locale(identifier: "it_IT"), now: Fixed.today
        )
        #expect(preview.rows.allSatisfy { $0.issues.isEmpty })
        let subscriptions = preview.rows.compactMap(\.subscription)
        #expect(subscriptions.map(\.price) == [Fixed.money("1234"), Fixed.money("1.234"), Fixed.money("1234.567")])
        #expect(subscriptions.first?.priceChanges.map(\.price) == [Fixed.money("2.345"), Fixed.money("1000")])
        #expect(subscriptions.dropFirst().first?.priceChanges.first?.price == Fixed.money("0.567"))
        #expect(subscriptions.dropFirst().first?.priceChanges.first?.currency == "KWD")
    }

    @Test("Dates are read as whole days in the injected calendar")
    func dateParsing() {
        #expect(ValueParsing.date("2026-08-24", calendar: calendar) == Fixed.day(2026, 8, 24))
        #expect(ValueParsing.date("2026/08/24", calendar: calendar) == Fixed.day(2026, 8, 24))
        #expect(ValueParsing.date("24 Aug 2026", calendar: calendar, locale: Fixed.locale) == Fixed.day(2026, 8, 24))
        #expect(ValueParsing.date("24/08/2026", calendar: calendar, locale: Fixed.locale) == Fixed.day(2026, 8, 24))
        #expect(ValueParsing.date("", calendar: calendar) == nil)
        #expect(ValueParsing.date("soon", calendar: calendar) == nil)
    }

    @Test("A day the calendar does not have is refused, not rolled forward")
    func impossibleISODays() {
        // `Calendar` answers a request for 31 February with 3 March, so the parser reads
        // its own result back before believing it.
        #expect(ISODay.parse("2026-02-31", calendar: calendar) == nil)
        #expect(ISODay.parse("2026-13-01", calendar: calendar) == nil)
        #expect(ISODay.parse("2025-02-29", calendar: calendar) == nil)
        #expect(ISODay.parse("2026-04-31", calendar: calendar) == nil)
        #expect(ISODay.parse("2026-08-00", calendar: calendar) == nil)
        #expect(ISODay.parse("26-08-21", calendar: calendar) == nil)
        #expect(ISODay.parse("2026-08", calendar: calendar) == nil)
        #expect(ISODay.parse("soon", calendar: calendar) == nil)

        // A leap day that exists is a leap day.
        #expect(ISODay.parse("2024-02-29", calendar: calendar) == Fixed.day(2024, 2, 29))
        #expect(ISODay.parse("2026-08-24", calendar: calendar) == Fixed.day(2026, 8, 24))

        // The importer refuses the same strings: a day-shaped cell is settled by the
        // parser above and never falls through to the tolerant patterns, which read a
        // hyphen as a separator and would roll 31 February into March.
        #expect(ValueParsing.date("2026-02-31", calendar: calendar, locale: Fixed.locale) == nil)
        #expect(ValueParsing.date("2026-13-01", calendar: calendar, locale: Fixed.locale) == nil)
        #expect(ValueParsing.date("2025-02-29", calendar: calendar, locale: Fixed.locale) == nil)
        #expect(ValueParsing.date("2024-02-29", calendar: calendar, locale: Fixed.locale) == Fixed.day(2024, 2, 29))
        // And the shapes that were always read still read.
        #expect(ValueParsing.date("2026-8-4", calendar: calendar, locale: Fixed.locale) == Fixed.day(2026, 8, 4))
        #expect(ValueParsing.date("2026-08-24", calendar: calendar, locale: Fixed.locale) == Fixed.day(2026, 8, 24))
    }

    @Test("Cycles are read from every spelling the contract lists")
    func cycleParsing() {
        #expect(BillingCycle(parsing: "Weekly") == .weekly)
        #expect(BillingCycle(parsing: "Monthly") == .monthly)
        #expect(BillingCycle(parsing: "Quarterly") == .quarterly)
        #expect(BillingCycle(parsing: "Yearly") == .yearly)
        #expect(BillingCycle(parsing: "Every 2 years") == .everyTwoYears)
        #expect(BillingCycle(parsing: "every 4 months") == .custom(months: 4))
        #expect(BillingCycle(parsing: "Every 3 months") == .quarterly)
        #expect(BillingCycle(parsing: "annual") == .yearly)
        #expect(BillingCycle(parsing: "custom:6") == .custom(months: 6))
        #expect(BillingCycle(parsing: "whenever") == nil)
    }

    // MARK: - An anonymised Google Sheets export

    @Test("The Google Sheets export imports as ten rows, one of them flagged")
    func importsTheSheetExport() throws {
        let preview = try CSVImporter.preview(
            data: try Fixed.fixtureData("sheet-export-sample.csv"),
            document: .initial(),
            calendar: calendar,
            locale: Fixed.locale
        )

        #expect(preview.rows.count == 10)
        #expect(preview.importableCount == 10)
        #expect(preview.errorCount == 0)
        #expect(preview.rows.count { $0.severity == .warning } == 1)
        // Every column in that file is one the importer knows.
        #expect(preview.unmatchedColumns.isEmpty)
        // Its categories are all seeded ones, so nothing new is needed.
        #expect(preview.newCategoryNames.isEmpty)
    }

    @Test("The Website column lands as a bare domain")
    func websiteColumnImports() throws {
        let preview = try CSVImporter.preview(
            data: try Fixed.fixtureData("sheet-export-sample.csv"),
            document: .initial(), calendar: calendar, locale: Fixed.locale
        )
        let byName = Dictionary(
            preview.rows.compactMap(\.subscription).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(byName["Netflix"]?.website == "netflix.com")
        #expect(byName["Notion Plus"]?.website == "notion.so")
        #expect(byName["Netflix"]?.effectiveDomain == "netflix.com")
        // Nine of the ten rows name their service, so a "fetch the missing ones" pass has
        // something to work with for all but the cancelled one, whose cell is empty.
        #expect(preview.rows.compactMap(\.subscription).filter { $0.effectiveDomain != nil }.count == 9)
        #expect(byName["Disney+"]?.website == nil)
    }

    @Test("A note containing a comma stays one field")
    func quotedNotesSurvive() throws {
        let preview = try CSVImporter.preview(
            data: try Fixed.fixtureData("sheet-export-sample.csv"),
            document: .initial(), calendar: calendar, locale: Fixed.locale
        )
        let spotify = preview.rows.compactMap(\.subscription).first { $0.name == "Spotify Premium" }!
        #expect(spotify.notes == "Billed in USD")
        #expect(spotify.currency == "USD")
        #expect(spotify.price == Fixed.money("10.99"))
        #expect(spotify.cycle == .monthly)
        #expect(spotify.anchorDate == Fixed.billingDay(2026, 8, 25))
        #expect(spotify.paymentMethod == "PayPal")
    }

    @Test("An empty date column imports as no date, which is a supported state and not an error")
    func emptyDateImportsAsNoDate() throws {
        let preview = try CSVImporter.preview(
            data: try Fixed.fixtureData("sheet-export-sample.csv"),
            document: .initial(), calendar: calendar, locale: Fixed.locale
        )
        let row = preview.rows.first { $0.subscription?.name == "Adobe Creative Cloud" }!
        #expect(row.subscription?.anchorDate == nil)
        #expect(row.subscription?.price == Fixed.money("65.49"))
        #expect(row.issues.isEmpty)
        #expect(row.isImportable)
    }

    @Test("An empty cost with Active=No imports as cancelled at zero, warned about but not refused")
    func cancelledRowWithNoPrice() throws {
        let preview = try CSVImporter.preview(
            data: try Fixed.fixtureData("sheet-export-sample.csv"),
            document: .initial(), calendar: calendar, locale: Fixed.locale
        )
        let row = preview.rows.first { $0.subscription?.name == "Disney+" }!
        let subscription = row.subscription!

        #expect(subscription.price == 0)
        #expect(subscription.status == .cancelled)
        // The date column is the only place the sheet can say when access stops.
        #expect(subscription.endsOn == Fixed.billingDay(2026, 9, 5))
        #expect(row.severity == .warning)
        #expect(row.isImportable)
        #expect(row.issues.map(\.message) == ["The row has no price. Obolo imported 0."])
    }

    @Test("Applying the sheet export gives nine active and one cancelled")
    func applyingTheSheetExport() throws {
        var document = StoreDocument.initial()
        let preview = try CSVImporter.preview(
            data: try Fixed.fixtureData("sheet-export-sample.csv"),
            document: document, calendar: calendar, locale: Fixed.locale
        )
        let result = CSVImporter.apply(preview, to: &document, createMissingCategories: true)

        #expect(result.inserted == 10)
        #expect(result.updated == 0)
        #expect(result.skipped == 0)
        #expect(result.createdCategories.isEmpty)

        let ledger = Ledger(document: document, today: Fixed.today, calendar: calendar)
        #expect(ledger.activeCount == 9)
        #expect(ledger.filtered(search: "", section: .pausedCancelled).count == 1)
        #expect(ledger.summaries.count == 10)
    }

    @Test("With the USD rate entered, the sheet export reconciles to €129.41 a month")
    func theSheetExportReconciles() throws {
        var document = StoreDocument.initial()
        document.rates.setRate(SampleData.usdRate, for: "USD", updatedAt: Fixed.today)
        let preview = try CSVImporter.preview(
            data: try Fixed.fixtureData("sheet-export-sample.csv"),
            document: document, calendar: calendar, locale: Fixed.locale
        )
        CSVImporter.apply(preview, to: &document, createMissingCategories: true)

        let ledger = Ledger(document: document, today: Fixed.today, calendar: calendar)
        #expect(ledger.monthlyTotal == Fixed.money("129.41"))
        #expect(ledger.yearlyTotal == Fixed.money("1552.92"))
        #expect(ledger.missingRateCount == 0)
        // Only the undated item needs attention — nothing in that file is flagged as an
        // estimate yet, which is a thing the user ticks in the app.
        #expect(ledger.needsAttention.map(\.name) == ["Adobe Creative Cloud"])
    }

    @Test("Re-importing the same file updates in place rather than duplicating")
    func reimportIsIdempotent() throws {
        var document = StoreDocument.initial()
        let data = try Fixed.fixtureData("sheet-export-sample.csv")
        CSVImporter.apply(try CSVImporter.preview(data: data, document: document, calendar: calendar, locale: Fixed.locale),
                          to: &document, createMissingCategories: true)
        #expect(document.subscriptions.count == 10)

        // A Google Sheets export carries no IDs, so a second import of it is a second
        // set of rows — that is honest, and the app asks before applying.
        CSVImporter.apply(try CSVImporter.preview(data: data, document: document, calendar: calendar, locale: Fixed.locale),
                          to: &document, createMissingCategories: true)
        #expect(document.subscriptions.count == 20)

        // The app's own export does carry IDs, and re-importing it updates in place.
        var target = StoreDocument.initial()
        let exported = CSVExporter.export(SampleData.handoff())
        CSVImporter.apply(try CSVImporter.preview(data: exported, document: target, calendar: calendar, locale: Fixed.locale),
                          to: &target, createMissingCategories: true)
        let second = CSVImporter.apply(
            try CSVImporter.preview(data: exported, document: target, calendar: calendar, locale: Fixed.locale),
            to: &target, createMissingCategories: true
        )
        #expect(target.subscriptions.count == 11)
        #expect(second.updated == 11)
        #expect(second.inserted == 0)
    }

    @Test("A repeated ID in the same import updates the first row in place")
    func repeatedIDWithinFile() throws {
        let id = UUID()
        let csv = """
        ID,Name,Price
        \(id),First,1
        ,Other,2
        \(id),Revised,3
        """
        var document = StoreDocument.initial()
        let preview = try CSVImporter.preview(data: Data(csv.utf8), document: document)
        let result = CSVImporter.apply(preview, to: &document, createMissingCategories: true)
        #expect(result.inserted == 2)
        #expect(result.updated == 1)
        #expect(document.subscriptions.map(\.name) == ["Revised", "Other"])
        #expect(document.subscriptions.first?.id == id)
    }

    // MARK: - Round trip

    @Test("Export then import returns every subscription unchanged")
    func roundTrip() throws {
        let original = SampleData.handoff()
        let data = CSVExporter.export(original)

        var rebuilt = StoreDocument.initial()
        let preview = try CSVImporter.preview(data: data, document: rebuilt, calendar: calendar, locale: Fixed.locale)
        #expect(preview.errorCount == 0)
        #expect(preview.rows.count { $0.severity == .warning } == 0)
        CSVImporter.apply(preview, to: &rebuilt, createMissingCategories: true)

        #expect(rebuilt.subscriptions == original.subscriptions)
    }

    @Test("Export and import preserve fractions in prices and mixed-currency history")
    func fractionalPricesRoundTrip() throws {
        var kuwaiti = Fixed.subscription("Kuwaiti", price: "1.234", currency: "KWD")
        kuwaiti.priceChanges = [
            PriceChange(effectiveFrom: Fixed.billingDay(2026, 1, 1), price: Fixed.money("0.125"), currency: "EUR"),
            PriceChange(effectiveFrom: Fixed.billingDay(2026, 2, 1), price: Fixed.money("1.987"), currency: "BHD"),
        ]
        kuwaiti.currentPriceSince = Fixed.billingDay(2026, 3, 1)
        let imported = Fixed.subscription("Imported", price: "2.345", currency: "USD")
        let small = Fixed.subscription("Small", price: "1.23456789123", currency: "USD")
        let original = Fixed.document([kuwaiti, imported, small])
        let data = CSVExporter.export(original)

        for locale in [Locale(identifier: "en_US"), Locale(identifier: "it_IT")] {
            var rebuilt = StoreDocument.initial()
            let preview = try CSVImporter.preview(
                data: data, document: rebuilt, calendar: calendar, locale: locale, now: Fixed.today
            )
            #expect(preview.rows.allSatisfy { $0.issues.isEmpty })
            CSVImporter.apply(preview, to: &rebuilt, createMissingCategories: true)
            #expect(rebuilt.subscriptions == original.subscriptions)
        }
    }

    /// To rewrite the fixture after a deliberate format change, run
    /// `OBOLO_REGENERATE_FIXTURES=1 swift test --filter sampleFixtureIsCurrent` in `Core/`.
    /// Without that variable the test only compares.
    @Test("The checked-in sample fixture is what the exporter produces")
    func sampleFixtureIsCurrent() throws {
        let actual = CSVExporter.csv(SampleData.handoff())
        if ProcessInfo.processInfo.environment["OBOLO_REGENERATE_FIXTURES"] == "1" {
            try Data(actual.utf8).write(to: Fixed.fixtures.appendingPathComponent("sample.csv"), options: .atomic)
        }
        let expected = String(decoding: try Fixed.fixtureData("sample.csv"), as: UTF8.self)
        #expect(actual == expected)
    }

    @Test("The sample fixture imports back to the reconciling document")
    func sampleFixtureImports() throws {
        var document = StoreDocument.initial()
        document.rates.setRate(SampleData.usdRate, for: "USD", updatedAt: Fixed.today)
        let preview = try CSVImporter.preview(
            data: try Fixed.fixtureData("sample.csv"),
            document: document, calendar: calendar, locale: Fixed.locale
        )
        CSVImporter.apply(preview, to: &document, createMissingCategories: true)

        let ledger = Ledger(document: document, today: Fixed.today, calendar: calendar)
        #expect(ledger.monthlyTotal == Fixed.money("129.41"))
        #expect(ledger.activeCount == 9)
        let week = ledger.upcoming(within: Settings.paymentHighlightWindowDays)
        #expect(week.compactMap(\.chargeInBase).reduce(Decimal.zero, +) == Fixed.money("23.40"))
        #expect(ledger.needsAttention.count == 2)
    }

    // MARK: - Row-level failure

    @Test("A bad row is skipped and the rest of the file still imports")
    func rowErrorsDoNotAbortTheImport() throws {
        let csv = """
        Name,Cost,Currency,Billing cycle,Renews on,Category
        Good,10.00,EUR,Monthly,2026-09-01,Software
        ,5.00,EUR,Monthly,2026-09-01,Software
        Bad cycle,5.00,EUR,Fortnightly,2026-09-01,Software
        Bad price,ten euro,EUR,Monthly,2026-09-01,Software
        Also good,20.00,EUR,Yearly,2026-09-01,Software
        """
        var document = StoreDocument.initial()
        let preview = try CSVImporter.preview(data: Data(csv.utf8), document: document, calendar: calendar, locale: Fixed.locale)

        #expect(preview.rows.count == 5)
        #expect(preview.errorCount == 3)
        #expect(preview.importableCount == 2)

        let result = CSVImporter.apply(preview, to: &document, createMissingCategories: true)
        #expect(result.inserted == 2)
        #expect(result.skipped == 3)
        #expect(document.subscriptions.map(\.name) == ["Good", "Also good"])
    }

    @Test("Unknown categories are created when allowed and folded into Other when not")
    func missingCategories() throws {
        let csv = """
        Name,Cost,Currency,Billing cycle,Renews on,Category
        Thing,10.00,EUR,Monthly,2026-09-01,Woodworking
        """
        let data = Data(csv.utf8)

        var creating = StoreDocument.initial()
        let previewA = try CSVImporter.preview(data: data, document: creating, calendar: calendar, locale: Fixed.locale)
        #expect(previewA.newCategoryNames == ["Woodworking"])
        let result = CSVImporter.apply(previewA, to: &creating, createMissingCategories: true)
        #expect(result.createdCategories.map(\.name) == ["Woodworking"])
        #expect(creating.category(named: "Woodworking") != nil)
        #expect(creating.subscriptions[0].categoryID == creating.category(named: "Woodworking")!.id)

        var folding = StoreDocument.initial()
        let previewB = try CSVImporter.preview(data: data, document: folding, calendar: calendar, locale: Fixed.locale)
        CSVImporter.apply(previewB, to: &folding, createMissingCategories: false)
        // Never dropped: a category is not worth losing a subscription over.
        #expect(folding.subscriptions.count == 1)
        #expect(folding.subscriptions[0].categoryID == folding.fallbackCategoryID)
    }

    @Test("Columns nobody claims are reported rather than silently ignored")
    func unmatchedColumnsAreReported() throws {
        let csv = """
        Name,Cost,Sparkle,Vibe
        Thing,10.00,yes,good
        """
        let preview = try CSVImporter.preview(data: Data(csv.utf8), document: .initial(), calendar: calendar, locale: Fixed.locale)
        #expect(preview.unmatchedColumns == ["Sparkle", "Vibe"])
        #expect(preview.importableCount == 1)
    }

    @Test("A file that is not a subscription list is refused outright")
    func unusableFilesThrow() {
        #expect(throws: CSVImportError.empty) {
            try CSVImporter.preview(data: Data(), document: .initial())
        }
        #expect(throws: CSVImportError.noNameColumn(headers: ["Colour", "Shape"])) {
            try CSVImporter.preview(data: Data("Colour,Shape\nred,round\n".utf8), document: .initial())
        }
        // A header with no rows under it is not an import either.
        #expect(throws: CSVImportError.empty) {
            try CSVImporter.preview(data: Data("Name,Cost\n".utf8), document: .initial())
        }
    }

    @Test("A shipping CSV with a name column is refused")
    func shippingFileIsRefused() {
        let csv = """
        DATE TIME (UTC),MMSI,LATITUDE,LONGITUDE,COURSE,SPEED,HEADING,NAVSTAT,IMO,NAME,CALLSIGN,AISTYPE,A,B,C,D,DRAUGHT,DESTINATION,ETA
        2026-10-01 12:00:00,000000000,0,0,0,0,0,0,0,Test Vessel,,0,0,0,0,0,0,Test Port,
        """
        #expect(throws: CSVImportError.noBillingColumn) {
            try CSVImporter.preview(data: Data(csv.utf8), document: .initial())
        }
    }

    @Test("A sparse subscription CSV can identify its name and billing cycle with aliases")
    func billingCycleAliasIsEnough() throws {
        let csv = "\u{FEFF}\r\n\" Service \",\"FREQUENCY\",Notes\r\nLibrary,Yearly,\"Line one, continued\r\nLine two\""
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8), document: .initial(), calendar: calendar, locale: Fixed.locale
        )

        let row = try #require(preview.rows.first)
        #expect(preview.importableCount == 1)
        #expect(row.subscription?.name == "Library")
        #expect(row.subscription?.cycle == .yearly)
        #expect(row.subscription?.price == .zero)
        #expect(row.subscription?.notes == "Line one, continued\nLine two")
    }

    @Test("Status wins over Active where a file carries both")
    func statusBeatsActive() throws {
        let csv = """
        Name,Cost,Currency,Billing cycle,Status,Active
        Paused thing,10.00,EUR,Monthly,paused,No
        Trial thing,10.00,EUR,Monthly,trial,Yes
        """
        let preview = try CSVImporter.preview(data: Data(csv.utf8), document: .initial(), calendar: calendar, locale: Fixed.locale)
        let statuses = preview.rows.compactMap(\.subscription).map(\.status)
        // Pause is gone: a paused row imports as cancelled.
        #expect(statuses == [.cancelled, .trial])
    }

    @Test("A blank status warns and uses the Active column")
    func blankStatusWarns() throws {
        let csv = """
        Name,Cost,Currency,Billing cycle,Status,Active
        Paused thing,10.00,EUR,Monthly,,No
        """
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8),
            document: .initial(),
            calendar: calendar,
            locale: Fixed.locale,
            now: Fixed.today
        )
        let row = try #require(preview.rows.first)

        #expect(row.subscription?.status == .cancelled)
        // The file says nothing about when billing stopped, and today is not the answer.
        #expect(row.subscription?.billingStoppedOn == nil)
        #expect(row.severity == .warning)
    }

    // MARK: - Billing stop dates
    //
    // An import invents nothing here. "We do not know when this stopped" is a real
    // answer, and stamping today over it would hand the user years of charges they
    // never made on exactly the rows they are least able to check.

    @Test("A file written before the billing stop column existed leaves the date unknown")
    func oldExportLeavesTheStopDateUnknown() throws {
        let csv = """
        Name,Cost,Currency,Billing cycle,Status,First payment
        Old plan,10.00,EUR,Monthly,cancelled,2019-06-05
        """
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8), document: .initial(), calendar: calendar,
            locale: Fixed.locale, now: Fixed.today
        )
        let subscription = try #require(preview.rows.first?.subscription)

        #expect(subscription.status == .cancelled)
        #expect(subscription.billingStoppedOn == nil)
        #expect(preview.rows.count { $0.severity == .warning } == 0)
    }

    @Test("An end date that has been reached answers for the stop date, a future one does not")
    func endDateAnswersForTheStopDateOnlyOnceReached() throws {
        let csv = """
        Name,Cost,Currency,Billing cycle,Status,Ends on
        Ended plan,10.00,EUR,Monthly,cancelled,2026-03-04
        Ending plan,10.00,EUR,Monthly,cancelled,2026-09-30
        """
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8), document: .initial(), calendar: calendar,
            locale: Fixed.locale, now: Fixed.today
        )
        let byName = Dictionary(
            preview.rows.compactMap(\.subscription).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Billing had stopped by the day access ran out.
        #expect(byName["Ended plan"]?.billingStoppedOn == Fixed.billingDay(2026, 3, 4))
        // Access has not run out yet, so the row says nothing about a stop date.
        #expect(byName["Ending plan"]?.billingStoppedOn == nil)
    }

    @Test("An unreadable billing stop date warns and leaves the date unknown")
    func unreadableStopDateWarns() throws {
        let csv = """
        Name,Cost,Currency,Billing cycle,Status,Billing stopped on
        Mystery plan,10.00,EUR,Monthly,cancelled,sometime last year
        """
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8), document: .initial(), calendar: calendar,
            locale: Fixed.locale, now: Fixed.today
        )
        let row = try #require(preview.rows.first)

        #expect(row.subscription?.billingStoppedOn == nil)
        #expect(row.severity == .warning)
        #expect(row.issues.map(\.message) == [
            "Obolo cannot read the billing stop date “sometime last year”. The billing stop date is unknown."
        ])
        #expect(row.isImportable)
    }

    @Test("A future billing stop date warns and is ignored")
    func futureStopDateWarns() throws {
        let csv = """
        Name,Cost,Currency,Billing cycle,Status,Billing stopped on
        Future plan,10.00,EUR,Monthly,cancelled,2026-09-30
        """
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8), document: .initial(), calendar: calendar,
            locale: Fixed.locale, now: Fixed.today
        )
        let row = try #require(preview.rows.first)

        #expect(row.subscription?.billingStoppedOn == nil)
        #expect(row.severity == .warning)
        #expect(row.issues.map(\.message) == [
            "The billing stop date “2026-09-30” is after today. Obolo ignored it."
        ])
        #expect(row.isImportable)
    }

    @Test("A negative price is an import error")
    func negativePriceIsRejected() throws {
        let csv = """
        Name,Cost,Currency,Billing cycle
        Credit,-10.00,EUR,Monthly
        """
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8), document: .initial(), calendar: calendar, locale: Fixed.locale
        )

        #expect(preview.errorCount == 1)
        #expect(preview.importableCount == 0)
    }

    @Test("Export protects formulas and import restores the text")
    func protectsSpreadsheetFormulas() throws {
        let subscription = Subscription(
            name: "=2+2",
            categoryID: Category.unknown.id,
            price: 10,
            currency: "EUR",
            cycle: .monthly,
            notes: "+RUN()"
        )
        let data = CSVExporter.export(Fixed.document([subscription]))
        let table = CSVParser.parse(data)
        let nameIndex = try #require(table.first?.firstIndex(of: "Name"))
        let notesIndex = try #require(table.first?.firstIndex(of: "Notes"))

        #expect(table[1][nameIndex] == "'=2+2")
        #expect(table[1][notesIndex] == "'+RUN()")

        let preview = try CSVImporter.preview(
            data: data, document: .initial(), calendar: calendar, locale: Fixed.locale
        )
        #expect(preview.rows.first?.subscription?.name == "=2+2")
        #expect(preview.rows.first?.subscription?.notes == "+RUN()")
    }
}
