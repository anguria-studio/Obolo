import Foundation
import OboloCore
import Testing

@MainActor
@Suite("Window frame")
struct WindowChromeTests {
    @Test("The switch keeps All lit for every list section")
    func switchMapsSections() {
        #expect(WindowSection(.overview) == .home)
        #expect(WindowSection(.calendar) == .calendar)
        #expect(WindowSection(.all) == .all)
        #expect(WindowSection(.upcoming) == .all)
        #expect(WindowSection(.attention) == .all)
        #expect(WindowSection(.pausedCancelled) == .all)
        #expect(WindowSection(.category(UUID())) == .all)
        #expect(WindowSection.allCases.map(\.section) == [.overview, .calendar, .all])
    }

    @Test("Each Home chart builds once per window")
    func buildLogOncePerWindow() {
        let log = HomeBuildLog()
        #expect(!log.hasPlayed(.category))
        #expect(log.claim(.category))
        #expect(log.hasPlayed(.category))
        #expect(!log.claim(.category))
        #expect(log.claim(.months))
        // A reopened window has a new log, so everything builds again.
        #expect(HomeBuildLog().claim(.category))
    }

    @Test("The All pills: active is billing only, due soon is a week, inactive is cancelled")
    func allFilters() {
        let fixture = WindowFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        var soon = fixture.subscription(name: "Soon")          // due 28 Aug, in 3 days
        soon.anchorDate = BillingDay(isoDate: "2026-08-28")!
        let later = fixture.subscription(name: "Later")        // due 3 Sep, in 9 days
        var cancelled = fixture.subscription(name: "Cancelled")
        cancelled.status = .cancelled
        for subscription in [soon, later, cancelled] { model.add(subscription) }
        model.section = OboloCore.Section.all

        func names(_ filter: AllFilter) -> Set<String> { Set(model.allRows(scope: AllScope(pill: filter)).map(\.name)) }
        #expect(names(.active) == ["Soon", "Later"])
        #expect(names(.dueSoon) == ["Soon"])
        #expect(names(.inactive) == ["Cancelled"])

        // Another section ignores the pill.
        model.section = OboloCore.Section.pausedCancelled
        #expect(names(.dueSoon) == ["Cancelled"])
    }

    @Test("A category narrows whichever pill is on")
    func allCategory() {
        let fixture = WindowFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let categories = model.document.categories.map(\.id)
        try? #require(categories.count >= 2)

        var music = fixture.subscription(name: "Music")
        music.categoryID = categories[0]
        var other = fixture.subscription(name: "Other")
        other.categoryID = categories[1]
        var gone = fixture.subscription(name: "Gone")
        gone.categoryID = categories[0]
        gone.status = .cancelled
        for subscription in [music, other, gone] { model.add(subscription) }
        model.section = OboloCore.Section.all

        func names(_ scope: AllScope) -> Set<String> { Set(model.allRows(scope: scope).map(\.name)) }
        #expect(names(AllScope(category: categories[0])) == ["Music"])
        #expect(names(AllScope(pill: .inactive, category: categories[0])) == ["Gone"])
        #expect(model.activeCount(in: categories[0]) == 1)
    }

    @Test("Needs attention: no date or no rate on an active subscription; never an estimate or cancelled")
    func attentionIssues() {
        let fixture = WindowFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        var undated = fixture.subscription(name: "Undated")
        undated.anchorDate = nil
        var estimate = fixture.subscription(name: "Estimate")
        estimate.isEstimate = true
        var cancelledUndated = fixture.subscription(name: "Cancelled")
        cancelledUndated.anchorDate = nil
        cancelledUndated.status = .cancelled
        for subscription in [undated, estimate, cancelledUndated] { model.add(subscription) }

        #expect(model.issueRows.map(\.name) == ["Undated"])
        #expect(model.issueRows.first?.issue == .noDate)
        #expect(model.fixableCount == 1)
        #expect(AttentionIssue.missingRate(currency: "USD").reason == "No USD exchange rate")
    }

    @Test("The now halo breathes once per 3.6 s: full at 25%, gone by 55%, then rests")
    func nowHaloBreath() {
        #expect(NowHalo.breath(at: 0) == 0)
        #expect(abs(NowHalo.breath(at: 0.45) - 0.5) < 0.001)
        #expect(abs(NowHalo.breath(at: 0.9) - 1) < 0.001)
        #expect(NowHalo.breath(at: 1.98) < 0.001)
        #expect(NowHalo.breath(at: 3.0) == 0)
        #expect(abs(NowHalo.breath(at: 3.6 + 0.9) - 1) < 0.001)
    }

    @Test("The tick strip fills once per month shown: again when the month changes, not when Home comes back")
    func tickStripReplaysPerMonth() {
        let log = HomeBuildLog()
        let november = Date(timeIntervalSinceReferenceDate: 0)
        let december = Date(timeIntervalSinceReferenceDate: 86_400 * 31)
        #expect(log.claimTicks(for: november))
        #expect(log.hasFilledTicks(for: november))
        #expect(!log.claimTicks(for: november))
        #expect(log.claimTicks(for: december))
        #expect(!log.hasFilledTicks(for: november))
        #expect(log.claimTicks(for: november))
    }

