import Foundation

/// Turns a CSV into subscriptions, in two steps so the user can look before it lands.
///
/// `preview` is pure: it reads the file, matches the headers, parses every row and
/// records what it could not make sense of, without touching the document. `apply` then
/// writes the rows the user accepted. Splitting it that way is what makes the import
/// sheet possible — and what makes "row-level errors never abort the import" true by
/// construction rather than by care.
public enum CSVImporter {

    // MARK: - Preview

    /// Parses `data` against `document`, which supplies the base currency for rows with
    /// no currency column and the existing categories for name matching.
    ///
    /// Requires a name column and at least one price or billing cycle column.
    /// Throws if the required columns or the data rows are missing.
    /// Issues with individual cells are reported per row.
    public static func preview(
        data: Data,
        document: StoreDocument,
        calendar: Calendar = .current,
        locale: Locale = .current,
        now: Date = Date()
    ) throws -> ImportPreview {
        var records = CSVParser.rows(data)
        guard let headerRow = records.next() else { throw CSVImportError.empty }

        var columns: [CSVField: Int] = [:]
        var unmatched: [String] = []
        for (index, header) in headerRow.enumerated() {
            guard let field = CSVField.matching(header: header) else {
                if !header.isEmpty { unmatched.append(header) }
                continue
            }
            // First column to claim a field wins; a duplicate is reported as unmatched
            // so the user can see it was ignored rather than silently overriding.
            if columns[field] == nil { columns[field] = index } else { unmatched.append(header) }
        }
        guard columns[.name] != nil else { throw CSVImportError.noNameColumn(headers: headerRow) }

        guard columns[.price] != nil || columns[.cycle] != nil else {
            throw CSVImportError.noBillingColumn
        }

        var rows: [ImportRow] = []
        var newCategoryNames: [String] = []
        for (offset, fields) in records.enumerated() {
            let row = parse(
                fields: fields,
                columns: columns,
                headers: headerRow,
                lineNumber: offset + 2,
                document: document,
                calendar: calendar,
                locale: locale,
                now: now
            )
            if row.isImportable,
               !row.categoryName.isEmpty,
               document.category(named: row.categoryName) == nil,
               !newCategoryNames.contains(where: { $0.compare(row.categoryName, options: .caseInsensitive) == .orderedSame }) {
                newCategoryNames.append(row.categoryName)
            }
            rows.append(row)
        }
        guard !rows.isEmpty else { throw CSVImportError.empty }

        return ImportPreview(
            headers: headerRow,
            unmatchedColumns: unmatched,
            rows: rows,
            newCategoryNames: newCategoryNames
        )
    }

    // MARK: - One row

