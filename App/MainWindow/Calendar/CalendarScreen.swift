import AppKit
import SwiftUI
import OboloCore

/// Calendar: one month at a time, in the instrument style.
///
/// The month name with the year beside it, Today and ‹ › on the right; weekday pills; a
/// 7 × 6 grid of day cells; and the Monthly / Yearly key with the month's count and total.
/// A day shows the logos of what charges on it and a square marker for the cycle
/// (violet monthly, yellow for anything longer). Clicking a day puts its payments in
/// the bottom bar's status line; clicking it again clears that.
///
/// The arrows, scroll wheel and swipe gesture change the month. Select a day to see its payments in the status line.
///
/// Days outside the month are hatched and inert: hatching means "outside the range" and
/// nothing else.
struct CalendarScreen: View {
    @Bindable var model: AppModel

    /// Where the day grids sit, animated by its own clock so that a new press or swipe can
    /// pick up from exactly where the last one is.
    @State private var slide = MonthSlide()
    /// One page: the grid's card-wide frame, so neighbours come in from the card's edge.
    @State private var pageWidth: CGFloat = 560
    /// Which way the title last moved: 1 a later month, -1 an earlier one.
    @State private var titleDirection = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { model.calendar }
    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    }
    private var currency: String { model.document.settings.baseCurrency }

    /// The first day of the month on screen.
    private var month: Date { model.shownMonth }

    /// The title's move: about 8pt in the grid's direction, crossfading.
    private static let titleCurve = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.3)

    var body: some View {
        VStack(spacing: 0) {
            Group {
                header
                    .padding(.leading, 6)
                    .padding(.bottom, 12)

                weekdays
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, 16)

            // Only the days move; the title row and the weekdays stay put. The pages run
            // to the card's edges and are cut there, so nothing slides over other UI.
            pager

            key
                .padding(.top, 12)
                .padding(.horizontal, 22)
        }
        .padding(.vertical, 14)
        .background(scrollStepper)
        .accessibilityIdentifier("calendar")
    }

    private var scrollStepper: MonthScrollStepper {
        let onSwipe: ((MonthScrollStepper.SwipePhase) -> Void)? = reduceMotion ? nil : { swipe($0) }
        // A scroll that turns the month gives one trackpad step; the arrows and keys don't.
        return MonthScrollStepper(onStep: { direction in
            if direction != 0 { Haptics.step() }
            step(direction)
        }, onSwipe: onSwipe)
    }

    // MARK: - Moving between months

    /// One month back or forward, from the arrows, the keys, the wheel or a scroll: the
    /// grid slides the new month in from that side over 0.3 s. A press while a slide is
    /// still running takes the next month from wherever the grid is.
    private func step(_ direction: Int) {
        move(direction) { direction < 0 ? model.showPrevious() : model.showNext() }
    }

    /// Changes the month with `change`, sliding the grid by one page in `direction`.
    private func move(_ direction: Int, _ change: () -> Void) {
        guard direction != 0 else { return }
        titleDirection = direction
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { change() }
            return
        }
        let from = slide.current
        withAnimation(Self.titleCurve) { change() }
        // The month that was showing is now one page back: keep it where it is and
        // ease everything home from there.
        slide.settle(from: from + CGFloat(direction) * pageWidth, velocity: 0, kind: .curve)
    }

    private func showToday() {
        let todayMonth = MonthRange.start(of: model.today, calendar: calendar)
        let direction = todayMonth > month ? 1 : todayMonth < month ? -1 : 0
        move(direction) { model.showCurrentMonth() }
    }

    /// A two-finger swipe: the grid follows the fingers, and on release coasts on with
    /// their speed and settles on the nearest month. A fast swipe can cross several months.
    private func swipe(_ phase: MonthScrollStepper.SwipePhase) {
        switch phase {
        case .began:
            slide.hold()
        case .changed(let dx):
            slide.drag(by: dx, limit: pageWidth * CGFloat(Self.maxFlingMonths))
        case .ended(let velocity):
            // Where the grid would coast to if it kept the fingers' speed and slowed
            // like a scroll view, then the month nearest that: a gentle drag past
            // halfway turns one page, a hard flick can carry several.
            let offset = slide.current
            let coast = offset + velocity * Self.coastFactor
            let pages = min(Self.maxFlingMonths, max(-Self.maxFlingMonths, Int((-coast / pageWidth).rounded())))
            if pages != 0 {
                Haptics.step()
                titleDirection = pages > 0 ? 1 : -1
                let target = calendar.date(byAdding: .month, value: pages, to: month) ?? month
                withAnimation(Self.titleCurve) { model.showMonth(containing: target) }
            }
            slide.settle(from: offset + CGFloat(pages) * pageWidth, velocity: velocity, kind: .spring)
        }
    }

    /// How far a release coasts per point-per-second: a scroll view's normal
    /// deceleration (0.998 a millisecond) gives about half a second's travel.
    private static let coastFactor: CGFloat = 0.998 / (1 - 0.998) / 1000
    /// The most one fling can turn.
    private static let maxFlingMonths = 12

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Text("\(Text(month.formatted(dateStyle.month(.wide))).foregroundStyle(DS.Palette.ink)) \(Text(month.formatted(dateStyle.year())).foregroundStyle(DS.Palette.inkMuted).font(DSFonts.font(DSFonts.sansRegular, size: 22)))")
                    .font(DSFonts.font(DSFonts.sansMedium, size: 22))
                    .tracking(-0.22)
                    .lineLimit(1)
                    .id(month)
                    .transition(titleTransition)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Button("Today") { showToday() }
                .buttonStyle(DSSecondaryButtonStyle(height: 30, mono: true))
                .dsFocusRing(Capsule())
                .disabled(model.isShowingCurrentMonth)
                .keyboardShortcut("t", modifiers: [.command])
                .help("Go to this month")

            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(DSIconButtonStyle(size: 30))
                .dsFocusRing(Circle())
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous month")
                .accessibilityLabel("Previous month")

            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(DSIconButtonStyle(size: 30))
                .dsFocusRing(Circle())
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next month")
                .accessibilityLabel("Next month")
        }
    }

    private var titleTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let shift = CGFloat(titleDirection) * 8
        return .asymmetric(
            insertion: .offset(x: shift).combined(with: .opacity),
            removal: .offset(x: -shift).combined(with: .opacity)
        )
    }

    // MARK: - Weekdays

    /// The locale's week, starting on its first weekday.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var weekdays: some View {
        HStack(spacing: 6) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .dsLabel()
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(Capsule().fill(DS.Palette.bg300))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Pager

    @ViewBuilder
    private var pager: some View {
        if reduceMotion {
            // Reduce Motion: the month fades, as before.
            CalendarMonthGrid(model: model, month: month, isCurrent: true)
                .padding(.horizontal, 16)
                .id(month)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Read here so that a drag or a new slide redraws the pager.
            let isAnimating = slide.isAnimating
            let _ = slide.resting
            let month = month
            let width = pageWidth
            TimelineView(.animation(paused: !isAnimating)) { context in
                let offset = slide.value(at: context.date)
                ZStack {
                    // The month on screen and whichever neighbours are in view.
                    ForEach(Self.pages(offset: offset, width: width), id: \.self) { page in
                        let pageMonth = calendar.date(byAdding: .month, value: page, to: month) ?? month
                        CalendarMonthGrid(model: model, month: pageMonth, isCurrent: page == 0)
                            .padding(.horizontal, 16)
                            .frame(width: width)
                            .offset(x: CGFloat(page) * width + offset)
                            .transition(.identity)
                            .id(pageMonth)
                            .allowsHitTesting(page == 0)
                            .accessibilityHidden(page != 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = max(1, $0) }
        }
    }

    /// The pages (months from the one on screen) that overlap the card at `offset`.
    private static func pages(offset: CGFloat, width: CGFloat) -> [Int] {
        // Page k sits at k × width + offset; only those overlapping the card are drawn,
        // however far a fling has carried the grid.
        let first = Int(((-offset - width) / width).rounded(.down))
        let last = Int(((-offset + width) / width).rounded(.up))
        return (first...last).filter { abs(CGFloat($0) * width + offset) < width - 0.5 }
    }

    // MARK: - Key

    private var key: some View {
        let total = model.calendarMonthTotal
        return HStack(spacing: 16) {
            keyItem("Monthly", DS.CategoryColor.violet)
            keyItem("Yearly", DS.Palette.cycleYearly)
            Spacer(minLength: 8)
            // A month with nothing in it says so rather than "0 payments · 0,00 €".
            Group {
                if total.count == 0 {
                    Text("No payments this month")
                } else {
                    // A charge with no rate is left out of the money and counted, as on
                    // Home; with nothing to convert the amount is "-", never 0.
                    let amount = total.excludedCount == total.count
                        ? MoneyFormatting.unknown
                        : MoneyFormatting.amount(total.charged, currency: currency)
                    let excluded = total.excludedCount > 0
                        ? Text("\(Text("\(total.excludedCount)").foregroundStyle(DS.Palette.warning)) without a rate · ")
                        : Text("")
                    Text("\(Text.ink("\(total.count)")) \(total.count == 1 ? "payment" : "payments") · \(excluded)\(Text.ink(amount))")
                }
            }
            .dsLabel()
            .lineLimit(1)
        }
    }

    private func keyItem(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            CategoryMarker(color: color, size: 8)
            Text(title).dsLabel()
        }
    }
}

// MARK: - Month grid

/// One month's 7 × 6 days: the month, with the end of the one before and the start of the
/// one after filling the first and last weeks. Its own view, so that sliding it only
/// moves it and does not ask the ledger again.
private struct CalendarMonthGrid: View {
    let model: AppModel
    let month: Date
    /// The month on screen, the only one whose days can be picked.
    let isCurrent: Bool

    private var calendar: Calendar { model.calendar }

    private var days: [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: month) ?? month
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        // One query for the whole month, then grouped by day.
        let end = calendar.date(byAdding: .month, value: 1, to: month) ?? month
        let byDay = Dictionary(grouping: model.ledger.occurrences(from: month, to: end)) {
            calendar.startOfDay(for: $0.date)
        }
        let today = calendar.startOfDay(for: model.today)
        let days = days

        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<6, id: \.self) { week in
                GridRow {
                    ForEach(0..<7, id: \.self) { weekday in
                        let day = days[week * 7 + weekday]
                        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
                        CalendarDayCell(
                            model: model,
                            day: day,
                            occurrences: inMonth ? (byDay[day] ?? []) : [],
                            isInMonth: inMonth,
                            isToday: day == today,
                            isSelected: isCurrent && inMonth && model.selectedCalendarDay == day
                        )
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Slide

/// The day grids' horizontal offset, in points from rest, with its own clock.
///
/// SwiftUI does not say where an animation has got to, and a press or a swipe in the
/// middle of a slide has to start from exactly there; so the offset is a function of
/// time that the pager samples each frame. It always comes home to 0: either along
/// cubic-bezier(.32,.72,0,1) over 0.3 s, or on a critically damped spring that starts
/// with the fingers' velocity and never overshoots.
@MainActor @Observable
final class MonthSlide {
    enum Kind { case curve, spring }

    private struct Run {
        let start: Date
        let from: CGFloat
        let velocity: CGFloat
        let kind: Kind
    }

    /// The offset while nothing runs: 0 at rest, or wherever the fingers have it.
    private(set) var resting: CGFloat = 0
    private var run: Run?
    private var generation = 0

    var isAnimating: Bool { run != nil }

    var current: CGFloat { value(at: .now) }

    private static let duration: TimeInterval = 0.3
    /// Critically damped: settles in about half a second and, released towards the
    /// month it coasts to, does not cross 0.
    private static let stiffness: Double = 14
    private static let springLength: TimeInterval = 1.0
    private static let curve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.32, y: 0.72), endControlPoint: UnitPoint(x: 0, y: 1))

    func value(at date: Date) -> CGFloat {
        guard let run else { return resting }
        let t = max(0, date.timeIntervalSince(run.start))
        switch run.kind {
        case .curve:
            guard t < Self.duration else { return 0 }
            return run.from * (1 - CGFloat(Self.curve.value(at: t / Self.duration)))
        case .spring:
            let w = Self.stiffness
            let x = (Double(run.from) + (Double(run.velocity) + w * Double(run.from)) * t) * exp(-w * t)
            return abs(x) < 0.25 ? 0 : CGFloat(x)
        }
    }

    /// Stops wherever the grid is, for fingers that land mid-slide.
    func hold() {
        resting = current
        run = nil
        generation += 1
    }

    func drag(by dx: CGFloat, limit: CGFloat) {
        resting = min(limit, max(-limit, resting + dx))
    }

    /// Eases from `from` (points from rest) home to 0.
    func settle(from: CGFloat, velocity: CGFloat, kind: Kind) {
        resting = 0
        generation += 1
        guard abs(from) > 0.5 else {
            run = nil
            return
        }
        run = Run(start: .now, from: from, velocity: velocity, kind: kind)
        let generation = generation
        let length = kind == .curve ? Self.duration : Self.springLength
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(length + 0.05))
            guard let self, self.generation == generation else { return }
            self.run = nil
        }
    }
}