    @Test("Search matches names in any case, across active and inactive alike")
    func searchAcrossPills() {
        let fixture = WindowFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        var cancelled = fixture.subscription(name: "Cloud Archive")
        cancelled.status = .cancelled
        for subscription in [fixture.subscription(name: "Cloud storage"), fixture.subscription(name: "Music"), cancelled] {
            model.add(subscription)
        }
        #expect(Set(model.searchRows("cLoUd").map(\.name)) == ["Cloud storage", "Cloud Archive"])
        #expect(model.searchRows("zzz").isEmpty)
        #expect(AllSearch(isOpen: true, query: "  ").isActive == false)
        #expect(AllSearch(isOpen: true, query: "m").isActive)
    }

    @Test("All and search share the current order after a sort, rate change, or edit")
    func allOrderingUpdates() {
        let fixture = WindowFixture()
        defer { fixture.remove() }
        var document = fixture.document
        document.settings.autoUpdateRates = false
        let drive = fixture.subscription(name: "Cloud Drive")
        var storage = fixture.subscription(name: "Cloud Storage")
        storage.currency = "USD"
        var archive = fixture.subscription(name: "Cloud Archive")
        archive.status = .cancelled
        document.subscriptions = [drive, storage, archive]
        let model = fixture.makeModel(document: document)
        model.section = .all

        model.applySort(.name, ascending: true)
        #expect(model.allRows(scope: AllScope()).map(\.id) == [drive.id, storage.id])
        #expect(model.searchRows(" cLoUd\n").map(\.id) == [archive.id, drive.id, storage.id])

        model.applySort(.name, ascending: false)
        #expect(model.allRows(scope: AllScope()).map(\.id) == [storage.id, drive.id])
        #expect(model.searchRows("cloud").map(\.id) == [storage.id, drive.id, archive.id])

        model.applySort(.monthly, ascending: false)
        #expect(model.allRows(scope: AllScope()).map(\.id) == [drive.id, storage.id])
        var rates = document.rates
        rates.setRate(2, for: "USD", updatedAt: fixture.now)
        model.updateRates(rates)
        #expect(model.allRows(scope: AllScope()).map(\.id) == [storage.id, drive.id])
        #expect(model.searchRows("cloud").map(\.id) == [storage.id, drive.id, archive.id])

        storage.name = "Offsite Storage"
        model.update(storage)
        #expect(model.searchRows("cloud").map(\.id) == [drive.id, archive.id])
        model.section = .pausedCancelled
        #expect(model.allRows(scope: AllScope(pill: .dueSoon)).map(\.id) == [archive.id])
        #expect(model.searchRows("storage").map(\.id) == [storage.id])
    }

    @Test("A selected row replaces the list panel, and back returns to the list")
    func listDetail() {
        let fixture = WindowFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let subscription = fixture.subscription(name: "Cloud storage")
        model.add(subscription)
        model.section = OboloCore.Section.all

        #expect(!model.isShowingSubscriptionDetail)
        model.selectSubscriptionRow(subscription.id)
        #expect(model.isShowingSubscriptionDetail)

        model.closeSubscriptionDetail()
        #expect(!model.isShowingSubscriptionDetail)
        #expect(model.selectedID == nil)
        #expect(model.section == OboloCore.Section.all)
    }

    @Test("Picking a calendar day does not leave the calendar")
    func calendarDayStaysOnGrid() {
        let fixture = WindowFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.section = OboloCore.Section.calendar

        model.selectCalendarDay(fixture.day(2026, 8, 22))
        #expect(model.selectedCalendarDay != nil)
        #expect(!model.isShowingSubscriptionDetail)
    }

    @Test("Switching from a list detail to Home clears the subscription selection")
    func switchingToHomeClosesListDetail() {
        let fixture = WindowFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let subscription = fixture.subscription(name: "Cloud storage")
        model.add(subscription)
        model.section = OboloCore.Section.all
        model.selectSubscriptionRow(subscription.id)
        #expect(model.isShowingSubscriptionDetail)

        model.section = OboloCore.Section.overview
        #expect(!model.isShowingSubscriptionDetail)
        #expect(model.selectedID == nil)
    }
}

/// A model over a scratch store, pinned to 25 Aug 2026.
@MainActor
private final class WindowFixture {
    let calendar: Calendar
    let now: Date
    let directory: URL
    let document = StoreDocument.initial()

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25))!
        directory = FileManager.default.temporaryDirectory
            .appending(path: "OboloWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func makeModel(document: StoreDocument? = nil) -> AppModel {
        AppModel(
            store: DocumentStore(url: directory.appending(path: "obolo.json")),
            deviceStateStore: DeviceStateStore(url: directory.appending(path: DeviceStateStore.fileName)),
            document: document ?? self.document,
            calendar: calendar,
            clock: { [now] in now },
            rateService: RateService(),
            cloudSyncService: DisabledCloudSyncService(),
            autoload: false
        )
    }

    func subscription(name: String) -> Subscription {
        Subscription(
            name: name,
            categoryID: document.fallbackCategoryID,
            price: Decimal(string: "12.99")!,
            currency: "EUR",
            cycle: .monthly,
            anchorDate: BillingDay(isoDate: "2026-09-03")!,
            createdAt: now
        )
    }

    func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
