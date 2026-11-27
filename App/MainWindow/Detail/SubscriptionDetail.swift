import SwiftUI
import OboloCore

/// One subscription: a summary card and its price history.
///
/// The summary is the logo or initial, the name with its category, cycle and status, the
/// price (per month, and per year below it) and three facts: next payment, total spent,
/// customer since. The history is a bar per payment from the first to the next, the price
/// changes marked over the bars, and the list of prices underneath.
///
/// Opens from a row on All or from the Home subscription legend.
struct SubscriptionDetail: View {
    @Bindable var model: AppModel
    /// "+ Add price change": opens Edit with a new change row.
    let onAddPriceChange: (Subscription.ID) -> Void

    var body: some View {
        if let id = model.selectedID, let summary = model.summary(id) {
            VStack(spacing: DS.Size.gutter) {
                DetailSummaryCard(model: model, summary: summary)
                    .dsPanel()
                PriceHistoryCard(model: model, summary: summary) { onAddPriceChange(id) }
                    .frame(maxHeight: .infinity)
                    .dsPanel()
            }
            .background {
                // ⌘[ goes back, like Esc and the top bar's back link.
                Button("Back") { model.closeSubscriptionDetail() }
                    .keyboardShortcut("[", modifiers: [.command])
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier("detail")
        }
    }
}

// MARK: - Summary

private struct DetailSummaryCard: View {
    let model: AppModel
    let summary: SubscriptionSummary

    private var subscription: Subscription { summary.subscription }
    private var base: String { model.document.settings.baseCurrency }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                SubscriptionIcon(subscription: subscription, size: 52, isCancelled: summary.status == .cancelled)

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name)
                        .font(DSFonts.font(DSFonts.sansMedium, size: 24))
                        .tracking(-0.24)
                        .foregroundStyle(DS.Palette.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        CategoryMarker(summary.category.tint, size: 8)
                        // The status (with its end date) always shows in full; the category
                        // gives way first when the line is short of room, and the separator
                        // stays outside it so a cut category still reads "… · Active". The
                        // cycle is left to the price ("/ month", "/ 2 years").
                        HStack(spacing: 0) {
                            Text(summary.category.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(" · ")
                                .fixedSize()
                            statusText
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .dsLabel()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                price
            }

            // Three facts across the card's full width, under a hairline.
            HStack(spacing: 0) {
                fact("Next payment", value: nextValue, warn: nextWarns, isFirst: true)
                divider
                fact("Total spent", value: spentValue, warn: false)
                divider
                fact("Customer since", value: sinceValue, warn: false)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
            .overlay(alignment: .top) {
                Rectangle().fill(DS.Palette.line).frame(height: DS.hairline)
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    // MARK: Status

    /// The status in its colour: active green, trial orange with its end, cancelled grey
    /// with its end. (Pause is gone; a paused one left in memory reads as cancelled.)
    private var statusText: Text {
        let ends = subscription.endsOn.map {
            " · ends " + DateFormatting.dayAndMonth($0.startOfDay(in: model.calendar), calendar: model.calendar)
        } ?? ""
        // An end that is today or past is just "Cancelled": access has stopped.
        let accessRunsOn = subscription.endsOn.map {
            $0 > BillingDay(model.today, calendar: model.calendar)
        } ?? false
        switch summary.status {
        case .active: return Text("Active").foregroundStyle(DS.Palette.positive)
        case .trial: return Text("Trial" + ends).foregroundStyle(DS.Palette.accent)
        case .cancelled, .paused: return Text("Cancelled" + (accessRunsOn ? ends : "")).foregroundStyle(DS.Palette.inkDisabled)
        }
    }

    // MARK: Price

    /// The price in two aligned columns: the amounts end on one
    /// edge, the units start on another, both in the same label spacing. Short units
    /// ("/ mo", "/ yr") keep both lines the same width in mono. On top, the charge with
    /// its own unit, with "~" in yellow when the price may vary; under it, the other
    /// period in the base currency: the year for a monthly plan, the month otherwise.
    private var price: some View {
        let isMonthly = summary.cycle == .monthly
        let amount = MoneyFormatting.amount(summary.price, currency: summary.currency)
        let secondary: (amount: String, unit: String)? = isMonthly
            ? summary.yearlyInBase.map { (MoneyFormatting.amount($0, currency: base), "/ yr") }
            : summary.monthlyInBase.map { (MoneyFormatting.amount($0, currency: base), "/ mo") }
        return Grid(horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if summary.isEstimate {
                        Text("~")
                            .font(DSTextStyle.numLG.font)
                            .foregroundStyle(DS.Palette.warning)
                            .help("Estimated price")
                    }
                    HeroAmount(text: amount, style: .numLG, unitSize: 18)
                }
                .gridColumnAlignment(.trailing)
                Text(summary.cycle.shortPerUnitSuffix)
                    .dsLabel()
                    .gridColumnAlignment(.leading)
            }
            if let secondary {
                GridRow(alignment: .firstTextBaseline) {
                    Text(secondary.amount)
                        .foregroundStyle(DS.Palette.ink)
                        .dsLabel()
                    Text(secondary.unit)
                        .dsLabel()
                }
            }
        }
        .fixedSize()
    }

    // MARK: Facts

    private var divider: some View {
        Rectangle().fill(DS.Palette.line).frame(width: DS.hairline).frame(maxHeight: .infinity)
    }

    /// A mono label and a mono value, nothing under it.
    private func fact(_ title: String, value: String, warn: Bool, isFirst: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).dsLabel()
            Text(value)
                .font(DSFonts.font(DSFonts.monoRegular, size: 17))
                .foregroundStyle(warn ? DS.Palette.warning : DS.Palette.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, isFirst ? 0 : 18)
    }

    private var nextValue: String {
        if summary.status == .cancelled, let ends = subscription.endsOn {
            return DateFormatting.full(ends.startOfDay(in: model.calendar), calendar: model.calendar)
        }
        guard let date = summary.nextPayment else { return "–" }
        return DateFormatting.full(date, calendar: model.calendar)
    }

    /// Yellow when the next payment is within a week.
    private var nextWarns: Bool {
        guard summary.status.isBilling, let date = summary.nextPayment else { return false }
        let days = model.calendar.dateComponents(
            [.day], from: model.calendar.startOfDay(for: model.today), to: model.calendar.startOfDay(for: date)
        ).day ?? 0
        return days <= 7
    }

    private var spentValue: String {
        guard let paid = summary.paidSoFar else { return "–" }
        return paid.totalsByCurrency
            .sorted { $0.key < $1.key }
            .map { MoneyFormatting.amount($0.value, currency: $0.key) }
            .joined(separator: " + ")
    }

    /// The month and year of the first payment ("Aug 2021"); no duration.
    private var sinceValue: String {
        guard let start = subscription.anchorDate?.startOfDay(in: model.calendar) else { return "–" }
        guard start < model.calendar.startOfDay(for: model.today) else { return "–" }
        return start.formatted(
            Date.FormatStyle(calendar: model.calendar, timeZone: model.calendar.timeZone).month(.abbreviated).year()
        )
    }
}

// MARK: - Price history

private struct PriceHistoryCard: View {
    let model: AppModel
    let summary: SubscriptionSummary
    let onAddPriceChange: () -> Void

