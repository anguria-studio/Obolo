import Foundation
import Testing
@testable import OboloCore

struct BillingDayTests {
    private let sender = Self.calendar("Pacific/Kiritimati")
    private let recipient = Self.calendar("America/Los_Angeles")

    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func document() -> StoreDocument {
        func picked(_ year: Int, _ month: Int, _ day: Int) -> BillingDay {
            let date = sender.date(from: DateComponents(year: year, month: month, day: day))!
            return BillingDay(date, calendar: sender)
        }

        return StoreDocument(subscriptions: [
            Subscription(
                name: "Monthly on the 31st",
                categoryID: Category.fallbackID,
                price: 20,
                currency: "EUR",
                priceChanges: [
                    PriceChange(effectiveFrom: picked(2026, 1, 31), price: 10, currency: "EUR"),
                    PriceChange(effectiveFrom: picked(2026, 2, 28), price: 15, currency: "EUR")
                ],
                currentPriceSince: picked(2026, 3, 31),
                cycle: .monthly,
                anchorDate: picked(2026, 1, 31),
                status: .cancelled,
                billingStoppedOn: picked(2026, 4, 30),
                endsOn: picked(2026, 5, 31),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
    }

    @Test func backupAndSyncPreserveCalendarDaysAndCreationInstant() async throws {
        let original = document()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let senderStore = DocumentStore(url: directory.appending(path: "sender.json"))
        let backup = directory.appending(path: "backup.json")
        let recipientStore = DocumentStore(url: directory.appending(path: "recipient.json"))

        try await senderStore.save(original)
        try await senderStore.backup(to: backup)
        let restored = try await recipientStore.restore(from: backup)
        #expect(restored == original)
        #expect(try await recipientStore.load() == original)

        let backupJSON = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any])
        let storedRow = try #require((backupJSON["subscriptions"] as? [[String: Any]])?.first)
        try checkDayFields(storedRow)

        let projection = SyncedDocument(document: restored)
        let record = SyncRecord.subscription(try #require(projection.subscriptions.first))
        let recordData = try DocumentStore.makeEncoder().encode(record)
        let decodedRecord = try DocumentStore.makeDecoder().decode(SyncRecord.self, from: recordData)
        let recordJSON = try #require(JSONSerialization.jsonObject(with: recordData) as? [String: Any])
        let recordCase = try #require(recordJSON["subscription"] as? [String: Any])
        let syncRow = try #require(recordCase["_0"] as? [String: Any])
        try checkDayFields(syncRow)
        #expect(decodedRecord == record)

        let received = SyncedDocument(document: .initial())
            .applying(SyncChangeSet(changes: [.save(decodedRecord)]))
            .applying(to: .initial())
        #expect(received.subscriptions == original.subscriptions)
        try checkSchedule(received)
    }

    @Test func csvRetainsCalendarDaysWhenImportedInAnotherTimeZone() throws {
        let original = document()
        let preview = try CSVImporter.preview(
            data: CSVExporter.export(original),
            document: .initial(),
            calendar: recipient,
            locale: Fixed.locale,
            now: date("2026-05-15", in: recipient)
        )
        #expect(preview.rows.first?.issues.isEmpty == true)
        var imported = StoreDocument.initial()
        CSVImporter.apply(preview, to: &imported, createMissingCategories: true)
        #expect(imported.subscriptions == original.subscriptions)
        try checkSchedule(imported)
    }

    @Test func historyRecordedTodaySurvivesSyncAndExportAcrossTheDateLine() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-03-31T10:30:00Z"))
        let recordedDay = BillingDay(instant, calendar: sender)
        #expect(recordedDay.isoDate == "2026-04-01")
        #expect(BillingDay(instant, calendar: recipient).isoDate == "2026-03-31")
        let history = [PriceChange(effectiveFrom: recordedDay, price: 20, currency: "EUR")]
        let original = StoreDocument(subscriptions: [Subscription(
            name: "April plan", categoryID: Category.fallbackID, price: 30, currency: "EUR",
            priceChanges: history, currentPriceSince: BillingDay(isoDate: "2026-04-15"),
            cycle: .monthly, anchorDate: recordedDay, createdAt: instant
        )])
        let base = SyncedDocument(document: .initial())
        let remote = SyncedDocument(document: original)
        for calendar in [sender, recipient] {
            let result = try SyncMerge.merge(base: base, local: base, remote: remote, today: instant, calendar: calendar)
            #expect(result.document == remote)
            #expect(result.changesForRemoteStore.changes.isEmpty)
            let preview = try CSVImporter.preview(
                data: CSVExporter.export(original), document: .initial(), calendar: calendar, locale: Fixed.locale, now: instant
            )
            let row = try #require(preview.rows.first)
            #expect(row.subscription?.priceChanges == history)
            #expect(row.issues.isEmpty)
        }
    }

    @Test func invalidCalendarDaysFailToDecode() throws {
        let decoder = DocumentStore.makeDecoder()
        #expect(throws: DecodingError.self) {
            try decoder.decode(BillingDay.self, from: Data(#""2026-02-29""#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(BillingDay.self, from: Data(#""2026-01-31T00:00:00Z""#.utf8))
        }
        let leapDay = try decoder.decode(BillingDay.self, from: Data(#""2028-02-29""#.utf8))
        #expect(leapDay.isoDate == "2028-02-29")
    }

    @Test func timestampInputKeepsItsWrittenBillingDayAndCreationInstant() throws {
        let timestamp = "2026-01-31T00:00:00+14:00"
        let csv = "Name,Price,First payment,Created at\nPlan,10,\(timestamp),\(timestamp)"
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8),
            document: .initial(),
            calendar: recipient,
            locale: Fixed.locale
        )
        let imported = try #require(preview.rows.first?.subscription)
        #expect(imported.anchorDate?.isoDate == "2026-01-31")
        #expect(imported.createdAt == ISO8601DateFormatter().date(from: "2026-01-30T10:00:00Z"))
    }

    private func checkDayFields(_ row: [String: Any]) throws {
        #expect(row["anchorDate"] as? String == "2026-01-31")
        #expect(row["currentPriceSince"] as? String == "2026-03-31")
        #expect(row["billingStoppedOn"] as? String == "2026-04-30")
        #expect(row["endsOn"] as? String == "2026-05-31")
        #expect(row["createdAt"] as? String == "2023-11-14T22:13:20Z")
        let changes = try #require(row["priceChanges"] as? [[String: Any]])
        #expect(changes.compactMap { $0["effectiveFrom"] as? String } == ["2026-01-31", "2026-02-28"])
    }

    private func checkSchedule(_ document: StoreDocument) throws {
        let subscription = try #require(document.subscriptions.first)
        for calendar in [sender, recipient] {
            let anchor = try #require(subscription.anchorDate).startOfDay(in: calendar)
            let calendarRule = RecurrencePlan.plan(for: subscription.cycle, anchor: anchor, calendar: calendar)
            #expect(calendarRule.daysOfTheMonth == [28, 29, 30, 31])
            #expect(calendarRule.setPositions == [-1])

            let today = date("2026-05-15", in: calendar)
            let ledger = Ledger(document: document, today: today, calendar: calendar)
            let summary = try #require(ledger.summary(id: subscription.id))
            let payments = ledger.payments(for: subscription.id)
            let expectedDays = ["2026-01-31", "2026-02-28", "2026-03-31"].map { date($0, in: calendar) }
            #expect(payments.map(\.date) == expectedDays)
            #expect(payments.map(\.price) == [10, 15, 20])
            #expect(summary.paidSoFar?.count == 3)
            #expect(summary.attention == .endsOn(date("2026-05-31", in: calendar)))
            #expect(subscription.price(on: date("2026-03-30", in: calendar), calendar: calendar).price == 15)
            #expect(subscription.price(on: date("2026-03-31", in: calendar), calendar: calendar).price == 20)
            let all = ledger.occurrences(from: date("2026-01-01", in: calendar), to: today)
            #expect(all.map(\.date) == expectedDays)

            var active = document
            active.subscriptions[0].status = .active
            let beforeClampedPayment = date("2026-02-27", in: calendar)
            let activeLedger = Ledger(document: active, today: beforeClampedPayment, calendar: calendar)
            #expect(activeLedger.summary(id: subscription.id)?.nextPayment == date("2026-02-28", in: calendar))
        }
    }

    private func date(_ text: String, in calendar: Calendar) -> Date {
        ISODay.parse(text, calendar: calendar)!
    }
}