// MARK: - Day

private struct CalendarDayCell: View {
    let model: AppModel
    let day: Date
    let occurrences: [RenewalOccurrence]
    let isInMonth: Bool
    let isToday: Bool
    let isSelected: Bool

    @Environment(\.self) private var environment

    private static let maxLogos = 3

    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(calendar: model.calendar, timeZone: model.calendar.timeZone)
    }

    private var subscriptions: [Subscription] {
        occurrences.compactMap { model.subscription($0.subscriptionID) }
    }

    var body: some View {
        let subscriptions = subscriptions
        Button {
            model.selectCalendarDay(day)
        } label: {
            VStack(spacing: 3) {
                Text(day.formatted(dateStyle.day()))
                    .dsStyle(.data)
                    .font(DSFonts.font(DSFonts.monoRegular, size: 13))
                    .foregroundStyle(numberColor(hasPayments: !subscriptions.isEmpty))
                    .frame(height: 18)
                if !subscriptions.isEmpty {
                    logos(subscriptions)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .overlay(alignment: .topTrailing) { markers(subscriptions) }
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: DS.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .dsFocusRing(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .disabled(!isInMonth)
        .accessibilityLabel(accessibilityText(subscriptions))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
        if !isInMonth {
            // Outside the month: hatched, the one meaning hatching has.
            shape.fill(DS.Palette.bg200)
                .overlay(Hatching().stroke(DS.Palette.line, lineWidth: 1).clipShape(shape))
        } else {
            shape.fill(dayFill)
        }
    }

    private var dayFill: Color { isToday ? DS.Palette.accentTint : DS.Palette.bg300 }

    private var borderColor: Color {
        if isToday { return DS.Palette.accent }
        if isSelected { return DS.Palette.inkMuted }
        return .clear
    }

    private func numberColor(hasPayments: Bool) -> Color {
        if !isInMonth { return DS.Palette.inkDisabled }
        if isToday { return DS.Palette.accent }
        return hasPayments ? DS.Palette.ink : DS.Palette.inkMuted
    }

    /// Up to three logos side by side. More than three uses two logos and a "+N".
    private func logos(_ subscriptions: [Subscription]) -> some View {
        let overflow = subscriptions.count > Self.maxLogos
        let shown = overflow ? Array(subscriptions.prefix(Self.maxLogos - 1)) : subscriptions
        let size: CGFloat = subscriptions.count >= Self.maxLogos ? 18 : 22
        let canvas = CalendarLogo.Canvas(
            background: dayFill.resolve(in: environment),
            prefersDarkVariant: environment.colorScheme == .dark
        )
        return HStack(spacing: 2) {
            ForEach(shown) { subscription in
                // The letter tile and the "+N" chip share a bg400 fill on the day cell.
                SubscriptionIcon(
                    subscription: subscription,
                    size: size,
                    isCancelled: subscription.status == .cancelled,
                    fallbackFill: DS.Palette.bg400,
                    calendarCanvas: canvas
                )
            }
            if overflow {
                Text("+\(subscriptions.count - shown.count)")
                    .font(DSFonts.font(DSFonts.monoMedium, size: 9))
                    .foregroundStyle(DS.Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: size, height: size)
                    .background(SubscriptionIcon.shape(size: size).fill(DS.Palette.bg400))
                    .overlay(SubscriptionIcon.shape(size: size).strokeBorder(DS.Palette.bg200, lineWidth: 1))
            }
        }
    }

    /// The cycle markers in the top-right corner, one per legend group the day has, in
    /// the legend's order: violet for Monthly (weekly and monthly), then yellow for
    /// Yearly (anything longer than a month: quarterly, yearly, every two years,
    /// custom). Two charges in one group still show one marker.
    @ViewBuilder
    private func markers(_ subscriptions: [Subscription]) -> some View {
        let monthly = subscriptions.contains { ($0.cycle.months ?? 0) <= 1 }
        let longer = subscriptions.contains { ($0.cycle.months ?? 0) > 1 }
        if monthly || longer {
            HStack(spacing: 3) {
                if monthly { CategoryMarker(color: DS.CategoryColor.violet, size: DS.Size.markerSmall) }
                if longer { CategoryMarker(color: DS.Palette.cycleYearly, size: DS.Size.markerSmall) }
            }
            .padding(8)
        }
    }

    private func accessibilityText(_ subscriptions: [Subscription]) -> String {
        let date = day.formatted(dateStyle.day().month(.wide))
        guard !subscriptions.isEmpty else { return date }
        return date + ", " + subscriptions.map(\.name).joined(separator: " and ")
    }
}

/// 1pt diagonal lines at 135°, 8pt apart.
private struct Hatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let pitch: CGFloat = 8
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += pitch
        }
        return path
    }
}

