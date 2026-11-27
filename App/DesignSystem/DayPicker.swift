import SwiftUI

/// A month of days to pick one from, with two zoomed-out levels for jumping far.
///
/// Days: the month and year as a button with a chevron, ‹ › on the right; the locale's
/// weekdays; a 7 × 6 grid of 30pt cells (this month's days on `bg300`, the neighbours'
/// days bare and dim but still clickable); the picked day in accent tint with an accent
/// border; today marked by a 3pt orange square. The footer has Today and, where an
/// empty date is allowed, Clear.
///
/// Clicking the title zooms out: to the 12 months of that year, then to 12 years in
/// blocks aligned to 2016 (2004–2015, 2016–2027, …). ‹ › step by the level's unit (a
/// month, a year, twelve years). Picking a year shows its months, picking a month shows
/// its days; the value changes only when a day, Today or Clear is picked. The grid area
/// keeps one height, so the popover never changes size between levels.
///
/// It opens on the days of its own value's month, or of this month when there is none.
struct DayPicker: View {
    @Binding var date: Date
    /// Whether `date` holds a value; false means "no date".
    @Binding var isSet: Bool
    /// Offer Clear (only where an empty date is allowed).
    var allowsClear = false
    let today: Date
    let calendar: Calendar
    let onDone: () -> Void

    private enum Level: Int { case days, months, years }

    @State private var level: Level = .days
    /// The first day of the month being looked at; its year drives the months level.
    @State private var month: Date
    /// Which way the last level change went, for the incoming level's scale.
    @State private var zoomingOut = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Every level reserves 14pt for weekdays, a 10pt gap, six 30pt rows and five 4pt gaps.
    private static let gridAreaHeight: CGFloat = 224
    private static let zoomCurve = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.2)
    /// Year blocks start on years like 2016.
    private static let yearBlockOrigin = 2016

    init(
        date: Binding<Date>,
        isSet: Binding<Bool>,
        allowsClear: Bool = false,
        today: Date,
        calendar: Calendar,
        onDone: @escaping () -> Void
    ) {
        _date = date
        _isSet = isSet
        self.allowsClear = allowsClear
        self.today = today
        self.calendar = calendar
        self.onDone = onDone
        let anchor = isSet.wrappedValue ? date.wrappedValue : today
        _month = State(initialValue: Self.monthStart(of: anchor, calendar: calendar))
    }

    private static func monthStart(of date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ZStack(alignment: .top) {
                switch level {
                case .days:
                    days.transition(levelTransition)
                case .months:
                    months.transition(levelTransition)
                case .years:
                    years.transition(levelTransition)
                }
            }
            .frame(height: Self.gridAreaHeight, alignment: .top)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 272)
        .background(DS.Palette.bg200)
        .onExitCommand { onDone() }
    }

    // MARK: Levels

    private var levelTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        // Zooming out, the wider level settles down from slightly large; zooming in,
        // the closer one grows from slightly small.
        return .asymmetric(
            insertion: .scale(scale: zoomingOut ? 1.08 : 0.92).combined(with: .opacity),
            removal: .opacity
        )
    }

    private func show(_ newLevel: Level) {
        zoomingOut = newLevel.rawValue > level.rawValue
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.zoomCurve) { level = newLevel }
    }

    private var year: Int { calendar.component(.year, from: month) }

    private var yearBlock: ClosedRange<Int> {
        let offset = year - Self.yearBlockOrigin
        let start = Self.yearBlockOrigin + Int((Double(offset) / 12).rounded(.down)) * 12
        return start...(start + 11)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            title
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(DSIconButtonStyle(size: 30))
                .dsFocusRing(Circle())
                .accessibilityLabel(stepLabel(-1))
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(DSIconButtonStyle(size: 30))
                .dsFocusRing(Circle())
                .accessibilityLabel(stepLabel(1))
        }
    }

    @ViewBuilder
    private var title: some View {
        switch level {
        case .days:
            TitleButton(text: month.formatted(dateStyle.month(.wide).year())) { show(.months) }
                .accessibilityHint("Shows the months")
        case .months:
            TitleButton(text: String(year)) { show(.years) }
                .accessibilityHint("Shows the years")
        case .years:
            Text("\(String(yearBlock.lowerBound)) – \(String(yearBlock.upperBound))")
                .font(DSFonts.font(DSFonts.sansMedium, size: 17))
                .monospacedDigit()
                .foregroundStyle(DS.Palette.ink)
                .frame(height: 30)
        }
    }

    private func step(_ direction: Int) {
        let months = switch level {
        case .days: 1
        case .months: 12
        case .years: 144
        }
        month = calendar.date(byAdding: .month, value: direction * months, to: month) ?? month
    }

    private func stepLabel(_ direction: Int) -> String {
        switch level {
        case .days: direction < 0 ? "Previous month" : "Next month"
        case .months: direction < 0 ? "Previous year" : "Next year"
        case .years: direction < 0 ? "Earlier years" : "Later years"
        }
    }

    // MARK: Days

    private var days: some View {
        VStack(spacing: 10) {
            weekdays.frame(height: 14)
            dayGrid
        }
    }

    private var weekdays: some View {
        let symbols = calendar.shortStandaloneWeekdaySymbols.map { String($0.prefix(2)) }
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 4) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(DSFonts.font(DSFonts.monoMedium, size: 10))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Palette.inkDisabled)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var dayDates: [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: month) ?? month
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var dayGrid: some View {
        let days = dayDates
        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<6, id: \.self) { week in
                GridRow {
                    ForEach(0..<7, id: \.self) { weekday in
                        cell(days[week * 7 + weekday])
                    }
                }
            }
        }
    }

    private func cell(_ day: Date) -> some View {
        DayCell(
            label: day.formatted(dateStyle.day()),
            isInMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
            isSelected: isSet && calendar.isDate(day, inSameDayAs: date),
            isToday: calendar.isDate(day, inSameDayAs: today)
        ) {
            pick(day)
        }
        .accessibilityLabel(day.formatted(
            Date.FormatStyle(date: .complete, time: .omitted, calendar: calendar, timeZone: calendar.timeZone)
        ))
    }

    private func pick(_ day: Date) {
        date = calendar.startOfDay(for: day)
        isSet = true
        onDone()
    }

    // MARK: Months

    private var months: some View {
        let shown = year
        let selectedMonth = isSet ? Self.monthStart(of: date, calendar: calendar) : nil
        let thisMonth = Self.monthStart(of: today, calendar: calendar)
        return ZoomGrid(items: (1...12).compactMap { calendar.date(from: DateComponents(year: shown, month: $0, day: 1)) }) { start in
            ZoomCell(
                label: start.formatted(dateStyle.month(.abbreviated)).uppercased(),
                font: DSFonts.font(DSFonts.monoMedium, size: 13),
                tracking: 0.8,
                isSelected: start == selectedMonth,
                isCurrent: start == thisMonth
            ) {
                month = start
                show(.days)
            }
            .accessibilityLabel(start.formatted(dateStyle.month(.wide).year()))
        }
    }

    // MARK: Years

    private var years: some View {
        let selectedYear = isSet ? calendar.component(.year, from: date) : nil
        let thisYear = calendar.component(.year, from: today)
        let monthOfYear = calendar.component(.month, from: month)
        return ZoomGrid(items: Array(yearBlock)) { value in
            ZoomCell(
                label: String(value),
                font: DSFonts.font(DSFonts.monoRegular, size: 14),
                tracking: 0,
                isSelected: value == selectedYear,
                isCurrent: value == thisYear
            ) {
                month = calendar.date(from: DateComponents(year: value, month: monthOfYear, day: 1)) ?? month
                show(.months)
            }
            .accessibilityLabel(String(value))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if allowsClear, isSet {
                Button("Clear") {
                    isSet = false
                    onDone()
                }
                .buttonStyle(.plain)
                .font(DSFonts.font(DSFonts.monoRegular, size: 13))
                .foregroundStyle(DS.Palette.inkMuted)
                .dsFocusRing(RoundedRectangle(cornerRadius: DS.Radius.xs))
            }
            Spacer()
            Button("Today") { pick(today) }
                .buttonStyle(DSSecondaryButtonStyle(height: 28, mono: true))
                .dsFocusRing(Capsule())
        }
        .padding(.top, 2)
    }
}

