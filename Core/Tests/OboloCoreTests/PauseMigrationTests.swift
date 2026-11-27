import Foundation
import Testing
@testable import OboloCore

/// Pause is gone from the app. A stored paused subscription still
/// decodes, as `.paused`, and `resolvingLegacyPause(today:calendar:)` turns it into a
/// cancelled one where data comes in: the store, a backup and an iCloud merge.
@Suite("Pause migration")
struct PauseMigrationTests {

    /// A row in the shape older builds wrote it.
    private func roundTrip(_ subscription: Subscription) throws -> Subscription {
        let data = try JSONEncoder().encode(subscription)
        #expect(String(decoding: data, as: UTF8.self).contains("\"paused\""))
        return try JSONDecoder().decode(Subscription.self, from: data)
    }

    @Test("The decoder keeps a stored paused status and reads no clock")
    func decoderKeepsPaused() throws {
        let paused = Fixed.subscription("Gym", anchor: Fixed.day(2026, 3, 10), status: .paused)
        let read = try roundTrip(paused)
        #expect(read.status == .paused)
        #expect(read.endsOn == nil)
        #expect(read.billingStoppedOn == nil)
    }

    @Test("A paused subscription becomes cancelled, ending the day it was paused")
    func pausedWithStopDate() throws {
        let stopped = Fixed.billingDay(2026, 8, 1)
        let paused = try roundTrip(Fixed.subscription(
            "Audiobooks", price: "9.95", anchor: Fixed.day(2026, 5, 12),
            status: .paused, billingStoppedOn: stopped
        ))
        let read = paused.resolvingLegacyPause(today: Fixed.today, calendar: Fixed.calendar)
        #expect(read.status == .cancelled)
        #expect(read.endsOn == stopped)
        #expect(read.billingStoppedOn == stopped)
    }

    @Test("Without a pause date it ends and stops on its last payment before today")
    func pausedWithoutStopDate() throws {
        let paused = try roundTrip(Fixed.subscription(
            "Gym", price: "30", anchor: Fixed.day(2026, 3, 10), status: .paused
        ))
        let read = paused.resolvingLegacyPause(today: Fixed.today, calendar: Fixed.calendar)
        #expect(read.status == .cancelled)
        // Today is 22 August, so the last monthly payment was on 10 August.
        #expect(read.endsOn == Fixed.billingDay(2026, 8, 10))
        #expect(read.billingStoppedOn == Fixed.billingDay(2026, 8, 10))
    }

    @Test("The last payment follows the injected day, not the system clock")
    func lastPaymentUsesInjectedToday() {
        let paused = Fixed.subscription("Gym", anchor: Fixed.day(2026, 3, 10), status: .paused)
        let early = paused.resolvingLegacyPause(today: Fixed.day(2026, 4, 1), calendar: Fixed.calendar)
        #expect(early.endsOn == Fixed.billingDay(2026, 3, 10))
        // A payment due today has not been made yet.
        let onTheDay = paused.resolvingLegacyPause(today: Fixed.day(2026, 4, 10), calendar: Fixed.calendar)
        #expect(onTheDay.endsOn == Fixed.billingDay(2026, 3, 10))
    }

    @Test("A paused row before its first payment has no invented end or stop date")
    func pausedBeforeFirstPayment() {
        let paused = Fixed.subscription("Later", anchor: Fixed.day(2026, 9, 1), status: .paused)
        let read = paused.resolvingLegacyPause(today: Fixed.today, calendar: Fixed.calendar)
        #expect(read.status == .cancelled)
        #expect(read.endsOn == nil)
        #expect(read.billingStoppedOn == nil)
    }

    @Test("An end date that is still to come is kept and stops nothing yet")
    func pausedWithFutureEnd() {
        let ends = Fixed.billingDay(2026, 9, 30)
        let paused = Fixed.subscription(
            "Access left", anchor: Fixed.day(2026, 3, 10), status: .paused, endsOn: ends
        )
        let read = paused.resolvingLegacyPause(today: Fixed.today, calendar: Fixed.calendar)
        #expect(read.status == .cancelled)
        #expect(read.endsOn == ends)
        #expect(read.billingStoppedOn == nil)
    }

