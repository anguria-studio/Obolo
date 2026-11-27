import SwiftUI
import OboloCore

/// Home: the monthly spend card with its three charts, and this month's tick meter.
///
/// Two panels. The top one has one hero figure (Monthly spend) with Yearly and the
/// change since last month beside it, then one chart picked with the switch at the
/// bottom of the card. The bottom one is the current month's payments as 100 ticks.
/// Nothing on Home scrolls except the month bars, sideways.
struct HomeView: View {
    let model: AppModel
    /// The month picked in the top bar; `nil` is the current month.
    var month: Date?
    /// The first subscription, just saved: Home holds its empty layout a moment longer
    /// to fill the slab in (see `EmptyHomeView`), then clears this.
    var firstSlab: Binding<Subscription.ID?> = .constant(nil)

    @Environment(\.homeBuildLog) private var buildLog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The document as it reads in the picked month: its prices, its categories, its
    /// change against the month before. The current month is the model's own ledger.
    private var ledger: Ledger {
        month.map { model.ledger.ledger(forMonthContaining: $0) } ?? model.ledger
    }

    var body: some View {
        if model.hasNoSubscriptions || firstSlab.wrappedValue != nil {
            EmptyHomeView(model: model, firstSlab: firstSlab.wrappedValue, onFinish: finishFirstSlab)
                .transition(.opacity)
        } else {
            home
                .transition(.opacity)
        }
    }

    /// After the first-slab moment: the normal Home, whose stack starts from that slab
    /// already in place rather than dropping it in again.
    private func finishFirstSlab() {
        guard firstSlab.wrappedValue != nil else { return }
        _ = buildLog.claim(.category)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { firstSlab.wrappedValue = nil }
    }

    private var home: some View {
        let ledger = ledger
        return VStack(spacing: DS.Size.gutter) {
            SpendPanel(model: model, ledger: ledger, isCurrentMonth: month == nil)
                .frame(maxHeight: .infinity)
                .dsPanel()

            TickMeterPanel(
                progress: model.ledger.monthProgress(containing: ledger.today, paidThrough: model.today),
                currency: currency,
                calendar: model.calendar,
                showsYear: model.calendar.component(.year, from: ledger.today) != model.calendar.component(.year, from: model.today)
            )
            // A new month is a new meter: its paid ticks fill again (see `HomeBuildLog`).
            .id(MonthRange.start(of: ledger.today, calendar: model.calendar))
            .dsPanel()
        }
        .accessibilityIdentifier("home")
    }

    private var currency: String { model.document.settings.baseCurrency }
}

// MARK: - Build log

/// Which of Home's charts have already played their build animation in this window.
///
/// Each chart plays its build animation once per window opening. Switching back crossfades
/// to the chart. Data updates animate only the changed elements.
///
/// The tick strip also remembers the last month it filled so a month change replays the fill.
final class HomeBuildLog: @unchecked Sendable {
    enum Chart: Hashable { case category, months, subscriptions, ticks, emptySlab, detailChart }

    private var played: Set<Chart> = []

    func hasPlayed(_ chart: Chart) -> Bool { played.contains(chart) }

    /// Claims the build for `chart`: true the first time, false after.
    func claim(_ chart: Chart) -> Bool { played.insert(chart).inserted }

    /// The month the tick strip last filled for.
    private var ticksMonth: Date?

    /// Whether the tick strip has already filled for `month` in this window.
    func hasFilledTicks(for month: Date) -> Bool { ticksMonth == month }

    /// Claims the tick strip's fill for `month`: true the first time and whenever the
    /// month differs from the one it last filled for.
    func claimTicks(for month: Date) -> Bool {
        played.insert(.ticks)
        guard ticksMonth != month else { return false }
        ticksMonth = month
        return true
    }
}

extension EnvironmentValues {
    /// A fresh log by default, so previews always build.
    @Entry var homeBuildLog = HomeBuildLog()
}

// MARK: - Spend panel

private struct SpendPanel: View {
    let model: AppModel
    let ledger: Ledger
    let isCurrentMonth: Bool

    private var currency: String { model.document.settings.baseCurrency }
    private var mode: SpendView { model.document.settings.spendView }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetricHeader(ledger: ledger, isCurrentMonth: isCurrentMonth)

            ZStack {
                switch mode {
                case .category:
                    CategoryChart(model: model, ledger: ledger)
                        .transition(.opacity)
                case .month:
                    MonthBarsChart(model: model, focus: isCurrentMonth ? nil : ledger.today)
                        .transition(.opacity)
                case .subscription:
                    SubscriptionRingChart(model: model, ledger: ledger)
                        .transition(.opacity)
                }
            }
            // Switching charts crossfades; a chart shown before in this window does not
            // build again (see `HomeBuildLog`).
            .animation(.easeOut(duration: 0.2), value: mode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 10)

