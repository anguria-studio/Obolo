import SwiftUI
import OboloCore

/// Lets the user review CSV rows before importing them.
///
/// `CSVImporter` splits import into a pure `preview` and an `apply`, and this is the gap
/// between them: every row the file produced, what the app made of it, and what it could
/// not. Nothing here writes to the document until Import is pressed.
///
/// Drawn like New subscription: 580 × 600 over the dimmed window, 24pt corners, a 52pt
/// header with the file's name, and a footer that says what Import will do. Each row has
/// its own checkbox. A row with an error is never imported (its box is off and
/// disabled); a row that looks like one already in Obolo starts unticked; everything
/// else starts ticked. Row-level problems never abort an import: a bad line must not
/// cost the user the other forty.
struct ImportPreviewSheet: View {
    let preview: ImportPreview
    let model: AppModel
    let sheetID: WindowSheet.ID

    @State private var selection: ImportPreviewSelection?
    /// On by default: the alternative is a pile of subscriptions in "Other", which is a
    /// worse default than a few new categories the user can rename.
    @State private var createMissingCategories = true
    /// On by default: a freshly imported list of letters is exactly the moment a logo is
    /// worth having. It runs after the import lands.
    @State private var fetchLogosAfterImport = true
    @FocusState private var closeFocused: Bool

