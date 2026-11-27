import SwiftUI
import OboloCore

/// All subscriptions: filter chips, sentence-case mono column headers, and rows that
/// scroll inside the panel.
///
/// Each row is one 40pt line: the logo (or a quiet initial), the name, the next date
/// (yellow within 7 days), the amount with its cycle ("/mo", "/yr") and the monthly
/// equivalent. Alerts are single yellow marks with a tooltip: "~" before an estimated
/// price, "–" for a missing date or exchange rate. The category is the row's tooltip. Clicking a
/// row opens the subscription; double-clicking edits it; right-clicking gives its
/// actions. Name, Next, Amount and / month sort, with a second click reversing.
///
/// Keyboard: Tab or the arrow keys move between rows, Return opens one, Delete asks to
/// delete it.
struct AllListView: View {
    @Bindable var model: AppModel
    /// The pill and the category.
    @Binding var scope: AllScope
    /// The search query, or empty. While there is one it filters every subscription by
    /// name, whatever the pill, and the pills step back to 35%.
    var query: String = ""
    /// A row just added: lit, then fading out.
    var flashedRow: Subscription.ID?

    @FocusState private var focusedRow: Subscription.ID?

    // Name (flexible) · Next · Amount · / month.
    fileprivate static let nextWidth: CGFloat = 100
    fileprivate static let amountWidth: CGFloat = 112
    fileprivate static let monthlyWidth: CGFloat = 72
    fileprivate static let gap: CGFloat = 12

    private var rows: [SubscriptionSummary] {
        query.isEmpty ? model.allRows(scope: scope) : model.searchRows(query)
    }

    var body: some View {
        if model.hasNoSubscriptions, query.isEmpty {
            AllEmptyPanel(model: model)
        } else {
            list
        }
    }

