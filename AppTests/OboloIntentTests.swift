import AppIntents
import Foundation
import OboloCore
import Testing
import UserNotifications

@Suite("App Intents")
struct OboloIntentTests {
    @Test("Only window-opening shortcuts run in the foreground")
    func shortcutExecutionModes() {
        if #available(macOS 26.0, *) {
            #expect(ShowNextRenewalIntent.supportedModes == .background)
            #expect(OpenUpcomingSubscriptionsIntent.supportedModes == .foreground(.immediate))
            #expect(AddSubscriptionIntent.supportedModes == .foreground(.immediate))
        } else {
            #expect(!ShowNextRenewalIntent.openAppWhenRun)
            #expect(OpenUpcomingSubscriptionsIntent.openAppWhenRun)
            #expect(AddSubscriptionIntent.openAppWhenRun)
        }
    }

    @Test("The next renewal is the first active dated subscription")
    func findsNextRenewal() {
        let fixture = IntentFixture()
        var document = StoreDocument.initial()
        document.subscriptions = [
            fixture.subscription(name: "Later", day: 8),
            fixture.subscription(name: "Paused", day: 2, status: .paused),
            fixture.subscription(name: "No date", day: nil),
            fixture.subscription(name: "Cloud", day: 3)
        ]

        let result = NextRenewalReader.result(
            for: document,
            today: fixture.today,
            calendar: fixture.calendar,
            locale: fixture.locale
        )

        #expect(result == .renewal(name: "Cloud", amount: "€12.99", datePhrase: "on Sep 3"))
    }

    @Test("The next renewal uses a relative date within one week")
    func usesRelativeDate() {
        let fixture = IntentFixture()
        var document = StoreDocument.initial()
        document.subscriptions = [fixture.subscription(name: "Music", month: 8, day: 26)]

        let result = NextRenewalReader.result(
            for: document,
            today: fixture.today,
            calendar: fixture.calendar,
            locale: fixture.locale
        )

        #expect(result.message == "Music renews tomorrow for €12.99.")
    }

    @Test("A document with no dated billing item has no renewal")
    func reportsNoRenewal() {
        let fixture = IntentFixture()
        var document = StoreDocument.initial()
        document.subscriptions = [
            fixture.subscription(name: "Paused", month: 8, day: 26, status: .paused),
            fixture.subscription(name: "No date", day: nil)
        ]

        let result = NextRenewalReader.result(
            for: document,
            today: fixture.today,
            calendar: fixture.calendar,
            locale: fixture.locale
        )

        #expect(result == .noRenewal)
        #expect(result.message == "No active subscription has a renewal date.")
    }

    @Test("Reading a corrupt store does not change it")
    func leavesCorruptStoreUnchanged() async throws {
        let fixture = IntentFixture()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OboloIntentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = directory.appending(path: DocumentStore.fileName)
        let corruptData = Data("not json".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try corruptData.write(to: url)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await NextRenewalReader(
            store: DocumentStore(url: url),
            today: fixture.today,
            calendar: fixture.calendar,
            locale: fixture.locale
        ).read()

        #expect(result == .unavailable)
        #expect(try Data(contentsOf: url) == corruptData)
    }

    @Test("A quarantined store reports that data is unavailable")
    func reportsPendingRecovery() async throws {
        let fixture = IntentFixture()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OboloIntentRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = directory.appending(path: DocumentStore.fileName)
        let movedURL = directory.appending(path: "obolo.json.corrupt-test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecoverySidecar(movedTo: movedURL, error: "Test error", at: fixture.today)
            .write(besideStoreAt: url)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await NextRenewalReader(
            store: DocumentStore(url: url),
            today: fixture.today,
            calendar: fixture.calendar,
            locale: fixture.locale
        ).read()

        #expect(result == .unavailable)
    }

    @MainActor
    @Test("The Upcoming route is consumed one time")
    func consumesUpcomingRouteOnce() {
        _ = OboloIntentRouter.shared.takePendingRoute()

        OboloIntentRouter.shared.request(.upcoming)

        #expect(OboloIntentRouter.shared.takePendingRoute() == .upcoming)
        #expect(OboloIntentRouter.shared.takePendingRoute() == nil)
    }

    @MainActor
    @Test("Routes keep their request order")
    func keepsRouteOrder() {
        while OboloIntentRouter.shared.takePendingRoute() != nil {}
        let prefill = SubscriptionFormPrefill(name: "Music")

        OboloIntentRouter.shared.request(.upcoming)
        OboloIntentRouter.shared.request(.addSubscription(prefill))

        #expect(OboloIntentRouter.shared.takePendingRoute() == .upcoming)
        #expect(OboloIntentRouter.shared.takePendingRoute() == .addSubscription(prefill))
        #expect(OboloIntentRouter.shared.takePendingRoute() == nil)
    }

    @Test("Intent links keep their data in a URL")
    func roundTripsLinkURL() {
        let prefill = SubscriptionFormPrefill(
            name: "Video & Music",
            price: Decimal(string: "14.99"),
            currency: "USD",
            cycle: .custom(months: 5),
            anchorDate: BillingDay(isoDate: "2026-09-03")!
        )
        let link = OboloIntentLink.addSubscription(prefill)

        #expect(OboloIntentLink(url: link.url) == link)
        #expect(link.route == .addSubscription(prefill))
        #expect(OboloIntentLink(url: OboloIntentLink.upcoming.url) == .upcoming)
        #expect(OboloIntentLink.upcoming.route == .upcoming)
        #expect(OboloIntentLink(url: OboloIntentLink.home.url) == .home)
        #expect(OboloIntentLink.home.route == .home)

        // The links Shortcuts and the menu bar item have always sent still parse.
        #expect(
            OboloIntentLink(url: URL(string: "studio.anguria.obolo://intent/upcoming")!) == .upcoming
        )
        #expect(OboloIntentLink(url: URL(string: "studio.anguria.obolo://intent/home")!) == .home)
        #expect(
            OboloIntentLink(url: URL(string: "studio.anguria.obolo://intent/add-subscription?name=Music")!)
                == .addSubscription(SubscriptionFormPrefill(name: "Music"))
        )

        // A path the app does not route opens nothing.
        let unknown = URL(string: "studio.anguria.obolo://intent/subscription/a0000000-0000-4000-a000-000000000001")!
        #expect(OboloIntentLink(url: unknown) == nil)
    }

    @Test("No link opens a subscription's detail")
    func noLinkNamesASubscription() {
        // The link an earlier build sent for a clicked reminder, and its variants.
        let links = [
            "studio.anguria.obolo://intent/subscription?id=A0000000-0000-4000-A000-000000000001",
            "studio.anguria.obolo://intent/subscription?id=a0000000-0000-4000-a000-000000000001",
            "STUDIO.ANGURIA.OBOLO://INTENT/subscription?id=A0000000-0000-4000-A000-000000000001",
            "studio.anguria.obolo://intent/subscription",
            "studio.anguria.obolo://intent/subscription?id=netflix"
        ]
        for link in links {
            #expect(OboloIntentLink(url: URL(string: link)!) == nil, "\(link)")
        }
    }

    @Test("The window link builds the window and asks for nothing")
    func windowLinkAsksForNothing() {
        #expect(OboloIntentLink.window.absoluteString == "studio.anguria.obolo://intent/window")
        #expect(OboloIntentLink(url: OboloIntentLink.window) == nil)
        // The scene takes every "intent" link, so this one still builds the window.
        #expect(OboloIntentLink.window.host == "intent")
    }

    @Test("A route is sent as a link only when no window can take it")
    func sendsWindowLinkOnlyWithoutWindow() {
        #expect(MainWindowPresenter.windowLink(hasMainWindow: true) == nil)
        #expect(MainWindowPresenter.windowLink(hasMainWindow: false) == OboloIntentLink.window)
    }

    @MainActor
    @Test("Two clicked reminders open in click order, each one time")
    func keepsTwoReminderRoutesInOrder() {
        let router = OboloIntentRouter()
        let first = UUID(uuidString: "A0000000-0000-4000-A000-000000000001")!
        let second = UUID(uuidString: "A0000000-0000-4000-A000-000000000002")!

        router.request(.subscription(first))
        router.request(.subscription(second))

        #expect(router.takePendingRoute() == .subscription(first))
        #expect(router.takePendingRoute() == .subscription(second))
        #expect(router.takePendingRoute() == nil)
    }

    @MainActor
    @Test("The menu bar item does not send the window away from a waiting reminder")
    func homeDefersToWaitingRoute() {
        let router = OboloIntentRouter()
        let id = UUID(uuidString: "A0000000-0000-4000-A000-000000000001")!

        router.request(.subscription(id))
        router.request(.home)

        #expect(router.takePendingRoute() == .subscription(id))
        #expect(router.takePendingRoute() == nil)

        // With nothing waiting, the menu bar item opens Home as before.
        router.request(.home)
        #expect(router.takePendingRoute() == .home)
        #expect(router.takePendingRoute() == nil)
    }

    @Test("A clicked reminder asks for its subscription")
    func mapsClickedReminderToRoute() {
        let id = UUID(uuidString: "A0000000-0000-4000-A000-000000000001")!
        // The key and format `NotificationScheduler` writes.
        let userInfo: [AnyHashable: Any] = ["subscriptionID": id.uuidString]

        #expect(
            NotificationResponder.route(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: userInfo
            ) == .subscription(id)
        )
    }

    @Test("A dismissed or unreadable reminder asks for nothing")
    func ignoresOtherReminderResponses() {
        let id = UUID(uuidString: "A0000000-0000-4000-A000-000000000001")!

        #expect(
            NotificationResponder.route(
                actionIdentifier: UNNotificationDismissActionIdentifier,
                userInfo: ["subscriptionID": id.uuidString]
            ) == nil
        )
        #expect(
            NotificationResponder.route(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: [:]
            ) == nil
        )
        #expect(
            NotificationResponder.route(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: ["subscriptionID": "not a uuid"]
            ) == nil
        )
        #expect(
            NotificationResponder.route(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: ["subscriptionID": id]
            ) == nil
        )
    }

    @MainActor
    @Test("A clicked reminder waits with the other routes until the window takes it")
    func keepsReminderRouteUntilTaken() {
        while OboloIntentRouter.shared.takePendingRoute() != nil {}
        let id = UUID(uuidString: "A0000000-0000-4000-A000-000000000001")!

        OboloIntentRouter.shared.request(.home)
        OboloIntentRouter.shared.request(.subscription(id))

        #expect(OboloIntentRouter.shared.takePendingRoute() == .home)
        #expect(OboloIntentRouter.shared.takePendingRoute() == .subscription(id))
        #expect(OboloIntentRouter.shared.takePendingRoute() == nil)
    }

    @Test("The add intent makes an exact form prefill")
    func makesAddPrefill() {
        let fixture = IntentFixture()
        let price = IntentCurrencyAmount(
            amount: Decimal(string: "14.99")!,
            currencyCode: "usd"
        )
        let renewalDate = fixture.calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 3, hour: 16)
        )!

        let prefill = AddSubscriptionIntentPrefill.make(
            name: "Video",
            price: price,
            cycle: .yearly,
            renewalDate: renewalDate,
            calendar: fixture.calendar
        )

        #expect(prefill.name == "Video")
        #expect(prefill.price == Decimal(string: "14.99"))
        #expect(prefill.currency == "USD")
        #expect(prefill.cycle == .yearly)
        #expect(prefill.anchorDate == BillingDay(isoDate: "2026-09-03")!)
    }

    @Test("The add intent can open an empty form")
    func makesEmptyAddPrefill() {
        let fixture = IntentFixture()

        let prefill = AddSubscriptionIntentPrefill.make(
            name: nil,
            price: nil,
            cycle: nil,
            renewalDate: nil,
            calendar: fixture.calendar
        )

        #expect(prefill == SubscriptionFormPrefill())
    }

    @Test("The add form applies the prefill to its unsaved draft")
    func appliesPrefillToDraft() {
        let fixture = IntentFixture()
        let template = fixture.subscription(name: "", month: 8, day: 25)
        let prefill = SubscriptionFormPrefill(
            name: "Cloud",
            price: Decimal(string: "2.99"),
            currency: "USD",
            cycle: .quarterly,
            anchorDate: BillingDay(isoDate: "2026-09-03")!
        )

        let plainDraft = SubscriptionDraft(template, isNew: true)
        let prefilledDraft = SubscriptionDraft(
            template,
            isNew: true,
            prefill: prefill
        )

        #expect(plainDraft.hasAnchor == false)
        #expect(prefilledDraft.name == "Cloud")
        #expect(prefilledDraft.startingPrice == Decimal(string: "2.99"))
        #expect(prefilledDraft.currency == "USD")
        #expect(prefilledDraft.cycle == .quarterly)
        #expect(prefilledDraft.hasAnchor)
        #expect(prefilledDraft.anchorDate == BillingDay(isoDate: "2026-09-03")!)
        #expect(prefilledDraft.subscription()?.name == "Cloud")
    }

    @MainActor
    @Test("The add route keeps the prefill until the app consumes it")
    func routesAddPrefill() {
        _ = OboloIntentRouter.shared.takePendingRoute()
        let prefill = SubscriptionFormPrefill(name: "Music")

        OboloIntentRouter.shared.request(.addSubscription(prefill))

        #expect(OboloIntentRouter.shared.takePendingRoute() == .addSubscription(prefill))
        #expect(OboloIntentRouter.shared.takePendingRoute() == nil)
    }
}

private struct IntentFixture {
    let calendar: Calendar
    let locale = Locale(identifier: "en_US")
    let today: Date

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        self.today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25))!
    }

    func subscription(
        name: String,
        month: Int = 9,
        day: Int?,
        status: Status = .active
    ) -> Subscription {
        Subscription(
            name: name,
            categoryID: StoreDocument.initial().fallbackCategoryID,
            price: Decimal(string: "12.99")!,
            currency: "EUR",
            cycle: .monthly,
            anchorDate: day.map { BillingDay(self.day(2026, month, $0), calendar: calendar) },
            status: status,
            createdAt: today
        )
    }

    func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
