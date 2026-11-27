import AppKit
import SwiftUI
import OboloCore

// MARK: - Sections

/// The three places the window switch goes to.
///
/// The model has more `Section`s than the switch has places. Home and Calendar are
/// one each; All stands for the list sections (All itself, Upcoming from the View menu
/// and Shortcuts, and Cancelled when the menu bar reveals a cancelled subscription), so
/// the switch keeps All lit while one of those is on screen. Needs attention and a
/// category are not lists of their own: `MainWindow` turns Needs attention into Home
/// with its ⚠ list open, and a category into All with that category picked.
enum WindowSection: Hashable, CaseIterable {
    case home, calendar, all

    var title: String {
        switch self {
        case .home: "Home"
        case .calendar: "Calendar"
        case .all: "All"
        }
    }

    init(_ section: OboloCore.Section) {
        switch section {
        case .overview: self = .home
        case .calendar: self = .calendar
        default: self = .all
        }
    }

    var section: OboloCore.Section {
        switch self {
        case .home: .overview
        case .calendar: .calendar
        case .all: .all
        }
    }
}

// MARK: - Top bar

/// The window's top bar content: the section switch, centred, and a back button on the
/// leading side while a subscription is open.
///
/// It lives in the window toolbar, so macOS keeps the traffic lights, the drag area and
/// the 52pt bar height. The toolbar's own background and item glass are hidden, so the
/// bar reads as part of the `bg100` window.
struct WindowToolbar: ToolbarContent {
    @Bindable var model: AppModel
    /// Off while Home is empty or filling its first slab: there is no other month to see.
    var showsMonthPicker = true

    private var hidesSections: Bool { model.isFormPresented || model.storeRecovery != nil }

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // Hidden under the New subscription sheet, which covers the top bar. Kept in
            // place (only invisible) so the bar, and with it the window, keeps its height.
            DSSegmentedSwitch(
                options: WindowSection.allCases.map { ($0, $0.title) },
                selection: WindowSection(model.section),
                onSelect: select
            )
            // Also hidden while the data file cannot be read: the window shows only the
            // recovery panel, and there are no screens to switch between.
            .opacity(hidesSections ? 0 : 1)
            .disabled(hidesSections)
            .accessibilityHidden(hidesSections)
            .accessibilityIdentifier("window.sections")
        }
        .withoutSharedBackground()

        monthPicker

        ToolbarItem(placement: .navigation) {
            if model.isShowingSubscriptionDetail {
                // Hidden, not removed, under the edit form: an item AppKit re-inserts
                // into the titlebar can land at x = 0, under the traffic lights.
                let isHidden = model.isFormPresented
                Button {
                    model.closeSubscriptionDetail()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .regular))
                        Text(backTitle)
                            .dsStyle(.label)
                    }
                    .foregroundStyle(DS.Palette.inkMuted)
                    .padding(.leading, 6)
                    .padding(.trailing, 10)
                    .frame(height: 28)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .dsFocusRing(Capsule())
                .keyboardShortcut(.cancelAction)
                .help("Back to \(backTitle)")
                .accessibilityIdentifier("window.back")
                .opacity(isHidden ? 0 : 1)
                // Disabled, so Esc reaches the form rather than this link.
                .disabled(isHidden)
                .accessibilityHidden(isHidden)
            }
        }
        .withoutSharedBackground()
    }

    // MARK: Home month

    /// Home's month picker, on the trailing side. Re-dates the whole of Home.
    @ToolbarContentBuilder
    private var monthPicker: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if showsMonthPicker, model.storeRecovery == nil, model.section == .overview, !model.isShowingSubscriptionDetail, !model.isFormPresented {
                // Keep the button inside a hosted view so SwiftUI observes its toolbar focus.
                HStack {
                    HomeMonthPicker(model: model)
                }
                // The toolbar's own trailing margin is tighter than the design's 12.
                .padding(.trailing, 8)
            }
        }
        .withoutSharedBackground()
    }

    private var backTitle: String {
        switch model.section {
        case .calendar: "Calendar"
        case .all: "All"
        default: model.sectionTitle
        }
    }

    private func select(_ destination: WindowSection) {
        // A second click on the lit section while a subscription is open goes back to
        // the section, which is what the switch says is on screen.
        if WindowSection(model.section) == destination {
            if model.isShowingSubscriptionDetail { model.closeSubscriptionDetail() }
            if destination == .all, model.section != .all { model.section = .all }
            return
        }
        model.section = destination.section
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

// MARK: - Bottom bar

/// Gear (or the detail's `⋮`) │ tools · status line · the one primary button.
///
/// The status line carries what would otherwise need another panel: the next charge on
/// Home, the selected day's payments on Calendar, the shown total on a list, the
/// reminder on a subscription.
struct WindowBottomBar: View {
    @Bindable var model: AppModel
    var allScope = AllScope()
    var search: Binding<AllSearch> = .constant(AllSearch())
    /// Home's ⚠ list.
    var isAttentionOpen: Binding<Bool> = .constant(false)
    /// The ⚠ list's "Set date": Edit with the First payment picker open.
    var onSetDate: (Subscription.ID) -> Void = { _ in }

    /// A list on screen (not a subscription): the bar carries search. Not while there
    /// is nothing to search.
    private var showsSearch: Bool {
        !model.isShowingSubscriptionDetail && model.section != .overview && model.section != .calendar
            && !model.hasNoSubscriptions
    }

    var body: some View {
        HStack(spacing: 10) {
            moreMenu

            Rectangle()
                .fill(DS.Palette.lineStrong.opacity(0.6))
                .frame(width: DS.hairline, height: 24)

            if showsSearch {
                // The lens and the status line, with the search pill that grows over
                // the status line.
                SearchBarRegion(model: model, scope: allScope, search: search)
            } else {
                tools

                WindowStatusLine(model: model, scope: allScope)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
            }

            trailingButtons
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: DS.Size.bottomBar)
    }

    // MARK: Gear, or the detail's ⋮

    @ViewBuilder
    private var moreMenu: some View {
        if model.isShowingSubscriptionDetail, let id = model.selectedID {
            DetailActionsButton(model: model, id: id)
        } else {
            // Settings, directly: import, export and the calendar live there and in the
            // File menu.
            GearButton()
        }
    }

    // MARK: Tools

    @ViewBuilder
    private var tools: some View {
        if model.isShowingSubscriptionDetail {
            EmptyView()
        } else {
            switch model.section {
            case .overview:
                // What needs fixing, as a to-do list in a popover; gone at zero.
                if model.fixableCount > 0 {
                    AttentionButton(model: model, isOpen: isAttentionOpen, onSetDate: onSetDate)
                }
            default:
                // Month only on the Calendar; export moved to the File menu and
                // Settings.
                EmptyView()
            }
        }
    }

    // MARK: Primary

    @ViewBuilder
    private var trailingButtons: some View {
        if model.isShowingSubscriptionDetail, let id = model.selectedID {
            if let url = model.subscription(id)?.manageURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 6) {
                        Text("Account page")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .regular))
                    }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .dsFocusRing(Capsule())
                .help(url.absoluteString)
            }
            Button("Edit") { model.presentEdit(id) }
                .buttonStyle(DSPrimaryButtonStyle())
                .dsFocusRing(Capsule())
                .keyboardShortcut("e")
                .accessibilityIdentifier("window.edit")
        } else {
            Button {
                model.presentAdd()
            } label: {
                HStack(spacing: 6) {
                    Text("Add")
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .regular))
                }
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .dsFocusRing(Capsule())
            .help("Add a subscription")
            .accessibilityIdentifier("window.add")
        }
    }
}