    private var currency: String { model.document.settings.baseCurrency }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let selection {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        rowsCard(selection)
                        optionsCard(selection)
                        note
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
                .focusSection()
                footer(selection)
            } else {
                Spacer()
            }
        }
        .frame(width: 580, height: 600)
        .background(DS.Palette.bg100)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(DS.Palette.lineStrong, lineWidth: DS.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Import CSV")
        .onChange(of: preview, initial: true) { _, preview in
            selection = ImportPreviewSelection(preview: preview, document: model.document)
        }
        .onChange(of: model.document) { _, document in
            selection = ImportPreviewSelection(preview: preview, document: document, selected: selection?.selected)
        }
        .onAppear { Task { @MainActor in closeFocused = true } }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Import CSV")
                    .dsStyle(.heading)
                    .foregroundStyle(DS.Palette.ink)
                if let name = preview.sourceName {
                    Text(name)
                        .font(DSFonts.font(DSFonts.monoRegular, size: 13))
                        .foregroundStyle(DS.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(DSIconButtonStyle(size: 30))
            .dsFocusRing(Circle())
            .focused($closeFocused)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(height: 52)
    }

    private func footer(_ selection: ImportPreviewSelection) -> some View {
        let count = selection.selected.count
        return HStack(spacing: 10) {
            Text("\(Text.ink("\(count)")) to import · \(Text.ink(MoneyFormatting.amount(selection.selectedMonthly, currency: currency))) / mo")
                .dsLabel()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Cancel", action: close)
                .buttonStyle(DSSecondaryButtonStyle())
                .dsFocusRing(Capsule())

            Button(count > 0 ? "Import \(count)" : "Import") { importSelected(selection.selected) }
                .buttonStyle(DSPrimaryButtonStyle())
                .dsFocusRing(Capsule())
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(height: 60)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.line).frame(height: DS.hairline) }
    }

    // MARK: - Rows

    private func rowsCard(_ selection: ImportPreviewSelection) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            rowsHeader(selection)
                .padding(.bottom, 10)
            if preview.isEmpty {
                Text("That file has a header row, but no rows to import.")
                    .dsStyle(.bodySmall)
                    .foregroundStyle(DS.Palette.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(DS.Palette.line).frame(height: DS.hairline) }
            } else {
                ForEach(preview.rows) { row in
                    rowView(row, selection: selection)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .importCard()
    }

    private func rowsHeader(_ selection: ImportPreviewSelection) -> some View {
        HStack(spacing: 10) {
            Toggle("Select all", isOn: Binding(
                get: { selection.allSelected },
                set: { selection.selectAll($0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!selection.hasSelectableRows)

            Text("\(Text.ink("\(preview.rows.count)")) found · \(Text("\(selection.checkCount)").foregroundStyle(DS.Palette.warning)) to check · \(Text("\(selection.errorCount)").foregroundStyle(DS.Palette.danger)) skipped")
                .dsLabel()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("/ month")
                .dsStyle(.labelSmall)
                .foregroundStyle(DS.Palette.inkDisabled)
        }
    }

    private func rowView(_ row: ImportRow, selection: ImportPreviewSelection) -> some View {
        let isOn = selection.selected.contains(row.lineNumber)
        let details = selection.detailsByLine[row.lineNumber]
        let isImportable = details?.isImportable == true
        let flag = flag(for: row, isDuplicate: details?.knownSubscription != nil)
        return HStack(spacing: 10) {
            Toggle(row.subscription?.name ?? "Row \(row.lineNumber)", isOn: Binding(
                get: { selection.selected.contains(row.lineNumber) },
                set: { selection.setSelected(row.lineNumber, to: $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isImportable)

            icon(row, known: details?.knownSubscription)

            VStack(alignment: .leading, spacing: 0) {
                Text(row.subscription?.name ?? "Row \(row.lineNumber)")
                    .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                    .foregroundStyle(DS.Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    CategoryMarker(color: DS.category(selection.categoryHue(for: row.categoryName)), size: 7)
                    Text(categoryName(row))
                    if selection.isNewCategory(row.categoryName) {
                        Text("· New").foregroundStyle(DS.Palette.accent)
                    }
                    if let flag {
                        Text("· \(flag.text)")
                            .foregroundStyle(flag.isError ? DS.Palette.danger : DS.Palette.warning)
                    }
                }
                .dsStyle(.labelSmall)
                .foregroundStyle(DS.Palette.inkMuted)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            amount(row)
                .frame(width: 130, alignment: .trailing)

            Text(details?.monthly.map { MoneyFormatting.amount($0, currency: currency) } ?? "–")
                .font(DSFonts.font(DSFonts.monoRegular, size: 13))
                .foregroundStyle(DS.Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .opacity(!isImportable ? 0.45 : isOn ? 1 : 0.55)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.line).frame(height: DS.hairline) }
        .help(row.issues.map(\.message).joined(separator: "\n"))
    }

    /// The logo when the subscription is already known, else a calm initials square.
    @ViewBuilder
    private func icon(_ row: ImportRow, known: Subscription?) -> some View {
        if let known, known.icon.imageFilename != nil {
            IconInitial(subscription: known, size: 22)
        } else {
            Text(initials(row.subscription?.name ?? "?"))
                .font(DSFonts.font(DSFonts.monoMedium, size: 9))
                .foregroundStyle(DS.Palette.inkMuted)
                .frame(width: 22, height: 22)
                .background(SubscriptionIcon.shape(size: 22).fill(DS.Palette.bg300))
                .overlay(SubscriptionIcon.shape(size: 22).strokeBorder(DS.Palette.line, lineWidth: DS.hairline))
        }
    }

    private func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters
    }

    /// "14,99 €" with "/mo" after it in 11pt `inkDisabled`.
    @ViewBuilder
    private func amount(_ row: ImportRow) -> some View {
        if let subscription = row.subscription {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(MoneyFormatting.amount(subscription.price, currency: subscription.currency, estimate: subscription.isEstimate))
                    .dsStyle(.data)
                    .foregroundStyle(DS.Palette.ink)
                Text(subscription.cycle.compactSuffix)
                    .font(DSFonts.font(DSFonts.monoRegular, size: 11))
                    .foregroundStyle(DS.Palette.inkDisabled)
            }
            .lineLimit(1)
        } else {
            Text("–").dsStyle(.data).foregroundStyle(DS.Palette.ink)
        }
    }

    // MARK: - Categories

    private func categoryName(_ row: ImportRow) -> String {
        row.categoryName.isEmpty ? OboloCore.Category.fallbackName : row.categoryName
    }

    // MARK: - Flags

    private struct Flag {
        let text: String
        let isError: Bool
    }

    /// The one thing to say about a row, most pressing first: an error (never imported),
    /// then "Already in Obolo", "No first payment", then the first warning, each short.
    /// The full messages are the row's tooltip.
    private func flag(for row: ImportRow, isDuplicate: Bool) -> Flag? {
        if let error = row.issues.first(where: { $0.severity == .error }) ?? (row.subscription == nil ? .error("") : nil) {
            return Flag(text: errorText(error), isError: true)
        }
        if isDuplicate { return Flag(text: "Already in Obolo", isError: false) }
        if row.subscription?.anchorDate == nil { return Flag(text: "No first payment", isError: false) }
        if let warning = row.issues.first(where: { $0.severity == .warning }) {
            return Flag(text: warningText(warning), isError: false)
        }
        return nil
    }

    private func errorText(_ issue: ImportIssue) -> String {
        switch field(issue) {
        case .name: "No name"
        case .price: "Unreadable price"
        case .cycle: "Unreadable cycle"
        default: "Skipped"
        }
    }

    private func warningText(_ issue: ImportIssue) -> String {
        switch field(issue) {
        case .price: "Missing price"
        case .currency: "Currency guessed"
        case .anchorDate, .currentPriceSince, .billingStoppedOn, .endsOn: "Date unreadable"
        case .priceHistory: "Part of history"
        case .status, .active: "Status guessed"
        case .manageURL, .website: "Link unreadable"
        default: "Check row"
        }
    }

    /// Which field an issue is about, from the header it names.
    private func field(_ issue: ImportIssue) -> CSVField? {
        guard let column = issue.column else { return nil }
        return CSVField.matching(header: column)
    }

    // MARK: - Options

    private func optionsCard(_ selection: ImportPreviewSelection) -> some View {
        VStack(spacing: 0) {
            if !selection.selectedNewCategories.isEmpty {
                optionRow(
                    "Create missing categories",
                    newCategoriesDescription(selection.selectedNewCategories, selectedCount: selection.selected.count),
                    isOn: $createMissingCategories
                )
                Rectangle().fill(DS.Palette.line).frame(height: DS.hairline)
            }
            optionRow(
                "Fetch logos after import",
                "Obolo connects once to each service's website.",
                isOn: $fetchLogosAfterImport
            )
        }
        .padding(.horizontal, 18)
        .importCard()
    }

    /// "Mobile is new; the other rows match your categories."
    private func newCategoriesDescription(_ names: [String], selectedCount: Int) -> String {
        let list = ListFormatter.localizedString(byJoining: names)
        let verb = names.count == 1 ? "is" : "are"
        let rest = selectedCount > names.count ? "; the other rows match your categories." : "."
        return "\(list) \(verb) new\(rest)"
    }

    private func optionRow(_ title: String, _ description: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                    .foregroundStyle(DS.Palette.ink)
                Text(description)
                    .font(DSFonts.font(DSFonts.sansRegular, size: 12))
                    .foregroundStyle(DS.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .dsSwitch()
                .controlSize(.small)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    private var note: some View {
        var parts: [String] = []
        if !preview.unmatchedColumns.isEmpty {
            let noun = preview.unmatchedColumns.count == 1 ? "Ignored column" : "Ignored columns"
            parts.append("\(noun): \(preview.unmatchedColumns.joined(separator: ", ")).")
        }
        parts.append("Rows are matched to your categories by name.")
        return Text(parts.joined(separator: " "))
            .font(DSFonts.font(DSFonts.sansRegular, size: 12))
            .foregroundStyle(DS.Palette.inkDisabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }

    // MARK: - Import

    private func importSelected(_ selected: Set<Int>) {
        guard model.activeSheet?.id == sheetID, !selected.isEmpty else { return }
        _ = model.importCSV(preview.keeping(selected), createMissingCategories: createMissingCategories)
        // Detached from this view on purpose: the sheet is closing, and the pass reports
        // its progress through the model.
        if fetchLogosAfterImport {
            Task { await model.fetchMissingLogos() }
        }
        close()
    }

    private func close() {
        model.dismissSheet(sheetID)
    }
}

/// Index the static row details once, then maintain the footer and category option as boxes change.
@MainActor @Observable
final class ImportPreviewSelection {
    struct RowDetails {
        let isImportable: Bool
        let knownSubscription: Subscription?
        let monthly: Decimal?
        let newCategoryKey: String?
    }

    let detailsByLine: [Int: RowDetails]
    let checkCount: Int
    let errorCount: Int

    private let selectableLines: [Int]
    private let newCategoryNames: [String]
    private let existingCategoryHues: [String: CategoryHue]
    private let newCategoryHues: [String: CategoryHue]
    private let fallbackHue: CategoryHue

    private(set) var selected: Set<Int>
    private(set) var selectedMonthly: Decimal = 0
    private(set) var selectedNewCategories: [String] = []

    var hasSelectableRows: Bool { !selectableLines.isEmpty }
    var allSelected: Bool { hasSelectableRows && selected.count == selectableLines.count }

    init(preview: ImportPreview, document: StoreDocument, selected: Set<Int>? = nil) {
        newCategoryNames = preview.newCategoryNames
        let existingByID = Dictionary(document.subscriptions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let existingByName = Dictionary(document.subscriptions.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let newCategories = Set(preview.newCategoryNames.map { $0.lowercased() })

        var detailsByLine: [Int: RowDetails] = [:]
        var selectableLines: [Int] = []
        var selectedLines: Set<Int> = []
        var checkCount = 0
        var errorCount = 0
        for row in preview.rows {
            let line = row.lineNumber
            let severity = row.severity
            if severity == .error { errorCount += 1 }
            guard let subscription = row.subscription else { continue }
            let known = existingByID[subscription.id] ?? existingByName[subscription.name.lowercased()]
            let monthly = Normalizer.monthlyInBase(
                price: subscription.price,
                currency: subscription.currency,
                cycle: subscription.cycle,
                rates: document.rates
            )
            let categoryKey = row.categoryName.lowercased()
            detailsByLine[line] = RowDetails(
                isImportable: severity != .error,
                knownSubscription: known,
                monthly: monthly,
                newCategoryKey: newCategories.contains(categoryKey) ? categoryKey : nil
            )
            guard severity != .error else { continue }
            selectableLines.append(line)
            if known != nil || subscription.anchorDate == nil || severity == .warning { checkCount += 1 }
            if selected?.contains(line) ?? (known == nil) { selectedLines.insert(line) }
        }
        self.detailsByLine = detailsByLine
        self.checkCount = checkCount
        self.errorCount = errorCount
        self.selectableLines = selectableLines
        self.selected = selectedLines
        existingCategoryHues = Dictionary(document.categories.map {
            ($0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), $0.tint)
        }, uniquingKeysWith: { first, _ in first })
        newCategoryHues = Dictionary(preview.newCategoryNames.enumerated().map { index, name in
            (name.folding(options: .caseInsensitive, locale: nil), CategoryHue.roundRobin(document.categories.count + index))
        }, uniquingKeysWith: { first, _ in first })
        fallbackHue = CategoryHue.roundRobin(document.categories.count)
        rebuildSummary()
    }

    func selectAll(_ on: Bool) {
        selected = on ? Set(selectableLines) : []
        rebuildSummary()
    }

    func setSelected(_ line: Int, to on: Bool) {
        guard detailsByLine[line]?.isImportable == true, selected.contains(line) != on else { return }
        if on { selected.insert(line) } else { selected.remove(line) }
        rebuildSummary()
    }

    func isNewCategory(_ name: String) -> Bool {
        newCategoryHues[name.folding(options: .caseInsensitive, locale: nil)] != nil
    }

    func categoryHue(for name: String) -> CategoryHue {
        let displayName = name.isEmpty ? OboloCore.Category.fallbackName : name
        let existingKey = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return existingCategoryHues[existingKey]
            ?? newCategoryHues[name.folding(options: .caseInsensitive, locale: nil)]
            ?? fallbackHue
    }

    private func rebuildSummary() {
        var total: Decimal = 0
        var usedCategories: Set<String> = []
        for line in selectableLines where selected.contains(line) {
            guard let details = detailsByLine[line] else { continue }
            total += details.monthly ?? 0
            if let category = details.newCategoryKey { usedCategories.insert(category) }
        }
        selectedMonthly = total
        selectedNewCategories = newCategoryNames.filter { usedCategories.contains($0.lowercased()) }
    }
}

private extension View {
    /// A card in the sheet: `bg200`, 1pt `line`, 18pt corners (`DS.panelShape`).
    func importCard() -> some View {
        dsCard(border: DS.hairline)
    }
}
