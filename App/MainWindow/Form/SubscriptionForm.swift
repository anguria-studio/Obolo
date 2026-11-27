import AppKit
import SwiftUI
import OboloCore

/// The New subscription sheet, in the instrument style.
///
/// Three cards: identity (icon, name, website, category), money (price, price changes,
/// cycle, first payment) and a collapsed More options (status, reminder, account page,
/// notes, price may vary). The footer restates the price per month and per year and holds
/// Cancel and the one orange button.
///
/// Everything it saves goes through `SubscriptionDraft` in OboloCore.
/// In `.edit` the same sheet opens pre-filled, titled
/// "Edit <name>", with Save in place of Add and a last card to mark it cancelled (or
/// reactivate it) and to delete it, asked first in place; this is where price changes
/// are mainly managed.
///
/// The shared draft carries stored fields through an edit, including fields this form does not show.
struct SubscriptionForm: View {
    enum Mode {
        case add(SubscriptionFormPrefill)
        case edit(Subscription, focus: SubscriptionEditorFocus)
        /// New, pre-filled with the copy `AppModel.presentDuplicate` prepared (Duplicate,
        /// from the detail's ⋮, a row's menu or ⌘D).
        case duplicate(Subscription)
    }

    @Bindable var model: AppModel
    let mode: Mode
    let sheetID: WindowSheet.ID
    let onAdded: (Subscription) -> Void
    let onDeleted: () -> Void

    @State private var draft: SubscriptionDraft
    @FocusState private var focus: Field?
    @State private var isIconOpen = false
    @State private var isCategoryOpen = false
    @State private var isMoreOpen = false
    @State private var isOtherCycle: Bool
    @State private var otherCount: Int = 2
    @State private var otherUnit: OtherUnit = .years
    /// The Delete row has turned into its confirmation.
    @State private var asksDelete = false
    /// "Mark as cancelled" asking when access ends, in place of its row.
    @State private var asksCancel = false
    @State private var cancelEnd: BillingDay
    /// The status fields as they were before "Mark as cancelled", for Reactivate to put
    /// back within the same sheet.
    @State private var beforeCancel: StatusFields?
    /// The change row whose date picker opens by itself.
    @State private var autoOpenChange: UUID?
    /// A logo fetched from the icon popover, shown at once and stored only on Save.
    @State private var fetchedLogo: AppModel.FetchedLogo?
    /// The domain `fetchedLogo` came from: a website changed afterwards fetches again.
    @State private var fetchedLogoDomain: String?
    @State private var logoFetchState: LogoFetchState = .idle

    private enum LogoFetchState: Equatable {
        case idle
        case fetching
        case notFound(String)
    }

    enum Field: Hashable { case name, website, price, change(UUID), account, notes, otherCount }
    enum OtherUnit: String, CaseIterable { case months, years }