            footer
                .padding(.top, 12)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            DSSegmentedSwitch(
                options: [(SpendView.category, "Category"), (.month, "Months"), (.subscription, "Subscriptions")],
                selection: mode,
                onSelect: { model.settings.spendView = $0 },
                accessibilityLabel: "Chart",
                itemHeight: 24,
                itemPadding: 12,
                trackFill: DS.Palette.bg100
            )
            // Always whole: when the two compete for the width, the note gives way.
            .fixedSize()
            .accessibilityIdentifier("home.chart")

            Spacer(minLength: 0)

            footerNote
                .dsLabel()
                .lineLimit(1)
        }
    }

    private var footerNote: Text {
        // Honest numbers: a total that leaves something out says so next to the chart.
        // "N without a rate", the same words as the tick meter, the calendar and All.
        if ledger.missingRateCount > 0 {
            return Text("\(Text("\(ledger.missingRateCount)").foregroundStyle(DS.Palette.warning)) without a rate")
        }
        let categories = ledger.categoryTotals.count { $0.monthly > 0 }
        switch mode {
        case .category:
            return Text("\(Text.ink("\(categories)")) \(categories == 1 ? "category" : "categories")")
        case .month:
            let average = MoneyFormatting.compact(MonthBarsChart.averageCharged(model: model), currency: currency)
            return Text("← Scroll · avg \(Text.ink(average))")
        case .subscription:
            return Text("\(Text.ink("\(ledger.activeCount)")) active · \(Text.ink("\(categories)")) \(categories == 1 ? "category" : "categories")")
        }
    }
}

// MARK: - Metric header

/// "MONTHLY SPEND", the 44pt hero, the change since the month before, and Yearly on
/// the right. For another month the label names it.
private struct MetricHeader: View {
    let ledger: Ledger
    let isCurrentMonth: Bool

    private var currency: String { ledger.document.settings.baseCurrency }

    /// How far the hero may shrink to leave Yearly room.
    private static let heroMinimumScale: CGFloat = 0.6

    /// How Yearly reads in a row that does not fit as it is.
    private enum YearlyForm { case full, wholeUnits, wholeUnitsShrinking }