// MARK: - Gear

/// The bottom bar's gear: opens Settings, like ⌘,. On hover a 34pt `bg300` circle comes
/// up behind it, the icon turns `ink` and turns 60° (0.5 s, cubic(.32,.72,0,1); not with
/// Reduce Motion).
private struct GearButton: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button { openSettings() } label: {
            GearIcon()
                .frame(width: 18, height: 18)
                .foregroundStyle(isHovering ? DS.Palette.ink : DS.Palette.inkMuted)
                .rotationEffect(.degrees(isHovering && !reduceMotion ? 60 : 0))
                .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.5), value: isHovering)
                .frame(width: 34, height: 34)
                .background(Circle().fill(isHovering ? DS.Palette.bg300 : .clear))
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .dsFocusRing(Circle())
        .onHover { isHovering = $0 }
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("window.settings")
    }
}

/// A crisp gear in a 24-unit box: eight straight-sided teeth with flat tips, mitred
/// corners, a 1.4 stroke and a centre ring of radius 3.2. Teeth reach 10.2 from the
/// centre with tips ±9.5°; their bases sit at 7.4, ±13.5°, joined tooth to tooth by
/// straight lines.
struct GearIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            var path = Self.outline
            path.addEllipse(in: CGRect(x: 12 - 3.2, y: 12 - 3.2, width: 6.4, height: 6.4))
            let style = StrokeStyle(lineWidth: 1.4 * scale, lineCap: .butt, lineJoin: .miter, miterLimit: 4)
            context.stroke(
                path.applying(CGAffineTransform(scaleX: scale, y: scale)),
                with: .style(.foreground),
                style: style
            )
        }
        .accessibilityHidden(true)
    }

    private static let outline: Path = {
        func point(_ degrees: Double, _ radius: Double) -> CGPoint {
            let radians = degrees * .pi / 180
            return CGPoint(x: 12 + radius * cos(radians), y: 12 + radius * sin(radians))
        }
        var path = Path()
        for tooth in 0..<8 {
            let centre = -90 + Double(tooth) * 45
            let corners = [
                point(centre - 13.5, 7.4), point(centre - 9.5, 10.2),
                point(centre + 9.5, 10.2), point(centre + 13.5, 7.4),
            ]
            for (index, corner) in corners.enumerated() {
                if tooth == 0, index == 0 { path.move(to: corner) } else { path.addLine(to: corner) }
            }
        }
        path.closeSubpath()
        return path
    }()
}