    @Test("Every other status passes through unchanged")
    func otherStatusesUnchanged() {
        for status in [Status.active, .trial, .cancelled] {
            let row = Fixed.subscription("Row", anchor: Fixed.day(2026, 3, 10), status: status)
            #expect(row.resolvingLegacyPause(today: Fixed.today, calendar: Fixed.calendar) == row)
        }
    }

    @Test("A paused record from iCloud merges as cancelled and goes back corrected")
    func remotePausedRecordIsConvertedAndUploaded() throws {
        let category = OboloCore.Category(
            id: OboloCore.Category.fallbackID,
            name: OboloCore.Category.fallbackName,
            tint: .gray,
            sortOrder: 0
        )
        let preferences = SyncedPreferences(
            baseCurrency: "EUR", dueSoonWindowDays: 7, defaultReminderLeadDays: 2
        )
        var row = Fixed.subscription("Gym", anchor: Fixed.day(2026, 3, 10), status: .paused)
        row.categoryID = category.id
        // The record as another Mac's older build wrote it, through the wire format.
        let wire = try JSONEncoder().encode(SyncedSubscription(row))
        let remoteRow = try JSONDecoder().decode(SyncedSubscription.self, from: wire)
        #expect(remoteRow.status == .paused)

        let empty = SyncedDocument(
            subscriptions: [], categories: [category], preferences: preferences, manualRates: [:]
        )
        var remote = empty
        remote.subscriptions = [remoteRow]

        let result = try SyncMerge.merge(
            base: empty, local: empty, remote: remote,
            today: Fixed.today, calendar: Fixed.calendar
        )

        let merged = try #require(result.document.subscriptions.first)
        #expect(merged.status == .cancelled)
        #expect(merged.endsOn == Fixed.billingDay(2026, 8, 10))
        #expect(merged.billingStoppedOn == Fixed.billingDay(2026, 8, 10))
        #expect(result.changesForRemoteStore.changes == [.save(.subscription(merged))])
        #expect(result.changesForLocalStore.changes == [.save(.subscription(merged))])

        // Once the corrected record is in iCloud, the next merge has nothing to send.
        var corrected = empty
        corrected.subscriptions = [merged]
        let next = try SyncMerge.merge(
            base: corrected, local: corrected, remote: corrected,
            today: Fixed.today, calendar: Fixed.calendar
        )
        #expect(next.changesForRemoteStore.changes.isEmpty)
    }

    @Test("Paused stays decodable; the CSV word imports as cancelled")
    func parsing() {
        #expect(Status(rawValue: "paused") == .paused)
        #expect(Status(parsing: "paused") == .cancelled)
        #expect(Status(parsing: "On hold") == .cancelled)
    }

    @Test("A paused status not yet converted reads as cancelled")
    func pausedLabel() {
        #expect(Status.paused.displayName == "Cancelled")
        #expect(Status.paused.displayName == Status.cancelled.displayName)
        #expect(Status.active.displayName == "Active")
        #expect(Status.trial.displayName == "Trial")
    }

    @Test("A paused row not yet converted exports as cancelled and not billing")
    func pausedExport() throws {
        let paused = Fixed.subscription("Gym", anchor: Fixed.day(2026, 3, 10), status: .paused)
        let table = CSVParser.parse(CSVExporter.csv(Fixed.document([paused])))
        let header = try #require(table.first)
        let row = try #require(table.dropFirst().first)
        let status = try #require(header.firstIndex(of: CSVField.status.exportHeader))
        let active = try #require(header.firstIndex(of: CSVField.active.exportHeader))
        #expect(row[status] == "cancelled")
        #expect(row[active] == "No")
    }
}