    /// The payment under the pointer, by its date.
    @State private var hovered: Date?

    /// The chart takes the card’s remaining height, down to this minimum.
    private static let minChartHeight: CGFloat = 120
    /// Price list rows; past three the list scrolls, with a fade at the bottom, and the
    /// chart gets the room.
    private static let rowHeight: CGFloat = 34
    private static let maxListHeight: CGFloat = 3 * 34
    /// The year list beside the coin columns and the year strip.
    private static let yearListWidth: CGFloat = 250

    var body: some View {
        let payments = model.ledger.payments(for: summary.id)
        let history = DetailHistory(
            subscription: summary.subscription, payments: payments, today: model.today, calendar: model.calendar
        )
        let kind = DetailChartKind.for(
            summary.subscription, paidCount: history.paid.count, today: model.today, calendar: model.calendar
        )
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                headerText(history, kind: kind)
                    .dsLabel()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onAddPriceChange) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11))
                        Text("Add price change")
                    }
                    .fixedSize()
                }
                .buttonStyle(DSSecondaryButtonStyle(height: 28, mono: true))
                .dsFocusRing(Capsule())
            }

            if history.items.isEmpty {
                Text("Add the first payment to see the price history.")
                    .dsStyle(.bodySmall)
                    .foregroundStyle(DS.Palette.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: Self.minChartHeight, maxHeight: .infinity)
            } else {
                chart(history, kind: kind)
                    .frame(minHeight: Self.minChartHeight, maxHeight: .infinity)
                    .padding(.top, 12)
                legend
                    .padding(.top, 6)
            }

            // Anchored to the card's bottom: the chart above takes the rest.
            priceList(payments: payments)
                .padding(.top, 10)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 8)
        // A trackpad tick each time the pointer lands on another payment.
        .onChange(of: hovered) { _, id in if id != nil { Haptics.tick() } }
    }

    // MARK: Header

    /// "By month · 231,82 € since Feb 2025"; on hover, "By month · Mar 2025 · 14,99 € paid".
    private func headerText(_ history: DetailHistory, kind: DetailChartKind) -> Text {
        let title = kind == .yearTrays ? "By month" : "By year"
        let detail: String
        if let item = history.item(id: hovered) {
            let when = kind == .yearTrays
                ? item.date.formatted(Date.FormatStyle(calendar: model.calendar, timeZone: model.calendar.timeZone).month(.abbreviated).year())
                : DateFormatting.full(item.date, calendar: model.calendar)
            let amount = MoneyFormatting.amount(item.amount, currency: item.currency)
            let state = switch item.state {
            case .paid: "paid"
            case .next: "due"
            case .toCome: "to come"
            }
            detail = "\(when) · \(amount) \(state)"
        } else if let first = history.paid.first {
            let since = first.date.formatted(
                Date.FormatStyle(calendar: model.calendar, timeZone: model.calendar.timeZone).month(.abbreviated).year()
            )
            detail = "\(Self.total(history.paid)) since \(since)"
        } else {
            detail = "Nothing paid yet"
        }
        return Text("\(title) · \(Text(detail).foregroundStyle(DS.Palette.ink))")
    }

    /// A sum per currency, joined: "231,82 €", or "120,00 € + 40,00 $".
    private static func total(_ items: [DetailHistory.Item]) -> String {
        var byCurrency: [String: Decimal] = [:]
        for item in items { byCurrency[item.currency, default: 0] += item.amount }
        return byCurrency.sorted { $0.key < $1.key }
            .map { MoneyFormatting.amount($0.value, currency: $0.key) }
            .joined(separator: " + ")
    }

    // MARK: Chart

    @ViewBuilder
    private func chart(_ history: DetailHistory, kind: DetailChartKind) -> some View {
        switch kind {
        case .yearTrays:
            IsoHistoryCanvas(
                scene: .yearTrays(history),
                hovered: $hovered,
                accessibilityText: accessibilityText(history, unit: "month")
            )
        case .yearStrip:
            // The year list beside it, as with the columns; the strip
            // is fitted, centred, into the room left of it.
            HStack(spacing: 16) {
                IsoHistoryCanvas(
                    scene: .yearStrip(history),
                    hovered: $hovered,
                    accessibilityText: accessibilityText(history, unit: "year")
                )
                yearList(history)
                    .frame(width: Self.yearListWidth)
            }
        case .coinColumns:
            HStack(spacing: 16) {
                IsoHistoryCanvas(
                    scene: .coinColumns(history, subscription: summary.subscription),
                    hovered: $hovered,
                    accessibilityText: accessibilityText(history, unit: "year")
                )
                yearList(history)
                    .frame(width: Self.yearListWidth)
            }
        }
    }

    private func accessibilityText(_ history: DetailHistory, unit: String) -> String {
        let paid = history.paid.count
        var text = "Payments by \(unit): \(paid) \(paid == 1 ? "payment" : "payments") made"
        if let next = history.items.first(where: { $0.state == .next }) {
            text += ", next on \(DateFormatting.full(next.date, calendar: model.calendar))"
        }
        return text
    }

    /// Newest year first: a marker, the year, how many payments, what they came to.
    /// Years with nothing paid are left out; past eight, the rest are counted.
    private func yearList(_ history: DetailHistory) -> some View {
        let shown = Array(history.years.suffix(IsoScene.maxColumns))
        let earlier = history.years.count - shown.count
        let rows = shown.reversed().compactMap { year -> (year: Int, paid: [DetailHistory.Item])? in
            let paid = history.items(in: year).filter { $0.state == .paid }
            return paid.isEmpty ? nil : (year, paid)
        }
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(rows, id: \.year) { row in
                    HStack(spacing: 10) {
                        Rectangle()
                            .fill(row.year == history.currentYear ? DS.Palette.accent : DS.Palette.inkMuted)
                            .frame(width: 8, height: 8)
                        Text(String(row.year))
                            .font(DSFonts.font(DSFonts.monoRegular, size: 14))
                            .foregroundStyle(DS.Palette.ink)
                        Text(row.paid.count == 1 ? "1 payment" : "\(row.paid.count) payments")
                            .dsStyle(.labelSmall)
                            .foregroundStyle(DS.Palette.inkMuted)
                            .fixedSize()
                        Spacer(minLength: 8)
                        Text(Self.total(row.paid))
                            .dsStyle(.data)
                            .foregroundStyle(DS.Palette.ink)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(height: 30)
                    .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.line).frame(height: DS.hairline) }
                }
                if earlier > 0 {
                    Text("+ \(earlier) earlier \(earlier == 1 ? "year" : "years")")
                        .dsStyle(.labelSmall)
                        .foregroundStyle(DS.Palette.inkMuted)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                }
            }
        }
        .scrollIndicators(.automatic)
    }

    /// ▪ Paid · ▪ Next · ⬚ To come, right-aligned above the price list.
    private var legend: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(IsoScene.paidSwatch).frame(width: 8, height: 8)
            Text("Paid")
            Text("·")
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(DS.Palette.accent).frame(width: 8, height: 8)
            Text("Next")
            Text("·")
            // 135° stripes in a solid outline, like the blocks still to come.
            Canvas { context, size in
                let square = RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .path(in: CGRect(origin: .zero, size: size))
                var stripes = context
                stripes.clip(to: square)
                stripes.stroke(
                    IsoScene.stripes(in: CGRect(origin: .zero, size: size), pitch: 3, rising: false),
                    with: .color(IsoScene.stripe), lineWidth: 1
                )
                context.stroke(
                    RoundedRectangle(cornerRadius: 2, style: .continuous).path(in: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)),
                    with: .color(IsoScene.toComeEdge), lineWidth: 1
                )
            }
            .frame(width: 8, height: 8)
            Text("To come")
        }
        .font(DSFonts.font(DSFonts.monoRegular, size: 10))
        .foregroundStyle(DS.Palette.inkDisabled)
        .accessibilityHidden(true)
    }

    // MARK: Price list

    /// Each price with the payments made at it, oldest first; one price ever is a single
    /// line instead. The counts add up to the payments on the chart and "Total spent".
    @ViewBuilder
    private func priceList(payments: [Ledger.Payment]) -> some View {
        let periods = summary.subscription.pricePeriods(today: model.today, calendar: model.calendar)
        let paid = payments.filter { !$0.isNext }
        if periods.count <= 1 {
            singlePriceRow(
                first: periods.first?.start ?? summary.subscription.anchorDate?.startOfDay(in: model.calendar),
                count: paid.count
            )
        } else {
            let counts = Self.paymentCounts(periods, paid: paid, calendar: model.calendar)
            let rows = VStack(spacing: 0) {
                ForEach(Array(periods.enumerated()), id: \.offset) { index, period in
                    priceRow(period, isFirst: index == 0, count: counts[index])
                }
            }
            if CGFloat(periods.count) * Self.rowHeight > Self.maxListHeight {
                ScrollView(.vertical) { rows }
                    .dsScrollFade()
                    .frame(height: Self.maxListHeight)
            } else {
                rows
            }
        }
    }

    /// How many payments fell in each period: from its start to the next one's.
    static func paymentCounts(
        _ periods: [Subscription.PricePeriod],
        paid: [Ledger.Payment],
        calendar: Calendar
    ) -> [Int] {
        let starts = periods.map { calendar.startOfDay(for: $0.start) }
        return starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : nil
            return paid.filter { payment in
                // The first period holds everything up to the second, so the counts add
                // up even if a payment predates the first start.
                (index == 0 || payment.date >= starts[index]) && (end.map { payment.date < $0 } ?? true)
            }.count
        }
    }

    private func priceRow(_ period: Subscription.PricePeriod, isFirst: Bool, count: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(isFirst ? "Since" : "From") \(DateFormatting.full(period.start, calendar: model.calendar))")
                .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                .foregroundStyle(DS.Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 132, alignment: .leading)
            Text(MoneyFormatting.amount(period.price, currency: period.currency))
                .dsStyle(.data)
                .foregroundStyle(DS.Palette.ink)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            Text(count == 1 ? "1 payment" : "\(count) payments")
                .dsStyle(.labelSmall)
                .foregroundStyle(DS.Palette.inkMuted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let change = period.change {
                Text("\(change > 0 ? "↑ +" : "↓ −")\(MoneyFormatting.amount(abs(change), currency: period.currency))")
                    .dsLabel()
                    .foregroundStyle(change > 0 ? DS.Palette.danger : DS.Palette.positive)
            }
            if period.isCurrent {
                Text("Now")
                    .dsLabel()
                    .foregroundStyle(DS.Palette.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(DS.Palette.lineStrong, lineWidth: DS.hairline))
            }
        }
        .frame(height: Self.rowHeight)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.line).frame(height: DS.hairline) }
    }

    /// "No price changes since 30 Aug 2021" on the left, "63 payments" on the right edge.
    private func singlePriceRow(first: Date?, count: Int) -> some View {
        let since = first.map { DateFormatting.full($0, calendar: model.calendar) }
        let payments = count == 1 ? "1 payment" : "\(count) payments"
        return HStack(spacing: 12) {
            if let since {
                Text("No price changes since \(Text(since).foregroundStyle(DS.Palette.ink))")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text(payments)
                    .foregroundStyle(DS.Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text("No price changes")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .dsLabel()
        .frame(height: Self.rowHeight)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.line).frame(height: DS.hairline) }
    }
}