/// The warning triangle with its mark: mitred, 1.5 stroke in a 24-unit box.
struct WarningIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            var path = Path()
            path.move(to: CGPoint(x: 12, y: 4))
            path.addLine(to: CGPoint(x: 3, y: 19.5))
            path.addLine(to: CGPoint(x: 21, y: 19.5))
            path.closeSubpath()
            path.move(to: CGPoint(x: 12, y: 10))
            path.addLine(to: CGPoint(x: 12, y: 14.5))
            path.move(to: CGPoint(x: 12, y: 16.5))
            path.addLine(to: CGPoint(x: 12, y: 18))
            context.stroke(
                path.applying(CGAffineTransform(scaleX: scale, y: scale)),
                with: .style(.foreground),
                style: StrokeStyle(lineWidth: 1.5 * scale, lineJoin: .miter)
            )
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Needs attention

/// Home's ⚠ and its to-do list: each subscription with something to fix, why, and the
/// fix. A row leaves only once its issue is fixed; at zero the button goes and the list
/// closes.
private struct AttentionButton: View {
    let model: AppModel
    @Binding var isOpen: Bool
    let onSetDate: (Subscription.ID) -> Void

    @State private var isHovering = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = model.fixableCount
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                WarningIcon().frame(width: 16, height: 16)
                Text("\(count)")
                    .font(DSFonts.font(DSFonts.monoMedium, size: 13))
                    .monospacedDigit()
            }
            .foregroundStyle(DS.Palette.warning)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Capsule().fill(isOpen || isHovering ? DS.Palette.bg300 : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .dsFocusRing(Capsule())
        .onHover { isHovering = $0 }
        .help("Needs attention")
        .accessibilityLabel(count == 1 ? "1 subscription needs attention" : "\(count) subscriptions need attention")
        .overlay(alignment: .bottomLeading) {
            if isOpen {
                list
                    .offset(y: -(34 + 8))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: isOpen)
        .onChange(of: count) { _, count in
            if count == 0 { isOpen = false }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Needs attention")
                .dsStyle(.label)
                .foregroundStyle(DS.Palette.inkMuted)
                .padding(.top, 8)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(model.issueRows) { row in
                        if let issue = row.issue {
                            AttentionRow(row: row, issue: issue) { fix(row.id, issue) }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 46 * 7)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(width: 320, alignment: .leading)
        .dsDropdownSurface()
        .fixedSize()
        .background(ClickOutsideMonitor(isActive: isOpen, onEscape: { isOpen = false }) { isOpen = false })
    }

    private func fix(_ id: Subscription.ID, _ issue: AttentionIssue) {
        isOpen = false
        switch issue {
        case .noDate:
            onSetDate(id)
        case .missingRate:
            PreferencesRoute.shared.tab = .currencies
            openSettings()
        }
    }
}

/// One thing to fix: icon, name, the reason in yellow, and the fix on the right.
private struct AttentionRow: View {
    let row: SubscriptionSummary
    let issue: AttentionIssue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SubscriptionIcon(subscription: row.subscription, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                        .foregroundStyle(DS.Palette.ink)
                        .lineLimit(1)
                    Text(issue.reason)
                        .dsStyle(.label)
                        .font(DSFonts.font(DSFonts.monoMedium, size: 10))
                        .foregroundStyle(DS.Palette.warning)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(issue.fix) ›")
                    .dsStyle(.label)
                    .font(DSFonts.font(DSFonts.monoMedium, size: 11))
                    .foregroundStyle(DS.Palette.inkMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PopoverRowStyle())
        .dsFocusRing(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("\(row.name), \(issue.reason)")
        .accessibilityHint(issue.fix)
    }
}

// MARK: - Status line

/// The mono status line. Values in `ink`, the words around them in `inkMuted`.
///
/// On overflow the facts stay whole and the words give way: dates,
/// amounts, counts and the " · " between them never shrink; only a name truncates. The
/// line never scrolls sideways.
struct WindowStatusLine: View {
    let model: AppModel
    var scope = AllScope()

    var body: some View {
        line
            .dsStyle(.label)
            .foregroundStyle(DS.Palette.inkMuted)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("window.status")
    }

    @ViewBuilder
    private var line: some View {
        // The ledger is valid before the store answers; only an empty first read
        // has nothing to say yet.
        if !(model.isLoaded || !model.document.subscriptions.isEmpty || model.hasNoSubscriptions) {
            Text("Loading")
        } else if model.isShowingSubscriptionDetail, let subscription = model.subscription(model.selectedID) {
            reminder(subscription)
        } else {
            switch model.section {
            case .overview: nextCharge
            case .calendar: calendarDay
            default: shownTotal
            }
        }
    }

    /// A part that never shrinks: a date, an amount, a count, a separator.
    private func whole(_ text: Text) -> some View {
        text.fixedSize()
    }

    private var separator: some View { whole(Text(" · ")) }

    private var currency: String { model.document.settings.baseCurrency }

    // Home: the next charge. The name truncates; the date and amount stay whole.
    @ViewBuilder
    private var nextCharge: some View {
        let next = model.ledger.summaries
            .filter { $0.status.isBilling && $0.nextPayment != nil }
            .min { ($0.nextPayment ?? .distantFuture) < ($1.nextPayment ?? .distantFuture) }
        if model.hasNoSubscriptions {
            Text("No subscriptions yet")
        } else if let next, let date = next.nextPayment {
            let when = DateFormatting.renewal(date, today: model.today, calendar: model.calendar)
            let charge = next.nextCharge
            let amount = MoneyFormatting.amount(
                charge?.price ?? next.price,
                currency: charge?.currency ?? next.currency,
                estimate: next.isEstimate
            )
            // Due within the week: the date takes `warning`, as it does everywhere else.
            let soon = (next.daysUntil ?? .max) <= DateFormatting.relativeWindowDays
            HStack(spacing: 0) {
                whole(Text("Next · "))
                Text.ink(next.name)
                separator
                whole(soon ? Text(when).foregroundStyle(DS.Palette.warning) : Text(when))
                separator
                whole(Text.ink(amount))
            }
        } else {
            Text("No payments coming")
        }
    }

    // Calendar: the picked day, or today while today is on screen. The month's own count
    // and total sit under the grid, so the status line never repeats them.
    @ViewBuilder
    private var calendarDay: some View {
        let todayShown = model.isShowingCurrentMonth
        if let day = model.selectedCalendarDay ?? (todayShown ? model.calendar.startOfDay(for: model.today) : nil) {
            let occurrences = model.calendarOccurrences(on: day)
            let isToday = model.calendar.isDate(day, inSameDayAs: model.today)
            let date = isToday ? "Today" : DateFormatting.weekdayAndDate(day, today: model.today, calendar: model.calendar)
            if occurrences.isEmpty {
                Text("\(Text.ink(date)) · No payments")
            } else {
                CalendarDayStatus(model: model, date: date, occurrences: occurrences)
            }
        } else {
            Text("Click a day to see its payments")
        }
    }

    // A list: how many rows are shown, and what they add up to each month. The numbers
    // stay whole; a section title in front gives way first.
    @ViewBuilder
    private var shownTotal: some View {
        if model.hasNoSubscriptions {
            Text("0 shown")
        } else {
            let rows = model.allRows(scope: scope)
            // A row with no rate is left out and counted, as on Home; with nothing to
            // convert the figure is "-", never 0.
            let monthly = ConvertedSum(monthly: rows)
            let amount = monthly.total.map { MoneyFormatting.amount($0, currency: currency) } ?? MoneyFormatting.unknown
            HStack(spacing: 0) {
                if model.section != .all {
                    Text.ink(model.sectionTitle)
                    separator
                }
                whole(Text("\(Text.ink("\(rows.count)")) shown · "))
                if monthly.excludedCount > 0 {
                    whole(Text("\(Text("\(monthly.excludedCount)").foregroundStyle(DS.Palette.warning)) without a rate · "))
                }
                whole(Text("\(Text.ink(amount)) / mo"))
            }
        }
    }

    // Show the reminder lead time when one is scheduled. A disabled reminder or a
    // cancelled subscription displays “No reminder”.
    private func reminder(_ subscription: Subscription) -> Text {
        guard let days = model.document.settings.reminderLeadDays(for: subscription) else { return Text("No reminder") }
        return Text("Remind \(Text.ink(OboloCore.Settings.reminderLeadText(days: days)))")
    }
}

/// Calendar's line for a day with payments: "Wed, 26 Aug · Basic-Fit + ChatGPT · 24,98 €".
///
/// The date and the total never shrink. The names give way in steps: all of them; then
/// the first and a count ("Apple Developer Account +1"); then the first cut short
/// ("Apple Developer Acco… +3"). Resting on the line for 0.4 s shows every payment in
/// a popover above it.
struct CalendarDayStatus: View {
    let model: AppModel
    /// "Today" or "Wed, 26 Aug".
    let date: String
    let occurrences: [RenewalOccurrence]

    @State private var isOpen = false
    @State private var hoverTask: Task<Void, Never>?

    private var currency: String { model.document.settings.baseCurrency }
    private var names: [String] { occurrences.compactMap { model.subscription($0.subscriptionID)?.name } }

    var body: some View {
        // A charge with no rate is left out of the amount and counted in front of it,
        // as under the grid; with nothing to convert the amount is "-", never 0.
        let sum = ConvertedSum(charges: occurrences)
        Self.line(
            date: date,
            names: names,
            amount: sum.total.map { MoneyFormatting.amount($0, currency: currency) } ?? MoneyFormatting.unknown,
            excluded: sum.excludedCount
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hoverTask?.cancel()
            if inside {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    isOpen = true
                }
            } else {
                isOpen = false
            }
        }
        .onDisappear { hoverTask?.cancel() }
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            DayPaymentsPopover(model: model, date: date, occurrences: occurrences)
        }
    }

    /// The date, the names, how many charges have no rate (when any do) and the amount;
    /// only the names give way.
    static func line(date: String, names: [String], amount: String, excluded: Int = 0) -> some View {
        HStack(spacing: 0) {
            Text(date).foregroundStyle(DS.Palette.ink).fixedSize()
            Text(" · ").fixedSize()
            Self.names(names)
            Text(" · ").fixedSize()
            if excluded > 0 {
                Text("\(Text("\(excluded)").foregroundStyle(DS.Palette.warning)) without a rate · ").fixedSize()
            }
            Text(amount).foregroundStyle(DS.Palette.ink).fixedSize()
        }
    }

    /// The names in the room there is, in three steps (see the type's comment).
    @ViewBuilder
    static func names(_ names: [String]) -> some View {
        let first = names.first ?? ""
        let more = names.count - 1
        ViewThatFits(in: .horizontal) {
            Text(names.joined(separator: " + "))
                .fixedSize()
            if more > 0 {
                HStack(spacing: 0) {
                    Text(first)
                    Text(" +\(more)").foregroundStyle(DS.Palette.ink)
                }
                .fixedSize()
            }
            HStack(spacing: 0) {
                Text(first)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if more > 0 {
                    Text(" +\(more)").foregroundStyle(DS.Palette.ink).fixedSize()
                }
            }
        }
    }
}

/// The day's payments in full, above the status line: the date, a row per payment (icon,
/// whole name, price), then the count and total under a hairline. No cycle column: the
/// full name matters more.
struct DayPaymentsPopover: View {
    let model: AppModel
    let date: String
    let occurrences: [RenewalOccurrence]

    private var currency: String { model.document.settings.baseCurrency }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date)
                .dsLabel()
                .padding(.bottom, 10)
            ForEach(Array(occurrences.enumerated()), id: \.offset) { _, occurrence in
                if let subscription = model.subscription(occurrence.subscriptionID) {
                    HStack(spacing: 10) {
                        SubscriptionIcon(subscription: subscription, size: 18)
                        Text(subscription.name)
                            .font(DSFonts.font(DSFonts.sansRegular, size: 13))
                            .foregroundStyle(DS.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 16)
                        // In the base currency where there is a rate, so the rows add up
                        // to the total under them.
                        Text(occurrence.amountInBase.map { MoneyFormatting.amount($0, currency: currency) }
                            ?? MoneyFormatting.amount(occurrence.amount, currency: occurrence.currency))
                            .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                            .foregroundStyle(DS.Palette.ink)
                            .fixedSize()
                    }
                    .frame(minHeight: 28)
                }
            }
            Rectangle()
                .fill(DS.Palette.lineStrong)
                .frame(height: DS.hairline)
                .padding(.vertical, 8)
            // A row with no rate shows its own currency above and is left out of the
            // total here, which says so; nothing to convert is "-", never 0.
            let sum = ConvertedSum(charges: occurrences)
            HStack(spacing: 0) {
                Text(occurrences.count == 1 ? "1 payment" : "\(occurrences.count) payments")
                Spacer(minLength: 16)
                if sum.excludedCount > 0 {
                    Text("\(Text("\(sum.excludedCount)").foregroundStyle(DS.Palette.warning)) without a rate · ")
                }
                Text(sum.total.map { MoneyFormatting.amount($0, currency: currency) } ?? MoneyFormatting.unknown)
                    .foregroundStyle(DS.Palette.ink)
            }
            .dsLabel()
        }
        .textCase(nil)
        .padding(14)
        .frame(width: 300)
        .background(DS.Palette.bg300)
    }
}