    var body: some View {
        // The first row that fits: as designed; then the hero shrinking (to 60% at
        // most) beside Yearly in full; then Yearly in whole units too; then Yearly also
        // set smaller. Amounts never end in an ellipsis.
        ViewThatFits(in: .horizontal) {
            row(heroShrinks: false, yearly: .full)
            row(heroShrinks: true, yearly: .full)
            row(heroShrinks: true, yearly: .wholeUnits)
            row(heroShrinks: true, yearly: .wholeUnitsShrinking)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(heroShrinks: Bool, yearly: YearlyForm) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                if isCurrentMonth {
                    Text("Monthly spend").dsLabel()
                } else {
                    Text("Monthly spend · \(Text(ledger.today.formatted(.dateTime.month(.abbreviated).year())).foregroundStyle(DS.Palette.ink))")
                        .dsLabel()
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    // Estimated prices carry the approximation mark on individual subscriptions.
                    HeroAmount(
                        text: MoneyFormatting.amount(ledger.monthlyTotal, currency: currency),
                        minimumScale: heroShrinks ? Self.heroMinimumScale : nil
                    )
                    if heroShrinks {
                        change.fixedSize()
                    } else {
                        change
                    }
                }
            }
            // Where the hero shrinks, it gives way first: it takes the width Yearly and
            // the gap leave. In the last row, at its smallest already, it leaves Yearly
            // the rest.
            .layoutPriority(heroShrinks && yearly != .wholeUnitsShrinking ? 1 : 0)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Text("Yearly").dsLabel()
                yearlyAmount(yearly, fixed: heroShrinks)
                    .dsStyle(.dataLG)
                    .foregroundStyle(DS.Palette.inkMuted)
            }
            .layoutPriority(yearly == .wholeUnitsShrinking ? 1 : 0)
        }
    }

    @ViewBuilder
    private func yearlyAmount(_ form: YearlyForm, fixed: Bool) -> some View {
        switch form {
        case .full:
            if fixed {
                Text(MoneyFormatting.amount(ledger.yearlyTotal, currency: currency)).fixedSize()
            } else {
                Text(MoneyFormatting.amount(ledger.yearlyTotal, currency: currency))
            }
        case .wholeUnits:
            Text(MoneyFormatting.compact(ledger.yearlyTotal, currency: currency)).fixedSize()
        case .wholeUnitsShrinking:
            // Takes the width the hero, at its smallest, leaves.
            ShrinkableWidth(minimumScale: 0.5) {
                Text(MoneyFormatting.compact(ledger.yearlyTotal, currency: currency))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
    }

    /// "↓ 3,20 € vs Oct": what price changes did to the total since a month earlier.
    @ViewBuilder
    private var change: some View {
        let monthBefore = ledger.calendar.date(byAdding: .month, value: -1, to: ledger.today) ?? ledger.today
        if let delta = ledger.monthlyTotalChange(since: monthBefore) {
            let up = delta > 0
            let month = monthBefore.formatted(.dateTime.month(.abbreviated))
            Text("\(up ? "↑" : "↓") \(MoneyFormatting.amount(abs(delta), currency: currency)) vs \(month)")
                .dsStyle(.column)
                .foregroundStyle(up ? DS.Palette.danger : DS.Palette.positive)
                .help("Change in the monthly total from price changes since \(month)")
        }
    }
}

/// The hero number with its currency symbol at 24pt in `inkMuted`.
///
/// The amount is formatted once by `MoneyFormatting`, so the locale still decides where
/// the symbol goes; this only sets the symbol smaller.
struct HeroAmount: View {
    let text: String
    var style: DSTextStyle = .numXL
    var unitSize: CGFloat = 24
    /// One colour for number and symbol both (empty Home's `inkDisabled` zero); `nil`
    /// draws the number in `ink` and the symbol in `inkMuted`.
    var color: Color?
    /// How small it may set itself to fit a narrower width, number and symbol alike
    /// and on the same baseline; `nil` always draws it whole at its size.
    var minimumScale: CGFloat?

    var body: some View {
        if let minimumScale {
            ShrinkableWidth(minimumScale: minimumScale) {
                Text(attributed)
                    .tracking(style.tracking)
                    .lineLimit(1)
                    .minimumScaleFactor(minimumScale)
            }
        } else {
            Text(attributed)
                .tracking(style.tracking)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let numberCharacters = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".,'~-−"))
        var run = ""
        var runIsNumber: Bool?
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if runIsNumber == true {
                piece.font = style.font
                piece.foregroundColor = color ?? DS.Palette.ink
            } else {
                piece.font = DSFonts.font(DSFonts.sansRegular, size: unitSize)
                piece.foregroundColor = color ?? DS.Palette.inkMuted
            }
            result += piece
            run = ""
        }
        for scalar in text.unicodeScalars {
            let isSpace = CharacterSet.whitespaces.contains(scalar)
            let isNumber = numberCharacters.contains(scalar)
            // Spaces join whichever run they sit in; they never start a new one.
            if !isSpace, runIsNumber != isNumber {
                flush()
                runIsNumber = isNumber
            }
            run.unicodeScalars.append(scalar)
        }
        flush()
        return result
    }
}

// MARK: - Previews

#Preview("Home · Category") {
    MainWindow(model: .handoffPreview { $0.settings.spendView = .category })
}

#Preview("Home · Months") {
    MainWindow(model: .handoffPreview { $0.settings.spendView = .month })
}

#Preview("Home · Subscriptions") {
    MainWindow(model: .handoffPreview { $0.settings.spendView = .subscription })
}

#Preview("Home · another month") {
    let model = AppModel.handoffPreview()
    return HomeView(model: model, month: model.calendar.date(byAdding: .month, value: 5, to: model.today))
        .frame(width: 624, height: 528)
        .padding(8)
        .background(DS.Palette.bg100)
}

#Preview("Month picker") {
    let model = AppModel.handoffPreview()
    let calendar = model.calendar
    let current = MonthRange.start(of: model.today, calendar: calendar)
    return MonthGridPicker(
        calendar: calendar,
        current: current,
        selected: MonthRange.start(of: model.today, offsetByMonths: 3, calendar: calendar),
        earliest: MonthRange.start(of: model.today, offsetByMonths: -20, calendar: calendar),
        latest: MonthRange.start(of: model.today, offsetByMonths: 60, calendar: calendar),
        onPick: { _ in }
    )
}

#Preview("Home · many categories") {
    MainWindow(model: .handoffPreview { document in
        // Give every subscription its own category so the list has to scroll.
        let tints = CategoryHue.allCases
        for index in document.subscriptions.indices {
            let category = OboloCore.Category(name: "Category \(index + 1)", tint: tints[index % tints.count], sortOrder: 100 + index)
            document.categories.append(category)
            document.subscriptions[index].categoryID = category.id
        }
    })
}