// MARK: - Scroll to change month

/// Turns a scroll or a swipe over the calendar into month changes.
///
/// A horizontal two-finger swipe on a trackpad is handed over as it happens, for the
/// grid to follow the fingers; its momentum is ignored. Any other trackpad scroll steps
/// once, when it has travelled far enough, and not again until the fingers lift. A mouse
/// wheel steps once per notch, with a short pause so a fast spin does not race through
/// a year.
struct MonthScrollStepper: NSViewRepresentable {
    enum SwipePhase {
        case began
        /// Points moved since the last change, in the content's direction.
        case changed(CGFloat)
        /// Points per second at release, in the content's direction.
        case ended(velocity: CGFloat)
    }

    let onStep: (Int) -> Void
    /// Without it (Reduce Motion) a horizontal swipe steps like any other scroll.
    var onSwipe: ((SwipePhase) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onStep: onStep, onSwipe: onSwipe) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onStep = onStep
        context.coordinator.onSwipe = onSwipe
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var onStep: (Int) -> Void
        var onSwipe: ((SwipePhase) -> Void)?
        private weak var view: NSView?
        private var monitor: Any?

        private enum Gesture { case undecided, swiping, stepping }
        private var gesture: Gesture = .undecided
        private var travelled: CGFloat = 0
        private var steppedThisGesture = false
        /// Recent horizontal moves, for the velocity at release.
        private var recent: [(time: TimeInterval, dx: CGFloat)] = []
        private var lastWheelStep = Date.distantPast