    init(
        model: AppModel,
        mode: Mode,
        sheetID: WindowSheet.ID,
        onAdded: @escaping (Subscription) -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.model = model
        self.mode = mode
        self.sheetID = sheetID
        self.onAdded = onAdded
        self.onDeleted = onDeleted

        let draft: SubscriptionDraft
        switch mode {
        case .add(let prefill):
            var template = model.newSubscriptionTemplate()
            // Logo mode by default: the quiet initial until a logo arrives.
            template.icon = .initial
            // The first payment starts empty: today is almost never the
            // first payment, and a plausible default gets accepted and loses the history
            // before it. The draft already leaves it unset for a new row.
            draft = SubscriptionDraft(template, isNew: true, prefill: prefill, calendar: model.calendar)
        case .edit(let subscription, _):
            draft = SubscriptionDraft(subscription, isNew: false, calendar: model.calendar)
        case .duplicate(let copy):
            // The copy shows the original's logo. `AppModel.add` gives it its own file on
            // Add, so Cancel leaves no file behind.
            draft = SubscriptionDraft(copy, isNew: false, calendar: model.calendar)
        }
        _draft = State(initialValue: draft)
        _cancelEnd = State(initialValue: BillingDay(model.today, calendar: model.calendar))
        _isOtherCycle = State(initialValue: Self.isOther(draft.cycle))

        // An existing 2-year plan opens on Other with "Every 2 Years".
        switch draft.cycle {
        case .everyTwoYears:
            _otherCount = State(initialValue: 2)
            _otherUnit = State(initialValue: .years)
        case .custom(let months):
            let years = months % 12 == 0
            _otherCount = State(initialValue: years ? months / 12 : months)
            _otherUnit = State(initialValue: years ? .years : .months)
        default:
            break
        }

        // More options opens by itself when anything in it differs from the defaults.
        if case .edit = mode {
            let defaultReminder = model.document.settings.defaultReminderLeadDays
            let reminderIsDefault = draft.reminderLeadDays == nil || draft.reminderLeadDays == defaultReminder
            let differs = draft.status != .active
                || !reminderIsDefault
                || !draft.manageURLText.trimmingCharacters(in: .whitespaces).isEmpty
                || !draft.notes.trimmingCharacters(in: .whitespaces).isEmpty
                || draft.isEstimate
            _isMoreOpen = State(initialValue: differs)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// The subscription as it was when the sheet opened.
    private var original: Subscription? {
        if case .edit(let subscription, _) = mode { return subscription }
        return nil
    }

    private var openingFocus: SubscriptionEditorFocus {
        if case .edit(_, let focus) = mode { return focus }
        return .name
    }

    /// The whole form inside the scroll view, to scroll to its end.
    private static let formContentID = "formContent"

    private var title: String {
        guard let original else { return "New subscription" }
        return "Edit \(original.name)"
    }

    private var currency: String { Subscription.normalizedCurrency(draft.currency) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        identityCard
                        moneyCard
                        moreCard
                        if isEditing { manageCard }
                    }
                    .padding(8)
                    .id(Self.formContentID)
                }
                .scrollIndicators(.automatic)
                // Finish tabbing through the fields before moving to the fixed footer.
                .focusSection()
                // The questions in the last card are taller than the rows they replace,
                // so they open partly under the footer: `reveal` scrolls them into view.
                .onChange(of: asksCancel) { _, asks in
                    if asks { reveal(.cancel, with: reader) }
                }
                .onChange(of: asksDelete) { _, asks in
                    if asks { reveal(.delete, with: reader) }
                }
            }
            footer
        }
        .frame(width: 580, height: 600)
        .background(DS.Palette.bg100)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(DS.Palette.lineStrong, lineWidth: DS.hairline)
        )
        // A price stays as typed while its field has focus, and is written out with the
        // currency's fraction digits once the person leaves it: "108,8" → "108,80".
        .onChange(of: focus) { left, _ in
            switch left {
            case .price:
                draft.priceText = SubscriptionDraft.tidied(draft.priceText, currency: draft.currency)
            case .change(let id):
                if let index = draft.priceChanges.firstIndex(where: { $0.id == id }) {
                    let row = draft.priceChanges[index]
                    draft.priceChanges[index].priceText = SubscriptionDraft.tidied(row.priceText, currency: row.currency)
                }
            default:
                break
            }
        }
        .onAppear {
            switch openingFocus {
            case .newPriceChange:
                addPriceChange(opensPicker: true)
            case .name:
                Task { @MainActor in focus = .name }
            case .firstPayment:
                break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack {
            Text(title)
                .dsStyle(.heading)
                .foregroundStyle(DS.Palette.ink)
                .lineLimit(1)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(DSIconButtonStyle(size: 30))
            .dsFocusRing(Circle())
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(height: 52)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            summary
                .dsLabel()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Cancel", action: close)
                .buttonStyle(DSSecondaryButtonStyle())
                .dsFocusRing(Capsule())

            Button(isEditing ? "Save" : "Add subscription") { submit() }
                .buttonStyle(DSPrimaryButtonStyle())
                .dsFocusRing(Capsule())
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(draft.subscription() == nil)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: 60)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.line).frame(height: DS.hairline) }
    }

    private var summary: Text {
        switch draft.priceSummary {
        case .unreadableChange:
            return Text("Price change needs a price")
        case .missingStartingPrice:
            return Text("Price is required")
        case .currentPrice(let amount, let currency):
            let monthly = MoneyFormatting.amount(
                Normalizer.monthlyEquivalent(price: amount, cycle: draft.cycle), currency: currency
            )
            let yearly = MoneyFormatting.amount(
                Normalizer.yearlyEquivalent(price: amount, cycle: draft.cycle), currency: currency
            )
            let figures = Text("\(Text.ink(monthly)) / mo · \(Text.ink(yearly)) / yr")
            if draft.status == .trial {
                let until = DateFormatting.dayAndMonth(draft.endDate.startOfDay(in: model.calendar), calendar: model.calendar)
                return Text("Free until \(Text.ink(until)), then \(figures)")
            }
            return figures
        }
    }

    // MARK: - Card 1: identity

    private var identityCard: some View {
        FormCard {
            HStack(spacing: 14) {
                Button { isIconOpen.toggle() } label: {
                    SubscriptionIcon(subscription: previewSubscription, size: 48, unsavedLogo: unsavedLogoImages)
                        .contentShape(SubscriptionIcon.shape(size: 48))
                }
                .buttonStyle(.plain)
                .dsFocusRing(SubscriptionIcon.shape(size: 48))
                .help("Change icon")
                .accessibilityLabel("Change icon")
                .popover(isPresented: $isIconOpen, arrowEdge: .bottom) { iconPopover }

                VStack(alignment: .leading, spacing: 4) {
                    FormLabel("Name", isFocused: focus == .name)
                    TextField("", text: $draft.name, prompt: placeholder("Netflix"))
                        .textFieldStyle(.plain)
                        .font(DSFonts.font(DSFonts.sansRegular, size: 22))
                        .foregroundStyle(DS.Palette.ink)
                        .focused($focus, equals: .name)
                }
            }
            .padding(.vertical, 14)
            .formRow()

            FormDivider()

            HStack {
                FormLabel("Website", isFocused: focus == .website)
                TrailingField(text: $draft.websiteText, placeholder: "netflix.com", font: DSFonts.font(DSFonts.monoRegular, size: 14))
                    .focused($focus, equals: .website)
            }
            .frame(height: 46)
            .formRow()

            FormDivider()

            HStack {
                FormLabel("Category", isFocused: isCategoryOpen)
                Spacer()
                Button { isCategoryOpen.toggle() } label: {
                    HStack(spacing: 8) {
                        if let category = model.category(draft.categoryID) {
                            CategoryMarker(category.tint)
                            Text(category.name)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 10))
                            .foregroundStyle(DS.Palette.inkMuted)
                    }
                }
                .buttonStyle(DSSecondaryButtonStyle(height: 30))
                .dsFocusRing(Capsule())
                .popover(isPresented: $isCategoryOpen, arrowEdge: .bottom) { categoryPopover }
            }
            .frame(height: 46)
            .formRow()
        }
    }

    /// The icon button draws the draft's appearance while the person edits other fields.
    private var previewSubscription: Subscription {
        var subscription = model.newSubscriptionTemplate()
        subscription.name = draft.name.isEmpty ? "?" : draft.name
        subscription.icon = draft.icon
        subscription.tint = draft.tint
        return subscription
    }

    /// The fetched logo as images, for the icon button before Save.
    private var unsavedLogoImages: (logo: NSImage, dark: NSImage?)? {
        guard let fetchedLogo, let logo = NSImage(data: fetchedLogo.logo) else { return nil }
        return (logo, fetchedLogo.dark.flatMap(NSImage.init(data:)))
    }

    /// The domain the draft would fetch a logo from, as typed so far.
    private var draftDomain: String? {
        Subscription.normalizedDomain(draft.websiteText) ?? Subscription.normalizedDomain(draft.manageURLText)
    }

    /// The popover's "Fetch logo": fetches now and shows the result on the icon button,
    /// but stores nothing until Save.
    private func fetchLogo(from domain: String) {
        logoFetchState = .fetching
        Task {
            if let found = await model.fetchLogoData(domain: domain) {
                fetchedLogo = found
                fetchedLogoDomain = domain
                if draft.icon.imageFilename == nil { draft.icon = .initial }
                logoFetchState = .idle
            } else {
                logoFetchState = .notFound(domain)
            }
        }
    }

    private var isLetterMode: Bool {
        if case .letter = draft.icon { return true }
        return false
    }

    /// The icon popover, built like the date picker: the Logo |
    /// Letter switch across the top, one cell for the chosen mode, and a mono Done pill.
    private var iconPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSegmentedSwitch(
                options: [(false, "Logo"), (true, "Letter")],
                selection: isLetterMode,
                onSelect: { letter in
                    if letter {
                        if !isLetterMode { draft.icon = .letter(.blue) }
                    } else {
                        draft.icon = .initial
                    }
                },
                accessibilityLabel: "Icon",
                itemHeight: 24,
                itemPadding: 14,
                trackFill: DS.Palette.bg100,
                fillsWidth: true
            )

            if isLetterMode {
                letterGrid
            } else {
                logoCell
            }

            HStack {
                Spacer()
                Button("Done") { isIconOpen = false }
                    .buttonStyle(DSSecondaryButtonStyle(height: 30, mono: true))
                    .dsFocusRing(Capsule())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 300 - 24)
        .dsPopoverPanel(padding: 12)
    }

    /// Logo mode: where the logo comes from and a Fetch pill, then what happens if there
    /// is none. Without a website there is only that last line.
    private var logoCell: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let domain = draftDomain {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FROM")
                            .font(DSFonts.font(DSFonts.monoMedium, size: 11))
                            .tracking(0.88)
                            .foregroundStyle(DS.Palette.inkMuted)
                        Text(domain)
                            .font(DSFonts.font(DSFonts.monoRegular, size: 14))
                            .foregroundStyle(DS.Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    // No ellipsis while it runs, as everywhere in the interface.
                    Button(fetchTitle(for: domain)) { fetchLogo(from: domain) }
                        .buttonStyle(DSSecondaryButtonStyle(height: 28, mono: true))
                        .dsFocusRing(Capsule())
                        .disabled(logoFetchState == .fetching)
                }
                Rectangle()
                    .fill(DS.Palette.line)
                    .frame(height: 1)
                    .padding(.vertical, 10)
            }
            logoNote
                .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Palette.bg300))
    }

    private func fetchTitle(for domain: String) -> String {
        switch logoFetchState {
        case .fetching: "Fetching"
        case .notFound(let tried) where tried == domain: "Try again"
        default: "Fetch"
        }
    }

    private var logoNote: Text {
        guard let domain = draftDomain else {
            return Text("Add a website to fetch its logo").foregroundStyle(DS.Palette.inkMuted)
        }
        if logoFetchState == .notFound(domain) {
            return Text("Nothing found on this site").foregroundStyle(DS.Palette.warning)
        }
        return Text("Falls back to the letter").foregroundStyle(DS.Palette.inkMuted)
    }

    /// Letter mode: the eight colours as 4 × 2 cells, each with the name's initial. The
    /// picked one has a 1pt `ink` ring 2pt outside it.
    private var letterGrid: some View {
        let initial = IconInitial.initial(of: draft.name.isEmpty ? "?" : draft.name)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(LetterColor.allCases, id: \.self) { color in
                let isSelected = draft.icon == .letter(color)
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                Button { draft.icon = .letter(color) } label: {
                    Text(initial)
                        .font(DSFonts.font(DSFonts.monoRegular, size: 15))
                        .foregroundStyle(DS.Palette.accentInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(shape.fill(DS.letterColor(color)))
                        .overlay {
                            if isSelected {
                                shape.inset(by: -3).strokeBorder(DS.Palette.ink, lineWidth: 1)
                            }
                        }
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .dsFocusRing(shape)
                .accessibilityLabel(color.rawValue.capitalized)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
    }

    /// Category rows show the colour, name and active subscription count. A checkmark marks the selection.
    private var categoryPopover: some View {
        ScrollViewReader { reader in
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(model.document.categories.sorted { $0.sortOrder < $1.sortOrder }) { category in
                    let isSelected = category.id == draft.categoryID
                    CategoryListRow(
                        title: category.name,
                        tint: category.tint,
                        trailing: isSelected ? "✓" : "\(model.activeCount(in: category.id))"
                    ) {
                        draft.categoryID = category.id
                        isCategoryOpen = false
                    }
                    .id(category.id)
                }
            }
            .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Opens on the category already picked.
        .onAppear { reader.scrollTo(draft.categoryID, anchor: .center) }
        }
        .frame(width: 230)
        .frame(maxHeight: 34 * 13 + 12)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Palette.bg300)
    }

    // MARK: - Card 2: money

    private var moneyCard: some View {
        FormCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    FormLabel(draft.priceChanges.isEmpty ? "Price" : "Starting price", isFocused: focus == .price)
                    TextField("", text: $draft.priceText, prompt: placeholder(pricePlaceholder(for: currency)))
                        .textFieldStyle(.plain)
                        .font(DSTextStyle.numLG.font)
                        .foregroundStyle(DS.Palette.ink)
                        .focused($focus, equals: .price)
                }
                Spacer()
                currencyMenu
            }
            .padding(.vertical, 12)
            .formRow()

            ForEach($draft.priceChanges) { $change in
                FormDivider()
                HStack(spacing: 10) {
                    FormLabel("From", isFocused: focus == .change(change.id))
                    DatePill(
                        date: $change.date,
                        today: model.today,
                        calendar: model.calendar,
                        opensOnAppear: change.id == autoOpenChange
                    )
                    Spacer()
                    TrailingField(
                        text: $change.priceText,
                        placeholder: pricePlaceholder(for: change.currency),
                        font: DSFonts.font(DSFonts.monoRegular, size: 17)
                    )
                        .frame(width: 110)
                        .focused($focus, equals: .change(change.id))
                    Text(currencySymbol(for: change.currency))
                        .font(DSFonts.font(DSFonts.monoRegular, size: 17))
                        .foregroundStyle(DS.Palette.inkMuted)
                    Button {
                        draft.priceChanges.removeAll { $0.id == change.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(DSIconButtonStyle(size: 28))
                    .dsFocusRing(Circle())
                    .help("Remove this price change")
                    .accessibilityLabel("Remove price change")
                }
                .frame(height: 46)
                .formRow()
            }

            FormDivider()

            HStack {
                FormLabel(priceChangesLabel, isFocused: false)
                Spacer()
                Button { addPriceChange() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11))
                        Text("Add price change")
                    }
                }
                .buttonStyle(DSSecondaryButtonStyle(height: 28, mono: true))
                .dsFocusRing(Capsule())
            }
            .frame(height: 46)
            .formRow()

            FormDivider()

            HStack {
                FormLabel("Every", isFocused: false)
                Spacer()
                DSSegmentedSwitch(
                    options: CycleChoice.allCases.map { ($0, $0.title) },
                    selection: cycleChoice,
                    onSelect: selectCycle,
                    accessibilityLabel: "Billing cycle",
                    itemHeight: 24,
                    itemPadding: 10,
                    trackFill: DS.Palette.bg100
                )
            }
            .frame(height: 46)
            .formRow()

            if isOtherCycle {
                FormDivider()
                HStack(spacing: 10) {
                    FormLabel("Every", isFocused: focus == .otherCount)
                    Spacer()
                    TextField("", value: $otherCount, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(DSFonts.font(DSFonts.monoRegular, size: 17))
                        .foregroundStyle(DS.Palette.ink)
                        .frame(width: 44)
                        .focused($focus, equals: .otherCount)
                        .onChange(of: otherCount) { _, _ in applyOtherCycle() }
                    DSSegmentedSwitch(
                        options: [(OtherUnit.months, "Months"), (.years, "Years")],
                        selection: otherUnit,
                        onSelect: { otherUnit = $0; applyOtherCycle() },
                        accessibilityLabel: "Unit",
                        itemHeight: 24,
                        itemPadding: 10,
                        trackFill: DS.Palette.bg100
                    )
                }
                .frame(height: 46)
                .formRow()
            }

            FormDivider()

            HStack {
                FormLabel("First payment", isFocused: false)
                Spacer()
                // Empty until picked; a subscription may be added without one and then
                // shows "–" (no renewal date) in the lists.
                DatePill(
                    date: $draft.anchorDate,
                    isSet: $draft.hasAnchor,
                    allowsClear: true,
                    today: model.today,
                    calendar: model.calendar,
                    opensOnAppear: openingFocus == .firstPayment
                )
            }
            .frame(height: 46)
            .formRow()
        }
    }

    private func pricePlaceholder(for currency: String) -> String {
        SubscriptionDraft.format(0, currency: currency)
    }

    private func currencySymbol(for currency: String) -> String {
        // The symbol as the locale writes it, read off a formatted zero ("0,00 €" → "€").
        let symbol = MoneyFormatting.amount(0, currency: currency)
            .filter { !$0.isNumber && $0 != "," && $0 != "." && !$0.isWhitespace && $0 != "-" }
        return symbol.isEmpty ? currency : symbol
    }

    private var currencyMenu: some View {
        Menu {
            ForEach(model.currencyChoices, id: \.self) { code in
                Button(code) { draft.setCurrency(code) }
            }
        } label: {
            HStack(spacing: 6) {
                Text("\(currency) \(currencySymbol(for: currency))")
                Image(systemName: "chevron.down").font(.system(size: 10))
                    .foregroundStyle(DS.Palette.inkMuted)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(DSSecondaryButtonStyle(height: 30, mono: true))
        .fixedSize()
        .dsFocusRing(Capsule())
        .accessibilityLabel("Currency, \(currency)")
    }

    private var priceChangesLabel: String {
        switch draft.priceChanges.count {
        case 0: "Price changes"
        case 1: "1 price change"
        default: "\(draft.priceChanges.count) price changes"
        }
    }

    /// A new change one billing cycle after the latest date on file, so it lands on a
    /// payment rather than on today.
    private func addPriceChange(opensPicker: Bool = false) {
        let lastDay = draft.priceChanges.map(\.date).max() ?? draft.anchorDate
        let last = lastDay.startOfDay(in: model.calendar)
        let months = max(1, draft.cycle.months ?? 1)
        let date = model.calendar.date(byAdding: .month, value: months, to: last) ?? last
        let row = SubscriptionDraft.PriceChangeRow(
            date: BillingDay(date, calendar: model.calendar), priceText: "", currency: draft.currency
        )
        draft.priceChanges.append(row)
        if opensPicker {
            autoOpenChange = row.id
        } else {
            Task { @MainActor in focus = .change(row.id) }
        }
    }

    // MARK: Cycle

    /// The four common cycles, and Other for any number of months or years (2 years,
    /// 6 months), which the app already supports as `custom(months:)`.
    enum CycleChoice: CaseIterable, Hashable {
        case weekly, monthly, quarterly, yearly, other

        var title: String {
            switch self {
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .quarterly: "Quarterly"
            case .yearly: "Yearly"
            case .other: "Other"
            }
        }
    }

    private static func isOther(_ cycle: BillingCycle) -> Bool {
        switch cycle {
        case .weekly, .monthly, .quarterly, .yearly: false
        case .everyTwoYears, .custom: true
        }
    }

    private var cycleChoice: CycleChoice {
        if isOtherCycle { return .other }
        switch draft.cycle {
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .quarterly: return .quarterly
        case .yearly: return .yearly
        case .everyTwoYears, .custom: return .other
        }
    }

    private func selectCycle(_ choice: CycleChoice) {
        switch choice {
        case .weekly: draft.cycle = .weekly
        case .monthly: draft.cycle = .monthly
        case .quarterly: draft.cycle = .quarterly
        case .yearly: draft.cycle = .yearly
        case .other:
            isOtherCycle = true
            applyOtherCycle()
            Task { @MainActor in focus = .otherCount }
            return
        }
        isOtherCycle = false
    }

    /// "Every 2 years" and the like, folded onto the cycles the model already names.
    private func applyOtherCycle() {
        let count = max(1, otherCount)
        let months = otherUnit == .years ? count * 12 : count
        draft.cycle = switch months {
        case 1: .monthly
        case 3: .quarterly
        case 12: .yearly
        case 24: .everyTwoYears
        default: .custom(months: months)
        }
    }

    // MARK: - Card 3: more options

    private var moreCard: some View {
        FormCard {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isMoreOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    FormLabel("More options", isFocused: false)
                    if !isMoreOpen {
                        Text(moreSummary)
                            .dsStyle(.label)
                            .foregroundStyle(DS.Palette.inkDisabled)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Palette.inkMuted)
                        .rotationEffect(.degrees(isMoreOpen ? 180 : 0))
                }
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dsFocusRing(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .formRow()
            .accessibilityLabel("More options")
            .accessibilityValue(isMoreOpen ? "Expanded" : "Collapsed")

            if isMoreOpen {
                FormDivider()
                HStack {
                    FormLabel("Status", isFocused: false)
                    Spacer()
                    DSSegmentedSwitch(
                        // No Pause; cancelling is in the last card.
                        options: [(Status.active, "Active"), (.trial, "Trial")],
                        selection: draft.status,
                        onSelect: selectStatus,
                        accessibilityLabel: "Status",
                        itemHeight: 24,
                        itemPadding: 12,
                        trackFill: DS.Palette.bg100
                    )
                }
                .frame(height: 46)
                .formRow()

                if draft.status == .trial {
                    FormDivider()
                    HStack {
                        FormLabel("Trial ends", isFocused: false)
                        Spacer()
                        DatePill(date: $draft.endDate, isAccent: true, today: model.today, calendar: model.calendar)
                    }
                    .frame(height: 46)
                    .formRow()
                }

                FormDivider()
                HStack {
                    FormLabel("Remind me", isFocused: false)
                    Spacer()
                    // Four segments, and a fifth for a lead that has none of its own.
                    let reminderSwitch = SubscriptionReminderSwitch(
                        stored: draft.reminderLeadDays,
                        defaultLead: model.document.settings.defaultReminderLeadDays
                    )
                    DSSegmentedSwitch(
                        options: reminderSwitch.segments.map { ($0.days, $0.title) },
                        selection: reminderSwitch.selected,
                        onSelect: { draft.reminderLeadDays = $0 },
                        accessibilityLabel: "Remind me",
                        itemHeight: 24,
                        itemPadding: 10,
                        trackFill: DS.Palette.bg100
                    )
                }
                .frame(height: 46)
                .formRow()

                FormDivider()
                textRow("Account page", text: $draft.manageURLText, prompt: "netflix.com/account", field: .account, mono: true)

                FormDivider()
                textRow("Notes", text: $draft.notes, prompt: "Anything to remember", field: .notes, mono: false)

                FormDivider()
                HStack {
                    FormLabel("Price may vary", isFocused: false)
                    Spacer()
                    Toggle("Price may vary", isOn: $draft.isEstimate)
                        .dsSwitch()
                        .tint(DS.Palette.accent)
                        .help("The price is an estimate: totals that include it show ~")
                }
                .frame(height: 46)
                .formRow()
            }
        }
    }

    private func textRow(_ label: String, text: Binding<String>, prompt: String, field: Field, mono: Bool) -> some View {
        HStack(spacing: 12) {
            FormLabel(label, isFocused: focus == field)
                .fixedSize()
            TrailingField(text: text, placeholder: prompt, font: mono ? DSFonts.font(DSFonts.monoRegular, size: 14) : DSTextStyle.body.font)
                .focused($focus, equals: field)
        }
        .frame(height: 46)
        .formRow()
    }

    /// The reminder as it will apply: the subscription's own, or the default from
    /// Settings when it has none.
    private var reminderDays: Int {
        draft.reminderLeadDays ?? model.document.settings.defaultReminderLeadDays
    }

    private func selectStatus(_ status: Status) {
        if !draft.status.isBilling {
            // Back from cancelled: billing again, with no stop and no end.
            draft.hasBillingStop = false
            draft.hasEndDate = false
            beforeCancel = nil
        }
        draft.status = status
        if status == .trial, !draft.hasEndDate {
            draft.hasEndDate = true
            let date = model.calendar.date(byAdding: .day, value: 7, to: model.today) ?? model.today
            draft.endDate = BillingDay(date, calendar: model.calendar)
        }
    }

    private var moreSummary: String {
        let reminder = switch reminderDays {
        case Subscription.noReminder: "No reminder"
        case 0: "Remind on the day"
        case 1: "Remind 1 day"
        case 7: "Remind 1 week"
        default: "Remind \(reminderDays) days"
        }
        return "\(draft.status.displayName) · \(reminder)"
    }

    // MARK: - Save

    private func submit() {
        guard model.activeSheet?.id == sheetID, let subscription = draft.subscription() else { return }
        if let original {
            model.update(subscription)
            // In Logo mode only (a letter or an icon the person chose stays as it is): a
            // logo fetched in the popover is stored now; otherwise a new website, or no
            // usable logo at all (Letter and back drops it), fetches one.
            let websiteChanged = original.effectiveDomain != subscription.effectiveDomain
            if !storeFetchedLogo(for: subscription),
               subscription.effectiveDomain != nil,
               Self.isLogoMode(subscription.icon),
               websiteChanged || model.logoFetchDomain(for: subscription) != nil {
                Task { await model.fetchLogo(for: subscription.id) }
            }
            close()
        } else {
            let copy: Subscription?
            if case .duplicate(let source) = mode { copy = source } else { copy = nil }
            let added = model.add(subscription, copyingHistoryFrom: copy)
            // The logo is fetched from the website once the subscription exists, so
            // Cancel never fetches anything; the row shows the initial until it arrives.
            // A duplicate keeps the original's logo unless its website changed: as in
            // Edit, a new website means a new logo.
            var needsLogo = added.icon == .initial
            if let copy, added.icon.imageFilename != nil {
                needsLogo = copy.effectiveDomain != added.effectiveDomain
            }
            if !storeFetchedLogo(for: added), needsLogo, added.effectiveDomain != nil {
                Task { await model.fetchLogo(for: added.id) }
            }
            close()
            onAdded(added)
        }
    }

    private func close() {
        model.dismissSheet(sheetID)
    }

    private static func isLogoMode(_ icon: Icon) -> Bool {
        icon == .initial || icon.imageFilename != nil
    }

    /// Stores the logo fetched in the popover, if there is one, the icon is still in
    /// Logo mode and the website is still the one it came from. `true` once stored.
    private func storeFetchedLogo(for saved: Subscription) -> Bool {
        guard let fetchedLogo, Self.isLogoMode(saved.icon),
              fetchedLogoDomain == Subscription.normalizedDomain(saved.effectiveDomain)
        else { return false }
        return model.applyLogo(fetchedLogo.logo, dark: fetchedLogo.dark, to: saved.id)
    }

    // MARK: - Card 4: cancel or delete (edit only)

    /// The status fields "Mark as cancelled" changes.
    private struct StatusFields {
        var status: Status
        var hasBillingStop: Bool
        var billingStopDate: BillingDay
        var hasEndDate: Bool
        var endDate: BillingDay
    }

    private var statusFields: StatusFields {
        StatusFields(
            status: draft.status,
            hasBillingStop: draft.hasBillingStop,
            billingStopDate: draft.billingStopDate,
            hasEndDate: draft.hasEndDate,
            endDate: draft.endDate
        )
    }

    private func apply(_ fields: StatusFields) {
        draft.status = fields.status
        draft.hasBillingStop = fields.hasBillingStop
        draft.billingStopDate = fields.billingStopDate
        draft.hasEndDate = fields.hasEndDate
        draft.endDate = fields.endDate
    }

    private var isCancelled: Bool { !draft.status.isBilling }

    /// The last card, in Edit only: Mark as cancelled (or Reactivate) and Delete. Both
    /// rows 42pt with a line icon, a label and a hint on the right; Delete turns into its
    /// confirmation in place.
    private var manageCard: some View {
        FormCard {
            if asksCancel {
                CancelPrompt(
                    name: draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? "it" : draft.name,
                    endDate: $cancelEnd,
                    today: model.today,
                    calendar: model.calendar,
                    onKeep: { withAnimation(.easeOut(duration: 0.15)) { asksCancel = false } },
                    onConfirm: {
                        markCancelled(endingOn: cancelEnd)
                        withAnimation(.easeOut(duration: 0.15)) { asksCancel = false }
                    }
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .id(Self.cancelQuestionID)
                .transition(Self.questionFade)
            } else {
                manageRow(
                    icon: isCancelled ? "arrow.uturn.backward" : "nosign",
                    title: isCancelled ? "Reactivate" : "Mark as cancelled",
                    hint: isCancelled ? endsHint : "Keeps history",
                    hintColor: isCancelled ? DS.Palette.warning : DS.Palette.inkDisabled,
                    isDanger: false,
                    action: toggleCancelled
                )
                .transition(Self.questionFade)
            }
            FormDivider()
            if asksDelete {
                deleteConfirmation
                    .transition(Self.questionFade)
            } else {
                manageRow(
                    icon: "trash",
                    title: "Delete subscription",
                    hint: "Removes history",
                    hintColor: DS.Palette.inkDisabled,
                    isDanger: true
                ) {
                    // Only the fade is animated, not the card growing: a scroll view
                    // drops a scroll asked for while its content is still animating, and
                    // the growth is under the footer, out of sight, anyway.
                    asksDelete = true
                }
                .transition(Self.questionFade)
            }
        }
    }

    /// Each row and its question fade into each other in 0.15 s.
    private static let questionFade = AnyTransition.opacity.animation(.easeOut(duration: 0.15))
    /// The Mark as cancelled question, to scroll into view.
    private static let cancelQuestionID = "cancelQuestion"

    /// A question that opens in place of its row in the last card.
    private enum Question { case cancel, delete }

    /// Scrolls the question that just opened into view, in the same 0.15 s as it fades
    /// in, and only as far as needed: nothing moves when it is already in view, and Keep
    /// does not scroll back. The delete question is the last thing in the form, so the
    /// form goes to its end; the Delete row stays under the cancel question, so the form
    /// goes only as far as the question's own bottom, or to its top when it is taller
    /// than the visible part of the form (a very long name).
    private func reveal(_ question: Question, with reader: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            switch question {
            case .cancel: reader.scrollTo(Self.cancelQuestionID)
            case .delete: reader.scrollTo(Self.formContentID, anchor: .bottom)
            }
        }
    }

    /// "Ends 3 Dec", or "Cancelled" when no end date is known.
    private var endsHint: String {
        guard draft.hasEndDate else { return "Cancelled" }
        return "Ends " + DateFormatting.dayAndMonth(draft.endDate.startOfDay(in: model.calendar), calendar: model.calendar)
    }

    /// Applies on Save, like the rest of the form. Cancelling ends access on the next
    /// payment, which will not be charged; Reactivate puts back what was there, or makes
    /// it active with no stop and no end.
    private func toggleCancelled() {
        if isCancelled {
            if let beforeCancel {
                apply(beforeCancel)
                self.beforeCancel = nil
            } else {
                draft.status = .active
                draft.hasBillingStop = false
                draft.hasEndDate = false
                if !draft.hasAnchor {
                    draft.hasAnchor = true
                    draft.anchorDate = BillingDay(model.today, calendar: model.calendar)
                }
            }
        } else {
            // Asks when access ends first (`CancelPrompt`), the next payment by default.
            let today = BillingDay(model.today, calendar: model.calendar)
            cancelEnd = original.map { CancelPrompt.defaultEnd(for: $0.id, model: model) } ?? today
            asksDelete = false
            // Only the fade is animated, as for Delete (`reveal`).
            asksCancel = true
        }
    }

    /// The answer to the prompt. Applies on Save, like the rest of the form.
    private func markCancelled(endingOn end: BillingDay) {
        beforeCancel = statusFields
        let today = BillingDay(model.today, calendar: model.calendar)
        draft.status = .cancelled
        draft.hasBillingStop = true
        draft.billingStopDate = today
        draft.hasEndDate = true
        draft.endDate = max(today, end)
    }

    private func manageRow(
        icon: String,
        title: String,
        hint: String,
        hintColor: Color,
        isDanger: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(isDanger ? DS.Palette.danger : DS.Palette.inkMuted)
                Text(title)
                    .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                    .foregroundStyle(isDanger ? DS.Palette.danger : DS.Palette.ink)
                Spacer(minLength: 8)
                Text(hint)
                    .dsStyle(.label)
                    .font(DSFonts.font(DSFonts.monoMedium, size: 10))
                    .foregroundStyle(hintColor)
                    .lineLimit(1)
            }
            .frame(height: 42)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        // The highlight fills the card's width at 4% opacity. The card clips its outer corners
        // and keeps the divider between rows straight.
        .buttonStyle(CardRowStyle())
        .dsFocusRing(Rectangle())
        .focusEffectDisabled()
    }

    /// "Delete Claude Max?" with what goes with it, in place of the Delete row.
    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DeletePrompt.title(name: original?.name))
                .font(DSFonts.font(DSFonts.sansMedium, size: 15))
                .foregroundStyle(DS.Palette.ink)
            Text(DeletePrompt.message(for: original?.id, model: model))
                .font(DSFonts.font(DSFonts.sansRegular, size: 13))
                .foregroundStyle(DS.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Keep") {
                    withAnimation(.easeOut(duration: 0.15)) { asksDelete = false }
                }
                .buttonStyle(DSSecondaryButtonStyle(height: 30))
                .dsFocusRing(Capsule())
                Button("Delete") { confirmDelete() }
                    .buttonStyle(DangerFillStyle())
                    .dsFocusRing(Capsule())
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 14)
        .formRow()
    }

    private func confirmDelete() {
        guard model.activeSheet?.id == sheetID, let original else { return }
        model.delete(original.id)
        onDeleted()
    }

    private func placeholder(_ text: String) -> Text {
        Text(text).foregroundStyle(DS.Palette.inkDisabled)
    }
}