#Preview("Status line · overflow steps") {
    VStack(alignment: .leading, spacing: 18) {
        StatusLineStep(label: "1 · all names", names: ["Basic-Fit", "ChatGPT"], width: 470)
        StatusLineStep(label: "2 · first name + count", names: ["Apple Developer Account", "Porkbun"], width: 470)
        StatusLineStep(
            label: "3 · first name cut + count",
            names: ["Apple Developer Account", "Porkbun", "Basic-Fit", "ChatGPT"],
            width: 340
        )
    }
    .padding(24)
    .background(DS.Palette.bg100)
}

/// One width of the overflow preview, with its right edge marked.
private struct StatusLineStep: View {
    let label: String
    let names: [String]
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            CalendarDayStatus.line(date: "Wed, 26 Aug", names: names, amount: "109,19 €")
                .dsStyle(.label)
                .foregroundStyle(DS.Palette.inkMuted)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .padding(.vertical, 6)
                .overlay(alignment: .trailing) { Rectangle().fill(DS.Palette.warning).frame(width: 1) }
        }
    }
}

// MARK: - CSV export

/// The Export CSV save panel and the write, which the File menu and Settings › Data
/// share. Each reports the result in its own place.
@MainActor
enum CSVExportPanel {
    /// The File menu: silent on success, an alert on failure.
    static func run(model: AppModel) {
        do {
            _ = try export(model: model)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Obolo cannot export the file."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Asks where to save, then writes the CSV there. `nil` when the user cancels the
    /// panel; throws when the write fails.
    static func export(model: AppModel) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Obolo.csv"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try model.exportCSV().write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Window surface

/// Keeps the top bar the window's own `bg100` on every screen.
///
/// Hiding the toolbar background in SwiftUI is not enough: when a scroll view in the
/// window is scrolled away from its top (the calendar pager always is, with months
/// stacked above the one on screen), AppKit gives the title bar a backdrop of its own and
/// the bar turns a shade lighter. A transparent title bar with no separator, over a
/// `bg100` window, has nothing to change.
struct WindowSurface: NSViewRepresentable {
    /// While the New subscription sheet covers the top bar, the traffic lights would sit
    /// on its title, so they step aside until it closes.
    var hidesWindowButtons = false
    /// The window's title, where one should show (the Settings window: the pane's name).
    var title: String?

    func makeNSView(context: Context) -> NSView { SurfaceView() }

    func updateNSView(_ view: NSView, context: Context) {
        let hidden = hidesWindowButtons
        let title = title
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            if let title { window.title = title }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            let reappearing = !hidden && buttons.contains { $0.alphaValue < 1 }
            for button in buttons {
                button.animator().alphaValue = hidden ? 0 : 1
                button.isEnabled = !hidden
            }
            // The toolbar puts its leading items after the window buttons it can see. A
            // toolbar layout while they are hidden puts the back link at x = 22, under
            // them, and AppKit does not lay the toolbar out again when they come back.
            // So ask for that layout now. The toolbar's view is one of the buttons'
            // siblings.
            if reappearing {
                buttons.first?.superview?.subviews.forEach { $0.needsLayout = true }
            }
        }
    }

    private final class SurfaceView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = DS.Palette.bg100NS
        }
    }
}

