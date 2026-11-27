import Foundation
import OboloCore
import Testing

/// The detail's history drawings: the year strip for plans billed
/// once a year or less often, and the order the blocks drop in.
@MainActor
@Suite("Payment history chart")
struct PaymentHistoryChartTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private var today: Date { day(2026, 11, 26) }

    private func history(_ cycle: BillingCycle, anchor: Date, price: Decimal = 57.99) -> DetailHistory {
        let subscription = Subscription(
            name: "Plan", categoryID: OboloCore.Category.seeded[0].id,
            price: price, currency: "EUR", cycle: cycle,
            anchorDate: BillingDay(anchor, calendar: calendar), createdAt: anchor
        )
        let document = StoreDocument(
            subscriptions: [subscription],
            categories: OboloCore.Category.seeded,
            rates: RateTable(base: "EUR"),
            settings: Settings(baseCurrency: "EUR")
        )
        let ledger = Ledger(document: document, today: today, calendar: calendar)
        return DetailHistory(
            subscription: subscription, payments: ledger.payments(for: subscription.id), today: today, calendar: calendar
        )
    }

    private func blocks(_ scene: IsoScene) -> [IsoScene.Prism] { scene.prisms.filter { $0.id != nil } }

    @Test("A yearly plan is one strip: a cell per year, one equal block in each, never past a small cube")
    func yearlyStrip() {
        // Paid 10 Mar 2024 and 2025 and 2026; next 10 Mar 2027.
        let scene = IsoScene.yearStrip(history(.yearly, anchor: day(2024, 3, 10)))
        let blocks = blocks(scene)

        #expect(scene.outlines.count == 1)
        #expect(scene.outlines[0].rect.width == 4 * IsoScene.stripCell)
        #expect(scene.dividers.count == 3)
        #expect(scene.labels.map(\.text) == ["2024", "2025", "2026", "2027"])

        // One block per year, all the same height, within 16…46.
        #expect(blocks.count == 4)
        #expect(Set(blocks.map(\.h)).count == 1)
        #expect(blocks.allSatisfy { $0.h >= 16 && $0.h <= 46 })
        // Each sits 9 in from its cell's sides, and the cells touch.
        #expect(blocks.map(\.x) == [9, 55, 101, 147])
        #expect(blocks.allSatisfy { $0.w == IsoScene.stripCell - 18 && $0.d == IsoScene.stripCell - 18 })
        #expect(blocks.last?.style == .next)
    }

    @Test("Every two years leaves the year between empty")
    func everyTwoYearsStrip() {
        // Paid 10 Mar 2023 and 2025; next 10 Mar 2027.
        let scene = IsoScene.yearStrip(history(.everyTwoYears, anchor: day(2023, 3, 10)))
        #expect(scene.labels.map(\.text) == ["2023", "2024", "2025", "2026", "2027"])
        #expect(blocks(scene).map(\.x) == [9, 101, 193])
    }

    @Test("The next payment lands last, in every drawing")
    func nextLandsLast() {
        let scenes = [
            IsoScene.yearStrip(history(.yearly, anchor: day(2024, 3, 10))),
            IsoScene.yearTrays(history(.monthly, anchor: day(2025, 2, 10))),
            IsoScene.coinColumns(
                history(.monthly, anchor: day(2019, 2, 10)),
                subscription: Subscription(
                    name: "Plan", categoryID: OboloCore.Category.seeded[0].id,
                    price: 57.99, currency: "EUR", cycle: .monthly
                )
            ),
        ]
        for scene in scenes {
            let next = scene.prisms.filter { $0.style == .next }
            let others = scene.prisms.filter { $0.style != .next && $0.id != nil }
            #expect(next.count == 1)
            guard let landing = next.first else { continue }
            #expect(others.allSatisfy { $0.delay < landing.delay })
            #expect(landing.duration == IsoScene.nextDuration)
            #expect(scene.nextLandsAt == landing.delay + IsoScene.nextDuration)
            #expect(scene.buildDuration >= scene.nextLandsAt)
        }
    }

    @Test("Trays build one after another, their blocks back to front")
    func traysBuildInOrder() {
        let scene = IsoScene.yearTrays(history(.monthly, anchor: day(2025, 2, 10)))
        #expect(scene.outlines.map(\.delay) == [0, 0.22])
        // Paid blocks in painter's order never start before the one drawn behind them.
        let delays = scene.prisms.filter { $0.style == .paid }.map(\.delay)
        let firstTray = delays.filter { $0 < 0.22 + 0.12 }
        #expect(firstTray == firstTray.sorted())
    }

    @Test("A hovered block lights up: paid turns light, next stops breathing, to come turns ink")
    func hoverLook() throws {
        let paid = try #require(IsoScene.look(for: .paid, isHovered: false))
        let litPaid = try #require(IsoScene.look(for: .paid, isHovered: true))
        #expect(litPaid != paid)
        #expect(litPaid.top == IsoScene.hoverTop)
        #expect(litPaid.right == IsoScene.hoverRight && litPaid.left == IsoScene.hoverLeft)
        #expect(litPaid.edge == IsoScene.hoverEdge && litPaid.edgeWidth == 0.6)

        // The next one breathes, except under the pointer.
        let next = try #require(IsoScene.look(for: .next, isHovered: false, nextOpacity: 0.6))
        let litNext = try #require(IsoScene.look(for: .next, isHovered: true, nextOpacity: 0.6))
        #expect(next.opacity == 0.6)
        #expect(litNext.opacity == 1)
        #expect(litNext.edgeWidth == 0.8)
        #expect(litNext.top == next.top)

        let toCome = try #require(IsoScene.look(for: .toCome, isHovered: false))
        let litToCome = try #require(IsoScene.look(for: .toCome, isHovered: true))
        #expect(toCome.top == IsoScene.stripe)
        #expect(litToCome.top == DS.Palette.ink && litToCome.edge == DS.Palette.ink)

        // The floor and the current-year frame are not payments.
        #expect(IsoScene.look(for: .frame, isHovered: true) == nil)
        #expect(IsoScene.look(for: .floor, isHovered: true) == nil)
    }

    @Test("A block is placed once its time is up, and waits before it starts")
    func progressClamps() {
        #expect(IsoScene.progress(elapsed: 0, delay: 0.5, duration: 0.55) == 0)
        #expect(IsoScene.progress(elapsed: 2, delay: 0.5, duration: 0.55) == 1)
        #expect(IsoScene.progress(elapsed: .infinity, delay: 0.5, duration: 0.55) == 1)
    }
}