// MARK: - Pieces

/// A card in the form: `bg200`, 1pt `line`, 18pt corners (`DS.panelShape`). Rows pad themselves, so the lines between them run edge to edge.
private struct FormCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .dsCard(border: DS.hairline)
    }
}

/// A card row that is a button: `ink` at 4% across the whole row on hover, press and
/// keyboard focus, with square edges (the card clips it to its corners).
private struct CardRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let lit = configuration.isPressed || isHovering || (isFocused && InputModality.shared.isKeyboard)
            configuration.label
                .background(Rectangle().fill(DS.Palette.ink.opacity(lit ? 0.04 : 0)))
                .animation(.easeOut(duration: 0.1), value: lit)
                .onHover { isHovering = $0 }
        }
    }
}

private struct FormDivider: View {
    var body: some View {
        Rectangle().fill(DS.Palette.line).frame(height: DS.hairline)
    }
}

/// The mono uppercase label; orange while its field has focus, in place of a focus ring.
private struct FormLabel: View {
    let text: String
    let isFocused: Bool

    init(_ text: String, isFocused: Bool) {
        self.text = text
        self.isFocused = isFocused
    }

    var body: some View {
        Text(text)
            .dsStyle(.label)
            .foregroundStyle(isFocused ? DS.Palette.accent : DS.Palette.inkMuted)
            .lineLimit(1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

private extension View {
    func formRow() -> some View {
        padding(.horizontal, 18)
            .focusEffectDisabled()
    }
}

/// A right-aligned text field whose placeholder is right-aligned too: a plain
/// `TextField` on macOS keeps its prompt on the left whatever the text alignment.
private struct TrailingField: View {
    @Binding var text: String
    let placeholder: String
    let font: Font

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(font)
            .foregroundStyle(DS.Palette.ink)
            .lineLimit(1)
            .background(alignment: .trailing) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(DS.Palette.inkDisabled)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(placeholder)
    }
}

/// A date as a pill (calendar icon and mono date) that opens the day picker. Reads
/// "Pick date" while unset; its border turns `ink` while the picker is open.
struct DatePill: View {
    @Binding var date: BillingDay
    /// For a date that may be unset; `.constant(true)` for one that always has a value.
    var isSet: Binding<Bool> = .constant(true)
    /// Offer Clear in the picker (only where an empty date is allowed).
    var allowsClear = false
    var isAccent = false
    let today: Date
    let calendar: Calendar
    /// Open the picker as soon as the pill appears.
    var opensOnAppear = false
    @State private var isOpen = false

    private var localDate: Binding<Date> {
        Binding(
            get: { date.startOfDay(in: calendar) },
            set: { date = BillingDay($0, calendar: calendar) }
        )
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 11))
                Text(isSet.wrappedValue ? DateFormatting.full(localDate.wrappedValue, calendar: calendar) : "Pick date")
                    .font(DSFonts.font(DSFonts.monoRegular, size: 13))
            }
            .foregroundStyle(isAccent ? DS.Palette.accent : isSet.wrappedValue ? DS.Palette.ink : DS.Palette.inkMuted)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(isAccent ? DS.Palette.accentTint : .clear))
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: DS.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .dsFocusRing(Capsule())
        .accessibilityLabel(isSet.wrappedValue ? localDate.wrappedValue.formatted(
            Date.FormatStyle(date: .long, time: .omitted, calendar: calendar, timeZone: calendar.timeZone)
        ) : "Pick date")
        .onAppear {
            if opensOnAppear {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    isOpen = true
                }
            }
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DayPicker(
                date: localDate,
                isSet: isSet,
                allowsClear: allowsClear,
                today: today,
                calendar: calendar,
                onDone: { isOpen = false }
            )
        }
    }

    private var borderColor: Color {
        if isAccent { return DS.Palette.accent }
        return isOpen ? DS.Palette.ink : DS.Palette.lineStrong
    }
}
#Preview("New subscription") {
    let model = AppModel.handoffPreview()
    model.presentAdd()
    return MainWindow(model: model)
}

// MARK: - Danger buttons

/// The confirming Delete: a `danger` fill with dark text.
private struct DangerFillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsStyle(.button)
            .foregroundStyle(DS.Palette.dangerInk)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(DS.Palette.danger).brightness(configuration.isPressed ? -0.08 : 0))
            .contentShape(Capsule())
    }
}

#Preview("Edit subscription") {
    let model = AppModel.handoffPreview { document in
        // A plan with a price history and options set, so the edit form has work to show.
        guard let index = document.subscriptions.firstIndex(where: { $0.name == "NordVPN" }) else { return }
        document.subscriptions[index].priceChanges = [
            PriceChange(effectiveFrom: SampleData.billingDay(2024, 8, 31), price: 79, currency: "EUR")
        ]
        document.subscriptions[index].currentPriceSince = SampleData.billingDay(2026, 8, 31)
        document.subscriptions[index].notes = "Family plan"
    }
    model.section = .all
    if let id = model.document.subscriptions.first(where: { $0.name == "NordVPN" })?.id {
        model.selectSubscriptionRow(id)
        model.presentEdit(id)
    }
    return MainWindow(model: model)
}