// MARK: - Home month picker

/// "Nov 26": the window's shared month, which Home reads and Calendar opens on. Opens a
/// month picker: the year with arrows, and the twelve months under it. The current
/// month is marked in `accent` (the way back), the picked one is filled. Months before
/// the first record, or more than five years ahead, are off.
struct HomeMonthPicker: View {
    let model: AppModel

    @State private var isOpen = false
    @State private var isHovering = false

    private var calendar: Calendar { model.calendar }
    private var current: Date { MonthRange.start(of: model.today, calendar: calendar) }
    private var shown: Date { model.shownMonth }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            // Quiet, like the section tabs beside it: bg200 with a
            // 1pt line, 34pt tall; on hover and while open, bg300 with line-strong.
            let lit = isHovering || isOpen
            HStack(spacing: 6) {
                Text(shown.formatted(.dateTime.month(.abbreviated).year(.twoDigits)))
                    .font(DSFonts.font(DSFonts.monoRegular, size: 13))
                    .foregroundStyle(DS.Palette.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(DS.Palette.inkMuted)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 34)
            .background(Capsule().fill(lit ? DS.Palette.bg300 : DS.Palette.bg200))
            .overlay(Capsule().strokeBorder(lit ? DS.Palette.lineStrong : DS.Palette.line, lineWidth: DS.hairline))
            .animation(.easeOut(duration: 0.12), value: lit)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .dsFocusRing(Capsule())
        .fixedSize()
        .help("Show Home for another month")
        .accessibilityLabel("Month: \(shown.formatted(.dateTime.month(.wide).year()))")
        .accessibilityIdentifier("home.month")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            MonthGridPicker(
                calendar: calendar,
                current: current,
                selected: shown,
                earliest: earliest,
                latest: MonthRange.start(of: model.today, offsetByMonths: 60, calendar: calendar)
            ) { picked in
                model.showMonth(containing: picked)
                isOpen = false
            }
        }
    }

    /// The first month with a record, or two years back when nothing has an anchor.
    private var earliest: Date {
        if let begins = model.ledger.recordBegins {
            return MonthRange.start(of: begins, calendar: calendar)
        }
        return MonthRange.start(of: model.today, offsetByMonths: -24, calendar: calendar)
    }
}

