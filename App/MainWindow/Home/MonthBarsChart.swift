import SwiftUI
import OboloCore

/// Months view: what each month charged, as thin bars that scroll back in time.
///
/// Two years back and eighteen months ahead, past bars light, future bars dim. Dotted
/// gridlines with their amounts sit in a clear strip on the left. Orange is the picked
/// month, the window's shared one: its bar and its axis letter are
/// accent, the only orange on the axis. Away from it, the current month's bar takes the
/// past style and its letter is ink with a small ink square under it, a neutral "today"
/// mark; its glow breathes only while it is also the picked month.
///
/// Hovering brightens a bar to ink and scrubs the four figures above; leaving the chart
/// returns them to the picked month. A click picks that month for the window (Home
/// re-dates to it, and Calendar opens on it) without scrolling, so the bar stays under
/// the pointer; the chart recentres only when the month changes from elsewhere (the
/// picker, Calendar, a reopened window, a new day). The month's name opens it in the
/// Calendar.
///
/// On appearing, the bars grow from the baseline in a wave that starts at the current
/// month and spreads outwards; the peak marks fade in after them.
///
/// Months before the record begins are left empty rather than drawn at zero: nothing in
/// the document can say what they cost.
struct MonthBarsChart: View {
    let model: AppModel
    /// The month picked for Home, selected and centred; `nil` is the current month.
    var focus: Date?

    private static let monthsBack = 24
    private static let monthsAhead = 18
    private static let slot: CGFloat = 18
    private static let barWidth: CGFloat = 10
    private static let barsHeight: CGFloat = 130
    private static let axisHeight: CGFloat = 38
    private static let chartHeight: CGFloat = 168
    private static let labelStrip: CGFloat = 44