    private var list: some View {
        let rows = rows
        return VStack(alignment: .leading, spacing: 0) {
            chips
                .opacity(query.isEmpty ? 1 : 0.35)
                .animation(.easeOut(duration: 0.2), value: query.isEmpty)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                // The category list hangs over the rows below.
                .zIndex(1)

            header
                .padding(.horizontal, 12)

            if rows.isEmpty, !query.isEmpty {
                Text("No subscription matches “\(query)”")
                    .dsStyle(.column)
                    .foregroundStyle(DS.Palette.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                Spacer(minLength: 0)
            } else if rows.isEmpty, model.section == .all, scope.isNarrowed, model.allCount > 0 {
                Text(narrowedEmptyText)
                    .dsStyle(.column)
                    .foregroundStyle(DS.Palette.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                Spacer(minLength: 0)
            } else if rows.isEmpty {
                emptyState
            } else {
                list(rows)
            }
        }
        .padding(.top, 14)
        .accessibilityIdentifier("all")
    }

    // MARK: - Chips

    private var chips: some View {
        HStack(spacing: 6) {
            // Another list section, reached from the View menu: shown as the active
            // chip, with a way back to All.
            if model.section != .all {
                Button {
                    model.section = .all
                    scope.pill = .active
                } label: {
                    HStack(spacing: 6) {
                        Text(model.sectionTitle)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(ChipStyle(isActive: true))
                .dsFocusRing(Capsule())
                .help("Back to all subscriptions")
            }

            ForEach(AllFilter.allCases) { chip in
                let isActive = model.section == .all && scope.pill == chip
                Button(chip.title) {
                    model.section = .all
                    scope.pill = chip
                }
                .buttonStyle(ChipStyle(isActive: isActive))
                .dsFocusRing(Capsule())
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }

            Spacer(minLength: 8)

            if model.section == .all {
                CategoryDropdown(model: model, selection: $scope.category)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: Self.gap) {
            sortButton("Name", .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortButton("Next", .nextPayment)
                .frame(width: Self.nextWidth, alignment: .leading)
            sortButton("Amount", .amount)
                .frame(width: Self.amountWidth, alignment: .trailing)
            sortButton("/ month", .monthly)
                .frame(width: Self.monthlyWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.line).frame(height: DS.hairline)
        }
    }

    private func sortButton(_ title: String, _ order: OboloCore.SortOrder) -> some View {
        let isActive = model.sortOrder == order
        return Button {
            let ascending = isActive ? !model.isSortAscending : order.naturalAscending
            model.applySort(order, ascending: ascending)
        } label: {
            Text(isActive ? "\(title) \(model.isSortAscending ? "↑" : "↓")" : title)
                .dsStyle(.column)
                .foregroundStyle(isActive ? DS.Palette.ink : DS.Palette.inkMuted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsFocusRing(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
        .help("Sort by \(title.lowercased())")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - Rows

    private func list(_ rows: [SubscriptionSummary]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        AllRow(
                            row: row,
                            model: model,
                            focusedRow: $focusedRow,
                            isFlashed: flashedRow == row.id
                        )
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.automatic)
            .dsScrollFade()
            .onMoveCommand { direction in
                moveFocus(direction, in: rows)
                if let focusedRow { proxy.scrollTo(focusedRow) }
            }
            .onKeyPress(.return) {
                guard let focusedRow else { return .ignored }
                model.selectSubscriptionRow(focusedRow)
                return .handled
            }
            .onDeleteCommand {
                if let focusedRow { model.pendingDelete = focusedRow }
            }
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection, in rows: [SubscriptionSummary]) {
        guard !rows.isEmpty else { return }
        let index = focusedRow.flatMap { id in rows.firstIndex { $0.id == id } }
        switch direction {
        case .down:
            focusedRow = rows[min((index ?? -1) + 1, rows.count - 1)].id
        case .up:
            focusedRow = rows[max((index ?? rows.count) - 1, 0)].id
        default:
            break
        }
    }

    // MARK: - Empty

    /// A list section with nothing in it while other subscriptions exist. With none at
    /// all the panel is `AllEmptyPanel` instead.
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(emptyText)
                .dsStyle(.bodySmall)
                .foregroundStyle(DS.Palette.inkMuted)
                .multilineTextAlignment(.center)
            if model.allCount == 0 {
                Button("Add subscription") { model.presentAdd() }
                    .buttonStyle(DSSecondaryButtonStyle(height: 30))
                    .dsFocusRing(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyText: String {
        if model.allCount == 0 { return "Nothing tracked yet. Add your first subscription, or import a CSV file." }
        // Needs attention and a category never stay here: `MainWindow` sends them to Home
        // and to All's category filter.
        switch model.section {
        case .upcoming: return "No subscription renews in the next \(OboloCore.Section.upcomingWindowDays) days."
        case .pausedCancelled: return "All your subscriptions are active."
        default: break
        }
        switch scope.pill {
        case .active: return "No active subscriptions."
        case .dueSoon: return "Nothing renews in the next \(AllFilter.dueSoonDays) days."
        case .inactive: return "Nothing cancelled."
        }
    }
}

// MARK: - Nothing at all

/// All with no subscriptions: one panel, centred: the small empty
/// slab, still, then what will show up here and the two ways in. No filter pills and no
/// category list, since there is nothing to filter.
struct AllEmptyPanel: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            EmptySlab(layout: .list, animated: false)
                .frame(width: EmptySlab.Layout.list.size.width, height: EmptySlab.Layout.list.size.height)
            Text("No subscriptions yet")
                .dsStyle(.heading)
                .foregroundStyle(DS.Palette.ink)
                .padding(.top, 28)
            Text("Everything you add shows up here, with its next date, price and cycle.")
                .dsStyle(.bodySmall)
                .foregroundStyle(DS.Palette.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            EmptyStateActions(model: model)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("all.empty")
    }
}

// MARK: - Narrowed

extension AllListView {
    /// "No inactive subscriptions in Utilities".
    fileprivate var narrowedEmptyText: String {
        let what = switch scope.pill {
        case .active: "active subscriptions"
        case .dueSoon: "subscriptions due soon"
        case .inactive: "inactive subscriptions"
        }
        var text = "No \(what)"
        if let name = model.categoryName(scope.category) { text += " in \(name)" }
        return text
    }
}

// MARK: - Category dropdown

/// The category filter at the right end of the pills: "CATEGORY ⌄" at rest; the picked
/// category's square and name, in `ink` on `bg300`, once one is picked. Its list drops
/// below, right-aligned, and closes on a pick, a click outside or Esc.
private struct CategoryDropdown: View {
    let model: AppModel
    @Binding var selection: OboloCore.Category.ID?

    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var picked: OboloCore.Category? {
        selection.flatMap { id in model.document.categories.first { $0.id == id } }
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .dsFocusRing(Capsule())
        .help("Show one category")
        .accessibilityLabel(picked.map { "Category: \($0.name)" } ?? "Category")
        .accessibilityHint("Shows the list of categories")
        .overlay(alignment: .topTrailing) {
            if isOpen {
                list
                    .offset(y: 28 + 6)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .offset(y: 4))
                    )
            }
        }
        .animation(.easeOut(duration: 0.14), value: isOpen)
        .background(ClickOutsideMonitor(isActive: isOpen, onEscape: { isOpen = false }) { isOpen = false })
    }

    private var label: some View {
        HStack(spacing: 8) {
            if let picked {
                CategoryMarker(picked.tint, size: 8)
                Text(picked.name)
            } else {
                Text("Category")
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .animation(.easeOut(duration: 0.14), value: isOpen)
        }
        .dsStyle(.label)
        .foregroundStyle(picked == nil ? DS.Palette.inkMuted : DS.Palette.ink)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(picked == nil ? .clear : DS.Palette.bg300))
        .overlay(
            Capsule().strokeBorder(
                isOpen || picked != nil ? DS.Palette.ink : DS.Palette.lineStrong,
                lineWidth: DS.hairline
            )
        )
        .contentShape(Capsule())
    }

    private var list: some View {
        VStack(spacing: 0) {
            CategoryListRow(title: "All categories", tint: nil, trailing: selection == nil ? "✓" : nil) {
                pick(nil)
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.hairline)
                .padding(.horizontal, 6).padding(.vertical, 4)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(model.dropdownCategories) { category in
                        let isPicked = selection == category.id
                        CategoryListRow(
                            title: category.name,
                            tint: category.tint,
                            trailing: isPicked ? "✓" : "\(model.activeCount(in: category.id))"
                        ) {
                            pick(category.id)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 34 * 8)
        }
        .padding(6)
        .frame(width: 230)
        .fixedSize(horizontal: false, vertical: true)
        .dsDropdownSurface()
    }

    private func pick(_ id: OboloCore.Category.ID?) {
        selection = id
        isOpen = false
    }
}

/// A row in a list of categories: the square, the name, and on the right how many
/// active subscriptions it holds, or ✓ on the one picked. All's category dropdown and
/// the form's Category popover both list categories with it.
struct CategoryListRow: View {
    let title: String
    let tint: CategoryHue?
    /// The count, "✓" for the picked row, or `nil` for nothing.
    let trailing: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let tint {
                    CategoryMarker(tint, size: 8)
                }
                Text(title)
                    .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                    .foregroundStyle(DS.Palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing {
                    Text(trailing)
                        .font(DSFonts.font(DSFonts.monoRegular, size: 11))
                        .monospacedDigit()
                        .foregroundStyle(trailing == "✓" ? DS.Palette.ink : DS.Palette.inkDisabled)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowStyle())
        .dsFocusRing(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityAddTraits(trailing == "✓" ? .isSelected : [])
    }
}

// MARK: - Row

private struct AllRow: View {
    let row: SubscriptionSummary
    let model: AppModel
    @FocusState.Binding var focusedRow: Subscription.ID?
    /// Just added: lit, then fading out over the second `MainWindow` gives it, on its
    /// own layer so the row's short hover animation does not cut the fade short.
    let isFlashed: Bool

    @State private var isHovered = false

    private var isInactive: Bool { !row.status.isBilling }

    /// Keyboard focus shares the hover fill, so a click never leaves a row lit.
    private var isHighlighted: Bool {
        isHovered || (focusedRow == row.id && InputModality.shared.isKeyboard)
    }

    var body: some View {
        Button {
            model.selectSubscriptionRow(row.id)
        } label: {
            HStack(spacing: AllListView.gap) {
                HStack(spacing: 10) {
                    SubscriptionIcon(subscription: row.subscription, size: 24, isCancelled: row.status == .cancelled)
                    Text(row.name)
                        .dsStyle(.body)
                        .foregroundStyle(isInactive ? DS.Palette.inkMuted : DS.Palette.ink)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                next
                    .frame(width: AllListView.nextWidth, alignment: .leading)

                amount
                    .frame(width: AllListView.amountWidth, alignment: .trailing)

                monthly
                    .frame(width: AllListView.monthlyWidth, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                    .fill(isHighlighted ? DS.Palette.bg300 : .clear)
                    .animation(.easeOut(duration: 0.12), value: isHighlighted)
            )
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                    .fill(isFlashed ? DS.Palette.bg300 : .clear)
            )
            .overlay(alignment: .bottom) {
                Rectangle().fill(DS.Palette.line).frame(height: DS.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedRow, equals: row.id)
        .onHover { isHovered = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.presentEdit(row.id) })
        .contextMenu { SubscriptionRowMenu(model: model, id: row.id) }
        // The category is no longer drawn in the row; it is the row's tooltip, with the
        // state when there is one.
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var tooltip: String {
        switch row.status {
        case .paused, .cancelled, .trial: "\(row.category.name) · \(row.status.displayName)"
        case .active: row.category.name
        }
    }

    // MARK: Next

    private var hasNoDate: Bool {
        guard row.status.isBilling else { return false }
        if case .noDate = row.attention { return true }
        return false
    }

    @ViewBuilder
    private var next: some View {
        if hasNoDate {
            Text("–")
                .dsStyle(.data)
                .font(DSFonts.font(DSFonts.monoRegular, size: 13))
                .foregroundStyle(DS.Palette.warning)
                .help("No renewal date")
        } else {
            Text(nextText)
                .dsStyle(.data)
                .font(DSFonts.font(DSFonts.monoRegular, size: 13))
                .foregroundStyle(nextColor)
                .lineLimit(1)
        }
    }

    /// Relative within a week, absolute beyond it; "Ends 5 Sep" for a cancelled row that
    /// still has access; `-` with no date at all.
    private var nextText: String {
        let text: String
        if let date = row.nextPayment {
            text = DateFormatting.renewal(date, today: model.today, calendar: model.calendar)
        } else if case .endsOn = row.attention {
            text = row.attention.label(today: model.today, calendar: model.calendar)
        } else {
            text = MoneyFormatting.unknown
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private var nextColor: Color {
        if isInactive { return DS.Palette.inkDisabled }
        if let days = row.daysUntil, (0...AllFilter.dueSoonDays).contains(days) { return DS.Palette.warning }
        return DS.Palette.ink
    }

    // MARK: Amount

    /// "~14,99 € /mo": the estimate mark in yellow, the charge, and the cycle in 11pt.
    private var amount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if row.isEstimate {
                    Text("~")
                        .foregroundStyle(DS.Palette.warning)
                        .help("Estimated price")
                }
                Text(MoneyFormatting.amount(row.price, currency: row.currency))
                    .foregroundStyle(isInactive ? DS.Palette.inkDisabled : DS.Palette.ink)
            }
            .dsStyle(.data)
            .lineLimit(1)
            Text(row.cycle.compactSuffix)
                .font(DSFonts.font(DSFonts.monoRegular, size: 11))
                .foregroundStyle(DS.Palette.inkDisabled)
                .fixedSize()
        }
    }

    // MARK: / month

    private var hasNoRate: Bool {
        if case .missingRate = row.attention { return true }
        return false
    }

    @ViewBuilder
    private var monthly: some View {
        if hasNoRate {
            Text("–")
                .dsStyle(.data)
                .font(DSFonts.font(DSFonts.monoRegular, size: 13))
                .foregroundStyle(DS.Palette.warning)
                .help("No exchange rate for \(row.currency)")
        } else {
            Text(monthlyText)
                .dsStyle(.data)
                .font(DSFonts.font(DSFonts.monoRegular, size: 13))
                .foregroundStyle(DS.Palette.inkMuted)
                .lineLimit(1)
        }
    }

    private var monthlyText: String {
        guard row.countsInTotals, let monthly = row.monthlyInBase else { return "–" }
        return MoneyFormatting.amount(monthly, currency: model.document.settings.baseCurrency)
    }

    private var accessibilityText: String {
        var parts = [row.name, row.category.name, hasNoDate ? "No renewal date" : nextText,
                     MoneyFormatting.amount(row.price, currency: row.currency, estimate: row.isEstimate)]
        if row.status != .active { parts.append(row.status.displayName) }
        if hasNoRate { parts.append("No exchange rate") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Chip

/// A filter chip: 28pt pill, mono label. Active: `ink` border on `bg300`; idle: a
/// `lineStrong` outline.
private struct ChipStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsStyle(.label)
            .foregroundStyle(isActive ? DS.Palette.ink : DS.Palette.inkMuted)
            .padding(.horizontal, 12)
            .frame(height: DS.Size.controlInPanel)
            .background(Capsule().fill(isActive ? DS.Palette.bg300 : (configuration.isPressed ? DS.Palette.bg300 : .clear)))
            .overlay(Capsule().strokeBorder(isActive ? DS.Palette.ink : DS.Palette.lineStrong, lineWidth: DS.hairline))
            .contentShape(Capsule())
    }
}