/// A year and its twelve months, in the instrument style.
struct MonthGridPicker: View {
    let calendar: Calendar
    /// First day of the current month.
    let current: Date
    /// First day of the picked month.
    let selected: Date
    let earliest: Date
    let latest: Date
    let onPick: (Date) -> Void

    @State private var year: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text(String(year))
                    .dsStyle(.heading)
                    .foregroundStyle(DS.Palette.ink)
                Spacer(minLength: 8)
                // Every control here takes the design's ring, keyboard only: without it
                // the system draws an accent (orange) ring as soon as the popover opens.
                Button { year -= 1 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(DSIconButtonStyle(size: 28))
                    .dsFocusRing(Circle())
                    .disabled(year <= calendar.component(.year, from: earliest))
                    .help("Previous year")
                Button { year += 1 } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(DSIconButtonStyle(size: 28))
                    .dsFocusRing(Circle())
                    .disabled(year >= calendar.component(.year, from: latest))
                    .help("Next year")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(months, id: \.self) { date in
                    cell(date)
                }
            }

            Button("This month") { onPick(current) }
                .buttonStyle(DSSecondaryButtonStyle(height: 28, mono: true))
                .dsFocusRing(Capsule())
                .disabled(selected == current)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(width: 252)
        .background(DS.Palette.bg200)
        .onAppear { year = calendar.component(.year, from: selected) }
    }

    private var months: [Date] {
        (1...12).compactMap { calendar.date(from: DateComponents(year: year, month: $0, day: 1)) }
    }

    private func cell(_ date: Date) -> some View {
        let isSelected = date == selected
        let isCurrent = date == current
        let isEnabled = date >= earliest && date <= latest
        return Button {
            onPick(date)
        } label: {
            Text(date.formatted(.dateTime.month(.abbreviated)))
                .dsStyle(.label)
                .foregroundStyle(
                    !isEnabled ? DS.Palette.inkDisabled
                        : isCurrent ? DS.Palette.accent
                        : isSelected ? DS.Palette.ink : DS.Palette.inkMuted
                )
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(isCurrent ? DS.Palette.accentTint : isSelected ? DS.Palette.bg400 : DS.Palette.bg300)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .strokeBorder(
                            isCurrent ? DS.Palette.accent : isSelected ? DS.Palette.inkMuted : .clear,
                            lineWidth: DS.hairline
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsFocusRing(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .disabled(!isEnabled)
        .accessibilityLabel(date.formatted(.dateTime.month(.wide).year()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Detail actions

/// The detail's ⋮: a popover above the button with Mark as cancelled or Reactivate,
/// Duplicate, and Delete. Mark as cancelled and Delete each ask first, in the same
/// popover, in place of the items. No Pause.
private struct DetailActionsButton: View {
    let model: AppModel
    let id: Subscription.ID

    @State private var isOpen = false
    @State private var asksDelete = false
    @State private var asksCancel = false
    @State private var cancelEnd = BillingDay(.now, calendar: .current)

    var body: some View {
        Button {
            asksDelete = false
            asksCancel = false
            isOpen.toggle()
        } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90))
        }
        .buttonStyle(DSIconButtonStyle())
        .dsFocusRing(Circle())
        .help("More: cancel, duplicate, delete")
        .accessibilityLabel("More")
        .accessibilityIdentifier("window.more")
        // A sheet opening over the window (Edit, Duplicate) takes the popover with it.
        .onChange(of: model.isFormPresented) { _, presented in
            if presented { isOpen = false }
        }
        // "Mark cancelled" from a row's right-click menu: the detail opens, and this
        // opens on the question.
        .onChange(of: model.cancelPromptID, initial: true) { _, prompt in
            guard prompt == id else { return }
            model.cancelPromptID = nil
            Task { @MainActor in
                // After the detail has come up, so the popover has a button to hang from.
                try? await Task.sleep(for: .milliseconds(200))
                askCancel()
                isOpen = true
            }
        }
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            Group {
                if asksDelete {
                    deleteConfirmation
                } else if asksCancel, let subscription {
                    CancelPrompt(
                        name: subscription.name,
                        endDate: $cancelEnd,
                        today: model.today,
                        calendar: model.calendar,
                        onKeep: { isOpen = false },
                        onConfirm: {
                            isOpen = false
                            model.cancel(id, endsOn: cancelEnd)
                        }
                    )
                } else {
                    items
                }
            }
            // Built like the date picker: the menu 248pt wide with
            // 8pt padding, a question 268pt with 12pt.
            .frame(width: asksDelete || asksCancel ? 268 - 24 : 248 - 16)
            .dsPopoverPanel(padding: asksDelete || asksCancel ? 12 : 8)
        }
    }

    private var subscription: Subscription? { model.subscription(id) }

    @ViewBuilder
    private var items: some View {
        if let subscription {
            VStack(spacing: 4) {
                if !subscription.status.isBilling {
                    row("Reactivate", icon: "arrow.uturn.backward") { model.setStatus(.active, for: id) }
                } else {
                    row("Mark as cancelled", icon: "nosign", closes: false) {
                        askCancel()
                    }
                }
                // The shortcuts are the app menu's: ⌘D Duplicate, ⌘⌫ Delete.
                row("Duplicate", icon: "plus.square.on.square", hint: "⌘D") { model.presentDuplicate(id) }
                Rectangle().fill(DS.Palette.line).frame(height: 1)
                row("Delete", icon: "trash", hint: "⌘⌫", isDanger: true, closes: false) { asksDelete = true }
            }
        }
    }

    private func row(
        _ title: String,
        icon: String,
        hint: String? = nil,
        isDanger: Bool = false,
        closes: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if closes { isOpen = false }
            action()
        } label: {
            // A cell, like the date picker's: a 16pt line icon, the
            // label in mono uppercase, and the shortcut on the right.
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(isDanger ? DS.Palette.danger : DS.Palette.inkMuted)
                Text(title)
                    .dsStyle(.label)
                    .foregroundStyle(isDanger ? DS.Palette.danger : DS.Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let hint {
                    Text(hint)
                        .font(DSFonts.font(DSFonts.monoRegular, size: 11))
                        .foregroundStyle(DS.Palette.inkDisabled)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PopoverRowStyle(isCell: true))
        .dsFocusRing(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The question replaces the items, with access ending on the next payment.
    private func askCancel() {
        cancelEnd = CancelPrompt.defaultEnd(for: id, model: model)
        asksDelete = false
        asksCancel = true
    }

    /// The question, in place of the menu: what goes with it as two counts, then mono
    /// Keep and Delete pills.
    private var deleteConfirmation: some View {
        let payments = model.summary(id)?.paidSoFar?.count ?? 0
        let priceChanges = subscription?.priceChanges.count ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            Text(DeletePrompt.title(name: subscription?.name))
                .font(DSFonts.font(DSFonts.sansMedium, size: 15))
                .foregroundStyle(DS.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                countRow("Payments", payments)
                if priceChanges > 0 { countRow("Price changes", priceChanges) }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Palette.bg300))
            // Delete keeps its few seconds of ⌘Z (the Undo toast), so this doesn't say
            // there is none.
            Text("They go too. You can undo for a few seconds.")
                .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                .foregroundStyle(DS.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Keep") { isOpen = false }
                    .buttonStyle(DSSecondaryButtonStyle(height: 30, mono: true))
                    .dsFocusRing(Capsule())
                    .keyboardShortcut(.cancelAction)
                Button("Delete") {
                    isOpen = false
                    model.delete(id)
                    model.closeSubscriptionDetail()
                    model.section = .all
                }
                .buttonStyle(DSDangerButtonStyle(height: 30))
                .dsFocusRing(Capsule())
            }
        }
    }

    private func countRow(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label.uppercased())
                .font(DSFonts.font(DSFonts.monoMedium, size: 11))
                .tracking(0.88)
                .foregroundStyle(DS.Palette.inkMuted)
            Spacer(minLength: 8)
            Text(count.formatted())
                .font(DSFonts.font(DSFonts.monoRegular, size: 13))
                .foregroundStyle(DS.Palette.ink)
        }
    }
}