    private static func parse(
        fields: [String],
        columns: [CSVField: Int],
        headers: [String],
        lineNumber: Int,
        document: StoreDocument,
        calendar: Calendar,
        locale: Locale,
        now: Date
    ) -> ImportRow {
        func value(_ field: CSVField) -> String? {
            guard let index = columns[field], index < fields.count else { return nil }
            let text = CSVParser.spreadsheetValue(fields[index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        func header(_ field: CSVField) -> String? {
            columns[field].flatMap { $0 < headers.count ? headers[$0] : nil }
        }

        var issues: [ImportIssue] = []
        let categoryName = value(.category) ?? Category.fallbackName

        guard let name = value(.name) else {
            issues.append(.error("The row has no name. Obolo skipped it.", column: header(.name)))
            return ImportRow(lineNumber: lineNumber, subscription: nil, categoryName: categoryName, issues: issues)
        }

        let currency: String
        if let raw = value(.currency) {
            let normalised = Subscription.normalizedCurrency(raw)
            if normalised.count == 3 {
                currency = normalised
            } else {
                currency = document.settings.baseCurrency
                issues.append(.warning("“\(raw)” is not a currency code. Obolo used \(currency).", column: header(.currency)))
            }
        } else {
            currency = document.settings.baseCurrency
        }

        // Price. A blank cell imports as 0 with a warning, so it can be fixed in place.
        var price: Decimal = 0
        if let raw = value(.price) {
            if let parsed = ValueParsing.decimal(raw, currency: currency, locale: locale), parsed >= 0 {
                price = parsed
            } else {
                issues.append(.error("Obolo cannot read the price “\(raw)”.", column: header(.price)))
                return ImportRow(lineNumber: lineNumber, subscription: nil, categoryName: categoryName, issues: issues)
            }
        } else if columns[.price] != nil {
            issues.append(.warning("The row has no price. Obolo imported 0.", column: header(.price)))
        }

        // Both price-history columns are optional, and a file without them describes a
        // subscription that has always cost what it costs now.
        var priceChanges: [PriceChange] = []
        if let raw = value(.priceHistory) {
            let parsed = ValueParsing.priceHistory(raw, currency: currency, calendar: calendar, locale: locale)
            priceChanges = parsed.changes
            if parsed.unreadable {
                issues.append(.warning(
                    "Obolo cannot read part of the price history “\(raw)”. It imported the rest.",
                    column: header(.priceHistory)
                ))
            }
        }

        var currentPriceSince: BillingDay?
        if let raw = value(.currentPriceSince) {
            currentPriceSince = ValueParsing.billingDay(raw, calendar: calendar, locale: locale)
            if currentPriceSince == nil {
                issues.append(.warning(
                    "Obolo cannot read the date “\(raw)”. The current price applies from the first payment.",
                    column: header(.currentPriceSince)
                ))
            }
        }

        var cycle = BillingCycle.monthly
        if let raw = value(.cycle) {
            if let parsed = BillingCycle(parsing: raw) {
                cycle = parsed
            } else {
                issues.append(.error("Obolo cannot read the billing cycle “\(raw)”.", column: header(.cycle)))
                return ImportRow(lineNumber: lineNumber, subscription: nil, categoryName: categoryName, issues: issues)
            }
        }

        // A missing date is a supported state, not a problem — the undated row. It
        // shows "—" for Next and lands in Needs attention with a one-click fix.
        var anchorDate: BillingDay?
        if let raw = value(.anchorDate) {
            anchorDate = ValueParsing.billingDay(raw, calendar: calendar, locale: locale)
            if anchorDate == nil {
                issues.append(.warning("Obolo cannot read the date “\(raw)”. The imported subscription has no date.", column: header(.anchorDate)))
            }
        }

        // `Status` is the richer column, so it wins where both are present; `Active`
        // is the Google Sheet's only way of saying it.
        var status = Status.active
        if columns[.status] != nil {
            if let raw = value(.status), let parsed = Status(parsing: raw) {
                status = parsed
            } else {
                let raw = value(.status)
                let subject = raw.map { "the status “\($0)”" } ?? "the blank status"
                issues.append(.warning(
                    "Obolo cannot read \(subject). It used the Active column or set the status to Active.",
                    column: header(.status)
                ))
                if let active = value(.active), let parsed = Status(parsing: active) {
                    status = parsed
                }
            }
        } else if let raw = value(.active) {
            if let parsed = Status(parsing: raw) {
                status = parsed
            } else {
                issues.append(.warning("Obolo cannot read “\(raw)”. Obolo set the status to Active.", column: header(.active)))
            }
        }

        let today = BillingDay(now, calendar: calendar)
        var billingStoppedOn: BillingDay?
        if let raw = value(.billingStoppedOn) {
            if let stopped = ValueParsing.billingDay(raw, calendar: calendar, locale: locale) {
                if stopped <= today {
                    billingStoppedOn = stopped
                } else {
                    issues.append(.warning(
                        "The billing stop date “\(raw)” is after today. Obolo ignored it.",
                        column: header(.billingStoppedOn)
                    ))
                }
            } else {
                issues.append(.warning(
                    "Obolo cannot read the billing stop date “\(raw)”. The billing stop date is unknown.",
                    column: header(.billingStoppedOn)
                ))
            }
        }

        var endsOn = value(.endsOn).flatMap { ValueParsing.billingDay($0, calendar: calendar, locale: locale) }
        // A sheet that says "Active: No" with a date is describing when access stops —
        // the date column is the only place that information can live in that format.
        if endsOn == nil, status == .cancelled, columns[.status] == nil, let anchorDate {
            endsOn = anchorDate
        }

        // A file that never carried a stop date says nothing about when billing ended,
        // and today is not the answer: stamping it would hand the user years of charges
        // they never made. An end date that has already been reached is the one piece of
        // evidence the row does carry, and it is the same rule `AppModel.apply` uses for
        // a store file written before the column existed. Everything else stays unknown.
        if !status.isBilling,
           billingStoppedOn == nil,
           let ended = endsOn,
           ended <= today {
            billingStoppedOn = ended
        }

        let isEstimate = value(.isEstimate).flatMap(ValueParsing.boolean) ?? false
        let reminderLeadDays = value(.reminderLeadDays).flatMap { Int($0) }
        let tint = value(.tint).flatMap { Tint(rawValue: $0.lowercased()) }
        let icon = value(.icon).map { Icon(encoded: $0) } ?? .initial

        var manageURL: URL?
        if let raw = value(.manageURL) {
            manageURL = URL(string: raw)
            if manageURL?.scheme == nil {
                manageURL = URL(string: "https://" + raw)
            }
            if manageURL == nil {
                issues.append(.warning("Obolo cannot read the link “\(raw)”. The imported subscription has no link.", column: header(.manageURL)))
            }
        }

        // A cell that is a link rather than a bare domain is not a problem — the
        // normaliser takes `https://www.netflix.com/browse` down to `netflix.com` — but
        // a cell that is neither is worth saying so about, because the column was
        // probably mapped wrongly.
        var website: String?
        if let raw = value(.website) {
            website = Subscription.normalizedDomain(raw)
            if website == nil {
                issues.append(.warning("“\(raw)” is not a website. The imported subscription has no website.", column: header(.website)))
            }
        }

        let id = value(.id).flatMap(UUID.init(uuidString:)) ?? UUID()
        let createdAt = value(.createdAt).flatMap { ValueParsing.date($0, calendar: calendar, locale: locale) } ?? now

        let parsed = Subscription(
            id: id,
            name: name,
            icon: icon,
            // A tint is decoration; assigning one per row keeps an imported list from
            // being uniformly blue.
            tint: tint ?? Tint.roundRobin(lineNumber),
            categoryID: document.category(named: categoryName)?.id ?? document.fallbackCategoryID,
            price: price,
            currency: currency,
            priceChanges: priceChanges,
            currentPriceSince: currentPriceSince,
            cycle: cycle,
            anchorDate: anchorDate,
            status: status,
            billingStoppedOn: billingStoppedOn,
            endsOn: endsOn,
            isEstimate: isEstimate,
            reminderLeadDays: reminderLeadDays,
            paymentMethod: value(.paymentMethod) ?? "",
            manageURL: manageURL,
            website: website,
            notes: value(.notes) ?? "",
            createdAt: createdAt
        )

        // A price history entry dated after today is not history. Left in, it would sit
        // below every charge the row has already made and answer for all of them, so a
        // sheet with a typed year in it would rewrite a settled record. The row still
        // imports, without those entries, and the warning says how many went.
        let (subscription, droppedHistory) = parsed.droppingFutureHistory(after: .latestWorldwide(at: now))
        if droppedHistory > 0 {
            issues.append(.warning(
                droppedHistory == 1
                    ? "Obolo removed 1 price history entry dated after today."
                    : "Obolo removed \(droppedHistory) price history entries dated after today.",
                column: header(.priceHistory)
            ))
        }
        if subscription.currentPriceSince != parsed.currentPriceSince {
            issues.append(.warning(
                "Obolo cannot use a current price date after today. The current price applies from the first payment.",
                column: header(.currentPriceSince)
            ))
        }

        return ImportRow(lineNumber: lineNumber, subscription: subscription, categoryName: categoryName, issues: issues)
    }

    // MARK: - Apply

    /// Writes the importable rows into `document`.
    ///
    /// A row whose ID already exists updates that subscription in place, so re-importing
    /// an export is idempotent rather than duplicating the list. A row whose category is
    /// unknown either creates it (round-robin tint, appended at the end) or falls back to
    /// "Other" — never skipped, because a category is not worth losing a subscription
    /// over.
    @discardableResult
    public static func apply(
        _ preview: ImportPreview,
        to document: inout StoreDocument,
        createMissingCategories: Bool
    ) -> ImportResult {
        var result = ImportResult()
        // Keep the first match, as StoreDocument.upsert does, and index new rows as
        // they arrive so a repeated ID in this file updates the same subscription.
        var indexByID = Dictionary(
            document.subscriptions.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        for row in preview.rows {
            guard var subscription = row.subscription, row.isImportable else {
                result.skipped += 1
                continue
            }

            let categoryName = row.categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = document.categories.first(named: categoryName) {
                subscription.categoryID = existing.id
            } else if createMissingCategories, !categoryName.isEmpty {
                let category = Category(
                    name: categoryName,
                    tint: CategoryHue.roundRobin(document.categories.count),
                    sortOrder: (document.categories.map(\.sortOrder).max() ?? -1) + 1
                )
                document.categories.append(category)
                result.createdCategories.append(category)
                subscription.categoryID = category.id
            } else {
                subscription.categoryID = document.fallbackCategoryID
            }

            if let index = indexByID[subscription.id] {
                document.subscriptions[index] = subscription
                result.updated += 1
            } else {
                indexByID[subscription.id] = document.subscriptions.endIndex
                document.subscriptions.append(subscription)
                result.inserted += 1
            }
        }

        // Categories created above were appended past the end of the existing order;
        // re-sorting keeps `sortOrder` and array order in agreement, which the category
        // lists and the reorder handle both rely on.
        document.categories.sort { $0.sortOrder < $1.sortOrder }
        return result
    }
}