/// The title at the days and months levels: the text and a chevron, `bg300` on hover.
private struct TitleButton: View {
    let text: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text)
                    .font(DSFonts.font(DSFonts.sansMedium, size: 17))
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(DS.Palette.inkMuted)
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? DS.Palette.bg300 : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .dsFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        // The picker's title row starts flush with the grid: pull the hover fill out.
        .padding(.leading, -6)
    }
}

/// Twelve cells, three across and four down, with 6pt gaps.
private struct ZoomGrid<Item: Hashable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<4, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let index = row * 3 + column
                        if items.indices.contains(index) { cell(items[index]) }
                    }
                }
            }
        }
    }
}

/// A month or a year: 50pt tall, 10pt corners, `bg300` (`bg400` on hover); the picked
/// one in accent tint with an accent border and accent text; the current one, when not
/// picked, marked by the 3pt orange square.
private struct ZoomCell: View {
    let label: String
    let font: Font
    let tracking: CGFloat
    let isSelected: Bool
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            Text(label)
                .font(font)
                .tracking(tracking)
                .monospacedDigit()
                .foregroundStyle(isSelected ? DS.Palette.accent : DS.Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(shape.fill(isSelected ? DS.Palette.accentTint : isHovering ? DS.Palette.bg400 : DS.Palette.bg300))
                .overlay(shape.strokeBorder(isSelected ? DS.Palette.accent : .clear, lineWidth: DS.hairline))
                .overlay(alignment: .bottom) {
                    if isCurrent, !isSelected {
                        Rectangle().fill(DS.Palette.accent).frame(width: 3, height: 3).padding(.bottom, 7)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .dsFocusRing(shape)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One day: 30pt, 8pt corners, mono 13 / 500.
private struct DayCell: View {
    let label: String
    let isInMonth: Bool
    let isSelected: Bool
    let isToday: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DSFonts.font(DSFonts.monoMedium, size: 13))
                .monospacedDigit()
                .foregroundStyle(isSelected ? DS.Palette.accent : isInMonth ? DS.Palette.ink : DS.Palette.inkDisabled)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? DS.Palette.accent : .clear, lineWidth: DS.hairline)
                )
                .overlay(alignment: .bottom) {
                    if isToday, !isSelected {
                        Rectangle().fill(DS.Palette.accent).frame(width: 3, height: 3).padding(.bottom, 4)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .dsFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if isSelected { return DS.Palette.accentTint }
        if isHovering { return isInMonth ? DS.Palette.bg400 : DS.Palette.bg300 }
        return isInMonth ? DS.Palette.bg300 : .clear
    }
}

#Preview("Day picker") {
    @Previewable @State var date = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 25))!
    @Previewable @State var isSet = true
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2
    return DayPicker(
        date: $date,
        isSet: $isSet,
        allowsClear: true,
        today: Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 9))!,
        calendar: calendar,
        onDone: {}
    )
}