    /// The month under the pointer, which the figures follow while it is there.
    @State private var hovered: Date?
    /// The month just picked by a click, which must not scroll away from the pointer.
    @State private var clickedMonth: Date?
    @State private var grown = false
    /// When the current month's halo began breathing; nil until it starts.
    @State private var breathingSince: Date?
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.homeBuildLog) private var buildLog

    /// Grown already if this window has shown the bars before.
    private var isGrown: Bool { grown || buildLog.hasPlayed(.months) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currency: String { model.document.settings.baseCurrency }

    private var timeline: SpendTimeline { Self.timeline(model: model) }

    /// The average month over the bars that have a record, for the card's footer.
    static func averageCharged(model: AppModel) -> Decimal {
        let plotted = timeline(model: model).buckets.filter { !$0.isBeforeRecord }
        guard !plotted.isEmpty else { return 0 }
        return plotted.reduce(Decimal.zero) { $0 + $1.charged } / Decimal(plotted.count)
    }

    private static func timeline(model: AppModel) -> SpendTimeline {
        let calendar = model.calendar
        return model.ledger.timeline(
            from: MonthRange.start(of: model.today, offsetByMonths: -monthsBack, calendar: calendar),
            to: MonthRange.start(of: model.today, offsetByMonths: monthsAhead + 1, calendar: calendar),
            interval: .month
        )
    }

    var body: some View {
        let buckets = timeline.buckets
        let plotted = buckets.filter { !$0.isBeforeRecord }
        let current = buckets.first { $0.phase == .current }
        let focused = focus.flatMap { date in buckets.first { $0.start <= date && date < $0.end } } ?? current
        let selection = buckets.first { $0.start == hovered } ?? focused
        let average = plotted.isEmpty ? Decimal.zero
            : plotted.reduce(Decimal.zero) { $0 + $1.charged } / Decimal(plotted.count)
        let scale = Self.scale(for: plotted.map(\.charged).max() ?? 0)

        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)
            stats(selection, average: average)
            chart(buckets, focused: focused, selection: selection, average: average, scale: scale)
                .frame(height: Self.chartHeight)
        }
    }

    // MARK: Figures

    private func stats(_ bucket: SpendTimeline.Bucket?, average: Decimal) -> some View {
        HStack(alignment: .top, spacing: 12) {
            figure("Month") {
                if let bucket {
                    Button {
                        model.showMonth(containing: bucket.start)
                        model.section = .calendar
                    } label: {
                        HStack(spacing: 4) {
                            Text(bucket.start.formatted(.dateTime.month(.abbreviated).year()))
                            Image(systemName: "arrow.up.right").font(.system(size: 10))
                                .foregroundStyle(DS.Palette.inkMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .dsFocusRing(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
                    .help("Open in Calendar")
                    .dsStyle(.heading)
                    .fontWeight(.regular)
                } else {
                    Text(MoneyFormatting.unknown)
                }
            }
            // The three amounts share the row in quarters: one too long for its quarter
            // drops its decimals rather than end in an ellipsis (see `FittingAmount`).
            figure("Charged") {
                Group {
                    if let bucket {
                        FittingAmount(value: bucket.charged, currency: currency)
                    } else {
                        Text(MoneyFormatting.unknown)
                    }
                }
                .dsStyle(.dataLG)
                .foregroundStyle(DS.Palette.accent)
            }
            figure("Non-monthly") {
                // What the quarterly, yearly and longer plans charged that month, on top
                // of the monthly ones: a plain amount, or "None".
                nonMonthly(bucket)
                    .dsStyle(.dataLG)
            }
            figure("Vs avg") {
                Group {
                    if let bucket {
                        vsAverage(bucket.charged - average)
                    } else {
                        Text(MoneyFormatting.unknown)
                    }
                }
                .dsStyle(.dataLG)
            }
        }
    }

    private func figure<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).dsLabel()
            content()
                .foregroundStyle(DS.Palette.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Non-monthly charges for the selected month. Show the amount or a muted “None”.
    @ViewBuilder
    private func nonMonthly(_ bucket: SpendTimeline.Bucket?) -> some View {
        if let bucket {
            let amount = model.ledger.renewalsCharged(from: bucket.start, to: bucket.end)
            if amount > 0 {
                FittingAmount(value: amount, currency: currency)
            } else {
                Text("None").foregroundStyle(DS.Palette.inkMuted)
            }
        } else {
            Text(MoneyFormatting.unknown)
        }
    }

    /// "+57.910,71 €" or "−3,20 €"; the sign stays when the amount drops its decimals.
    private func vsAverage(_ delta: Decimal) -> FittingAmount {
        let rounded = Normalizer.rounded(delta)
        let sign = rounded < 0 ? "−" : "+"
        return FittingAmount(value: abs(rounded), currency: currency, prefix: sign)
    }

    // MARK: Chart

    private func chart(
        _ buckets: [SpendTimeline.Bucket],
        focused: SpendTimeline.Bucket?,
        selection: SpendTimeline.Bucket?,
        average: Decimal,
        scale: (max: Decimal, lines: [Decimal])
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // Gridlines across the whole width, under the bars.
            ForEach(scale.lines, id: \.self) { value in
                gridline
                    .offset(y: Self.chartHeight - Self.axisHeight - height(value, max: scale.max))
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    let currentIndex = buckets.firstIndex { $0.phase == .current } ?? 0
                    HStack(spacing: 0) {
                        ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                            bar(bucket, index: index, isSelected: bucket.start == selection?.start,
                                isPicked: bucket.start == focused?.start, isHovered: bucket.start == hovered,
                                distance: abs(index - currentIndex), average: average, max: scale.max)
                                .id(bucket.start)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // Leaving the bars returns the figures to the picked month.
                .onHover { inside in if !inside { hovered = nil } }
                // A trackpad tick each time the scrub lands on another month.
                .onChange(of: hovered) { _, month in if month != nil { Haptics.tick() } }
                // Grows the first time this window shows the bars (see `HomeBuildLog`).
                .onAppear {
                    if buildLog.claim(.months) {
                        grown = true
                        // The halo waits for the build to be well under way.
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.6))
                            if breathingSince == nil { breathingSince = .now }
                        }
                    } else {
                        breathingSince = .now
                    }
                }
                .onDisappear { breathingSince = nil }
                .padding(.leading, Self.labelStrip)
                .onAppear {
                    if let focused { proxy.scrollTo(focused.start, anchor: .center) }
                }
                .onChange(of: focused?.start) { _, start in
                    guard let start else { return }
                    // A click picked it: the bar is already under the pointer.
                    if start == clickedMonth {
                        clickedMonth = nil
                        return
                    }
                    clickedMonth = nil
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { proxy.scrollTo(start, anchor: .center) }
                }
            }

            // Amount labels in the clear strip.
            ForEach(scale.lines, id: \.self) { value in
                Text(MoneyFormatting.compact(value, currency: currency))
                    .dsStyle(.labelSmall)
                    .foregroundStyle(DS.Palette.inkMuted)
                    .offset(y: Self.chartHeight - Self.axisHeight - height(value, max: scale.max) - 16)
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spend by month; scroll for earlier months")
    }

    private var gridline: some View {
        Line()
            .stroke(DS.Palette.lineStrong.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
            .frame(height: 1)
            .allowsHitTesting(false)
    }

    private func bar(
        _ bucket: SpendTimeline.Bucket,
        index: Int,
        isSelected: Bool,
        isPicked: Bool,
        isHovered: Bool,
        distance: Int,
        average: Decimal,
        max: Decimal
    ) -> some View {
        let isCurrent = bucket.phase == .current
        let isJanuary = model.calendar.component(.month, from: bucket.start) == 1
        let isPeak = average > 0 && bucket.charged > average * Decimal(1.5)

        return Button {
            if !isPicked { clickedMonth = bucket.start }
            model.showMonth(containing: bucket.start)
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if !bucket.isBeforeRecord {
                    if isPeak {
                        Rectangle()
                            .fill(DS.Palette.inkMuted)
                            .frame(width: 6, height: 6)
                            .rotationEffect(.degrees(45))
                            .padding(.bottom, 5)
                            .opacity(isGrown ? 1 : 0)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(1.1), value: isGrown)
                    }
                    RoundedRectangle(cornerRadius: DS.Radius.mark, style: .continuous)
                        .fill(barColor(bucket, isPicked: isPicked, isHovered: isHovered))
                        // Hover and picking change the bar at once.
                        .animation(Motion.snap, value: isPicked)
                        .animation(Motion.snap, value: isHovered)
                        .frame(width: Self.barWidth, height: max == 0 ? 0 : height(bucket.charged, max: max))
                        .background {
                            // The glow is "now": only while now is also the picked month.
                            if isCurrent, isPicked, !reduceMotion, let breathingSince {
                                NowHalo(since: breathingSince, isRunning: activeState == .key)
                            }
                        }
                        // Data changes: the bar eases to its new height.
                        .animation(
                            reduceMotion ? nil : DSMotion.easeOutCubic(0.5),
                            value: max == 0 ? 0 : height(bucket.charged, max: max)
                        )
                        // Grows from the baseline: 120 ms, then 45 ms per month from today.
                        .scaleEffect(x: 1, y: isGrown ? 1 : 0, anchor: .bottom)
                        .animation(
                            reduceMotion ? nil : DSMotion.grow.delay(0.12 + 0.045 * Double(distance)),
                            value: isGrown
                        )
                }
                Rectangle().fill(DS.Palette.line).frame(width: Self.slot, height: 1)
                // The letter follows the picked bar, so only one thing on the axis is
                // orange. Away from it, the current month's letter is ink with a small
                // ink square under it: a neutral "today" mark.
                Text(monthLetter(bucket.start))
                    .dsStyle(.label)
                    .tracking(0)
                    .foregroundStyle(isPicked ? DS.Palette.accent : isCurrent ? DS.Palette.ink : DS.Palette.inkMuted)
                    .frame(height: 16)
                    .overlay(alignment: .bottom) {
                        if isCurrent, !isPicked {
                            Rectangle()
                                .fill(DS.Palette.ink)
                                .frame(width: 3, height: 3)
                                .offset(y: 3)
                                .accessibilityHidden(true)
                        }
                    }
                    .animation(Motion.snap, value: isPicked)
                    .padding(.top, 5)
                Text(isJanuary || index == 0 ? String(model.calendar.component(.year, from: bucket.start)) : "")
                    .dsStyle(.labelSmall)
                    .foregroundStyle(DS.Palette.inkDisabled)
                    .fixedSize()
                    .frame(width: Self.slot, height: 16, alignment: .leading)
                    .padding(.leading, 4)
            }
            .frame(width: Self.slot, height: Self.chartHeight)
            .overlay(alignment: .top) {
                // The scrub line, on whichever month the figures describe.
                Rectangle()
                    .fill(DS.Palette.inkMuted)
                    .frame(width: 1, height: Self.chartHeight - Self.axisHeight)
                    .opacity(isSelected ? 0.6 : 0)
                    .animation(Motion.snap, value: isSelected)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { hovered = bucket.start } }
        .dsFocusRing(RoundedRectangle(cornerRadius: DS.Radius.mark, style: .continuous))
        .accessibilityLabel("\(bucket.start.formatted(.dateTime.month(.wide).year())), \(MoneyFormatting.amount(bucket.charged, currency: currency))")
    }

    /// The locale's narrow month name ("N"). Some locales (POSIX among them) answer
    /// with a number, which reads as a count on this axis, so those fall back to the
    /// first letter of the short name.
    private func monthLetter(_ date: Date) -> String {
        let style = Date.FormatStyle(calendar: model.calendar, timeZone: model.calendar.timeZone)
        let narrow = date.formatted(style.month(.narrow))
        guard narrow.allSatisfy(\.isNumber) else { return narrow }
        return String(date.formatted(style.month(.abbreviated)).prefix(1)).uppercased()
    }

    /// Orange for the picked month, ink under the pointer; otherwise past bars light
    /// (the current month among them) and future bars dim.
    private func barColor(_ bucket: SpendTimeline.Bucket, isPicked: Bool, isHovered: Bool) -> Color {
        if isPicked { return DS.Palette.accent }
        if isHovered { return DS.Palette.ink }
        switch bucket.phase {
        case .past, .current: return DS.Palette.inkMuted.opacity(0.75)
        case .future: return DS.Palette.lineStrong.opacity(0.55)
        }
    }

    private func height(_ value: Decimal, max: Decimal) -> CGFloat {
        guard max > 0 else { return 0 }
        let ratio = NSDecimalNumber(decimal: value / max).doubleValue
        return CGFloat(ratio) * Self.barsHeight
    }

    /// The chart's ceiling and its gridlines.
    ///
    /// As in the prototype (lines at 100, 200, 300 on a 420 scale): the ceiling leaves
    /// room above the tallest bar for its peak mark, the step is a round number about a
    /// quarter of the ceiling, and only the lines in the lower three quarters are drawn,
    /// so the top line and its label stay well clear of the figures above the chart.
    private static func scale(for maximum: Decimal) -> (max: Decimal, lines: [Decimal]) {
        let top = NSDecimalNumber(decimal: maximum).doubleValue
        guard top > 0 else { return (0, []) }
        let ceiling = top * 1.12
        let rough = ceiling / 4.2
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0].map { $0 * magnitude }.first { $0 >= rough } ?? rough
        let lines = (1...3).map { Double($0) * step }.filter { $0 <= ceiling * 0.8 }
        return (Decimal(ceiling), lines.map { Decimal($0) })
    }
}

/// A horizontal line across its frame.
/// The current month's "now" breathing: a soft orange halo around the bar, which itself
/// never changes. One breath every 3.6 s, easing in and out: full at a quarter of the
/// cycle, gone by 55%, then rest. The only looping motion in the app;
/// it stops while the window is not key, and never runs with Reduce Motion.
///
/// A blurred copy of the bar 2pt larger, under it: CSS `0 0 12px 2px` at 55% at most.
struct NowHalo: View {
    let since: Date
    let isRunning: Bool

    private static let cycle: TimeInterval = 3.6
    private static let peak = 0.55

    var body: some View {
        TimelineView(.animation(paused: !isRunning)) { context in
            RoundedRectangle(cornerRadius: DS.Radius.mark, style: .continuous)
                .fill(DS.Palette.accent)
                .padding(-2)
                .blur(radius: 6)
                .opacity(isRunning ? Self.peak * Self.breath(at: context.date.timeIntervalSince(since)) : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 0…1 over one cycle: in until 25%, out until 55%, then nothing.
    static func breath(at elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        let phase = elapsed.truncatingRemainder(dividingBy: cycle) / cycle
        func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        switch phase {
        case ..<0.25: return smooth(phase / 0.25)
        case ..<0.55: return 1 - smooth((phase - 0.25) / 0.30)
        default: return 0
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