        private static let threshold: CGFloat = 40
        private static let wheelPause: TimeInterval = 0.2

        init(onStep: @escaping (Int) -> Void, onSwipe: ((SwipePhase) -> Void)?) {
            self.onStep = onStep
            self.onSwipe = onSwipe
        }

        func attach(to view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns true when the event was used here.
        private func handle(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            // A gesture already under way keeps going even if the pointer leaves.
            guard view.bounds.contains(point) || gesture == .swiping else { return false }

            if event.hasPreciseScrollingDeltas {
                trackpad(event)
                return true
            }

            // The dominant axis: down or left is forward in time.
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                ? event.scrollingDeltaY : event.scrollingDeltaX
            guard delta != 0, Date().timeIntervalSince(lastWheelStep) > Self.wheelPause else { return true }
            lastWheelStep = Date()
            onStep(delta < 0 ? 1 : -1)
            return true
        }

        private func trackpad(_ event: NSEvent) {
            // Momentum after the fingers lift belongs to nobody.
            guard event.momentumPhase == [] else { return }

            if event.phase == .began || event.phase == .mayBegin {
                gesture = .undecided
                travelled = 0
                steppedThisGesture = false
                recent = []
            }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            if gesture == .undecided, abs(dx) + abs(dy) > 1 {
                if abs(dx) > abs(dy), let onSwipe {
                    gesture = .swiping
                    onSwipe(.began)
                } else {
                    gesture = .stepping
                }
            }

            switch gesture {
            case .swiping:
                if dx != 0 {
                    onSwipe?(.changed(dx))
                    recent.append((event.timestamp, dx))
                    recent.removeAll { event.timestamp - $0.time > 0.08 }
                }
            case .stepping:
                let delta = abs(dy) >= abs(dx) ? dy : dx
                travelled += abs(delta)
                if !steppedThisGesture, travelled > Self.threshold {
                    steppedThisGesture = true
                    onStep(delta < 0 ? 1 : -1)
                }
            case .undecided:
                break
            }

            if event.phase == .ended || event.phase == .cancelled {
                if gesture == .swiping {
                    onSwipe?(.ended(velocity: velocity(at: event.timestamp)))
                }
                gesture = .undecided
                travelled = 0
                steppedThisGesture = false
                recent = []
            }
        }

        private func velocity(at time: TimeInterval) -> CGFloat {
            let window = recent.filter { time - $0.time <= 0.08 }
            guard let first = window.first, window.count > 1 else { return 0 }
            let span = max(0.016, time - first.time)
            return window.reduce(0) { $0 + $1.dx } / CGFloat(span)
        }
    }
}

#Preview("Calendar") {
    let model = AppModel.handoffPreview()
    model.section = .calendar
    return MainWindow(model: model)
}
