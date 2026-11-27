import Foundation

/// Something worth telling the user about one row.
public struct ImportIssue: Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable, Comparable {
        /// The row imports, with a value filled in or left out.
        case warning
        /// The row cannot be imported and is skipped.
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .warning && rhs == .error
        }
    }

    public var severity: Severity
    /// The header the problem is in, when it belongs to one.
    public var column: String?
    public var message: String

    public init(severity: Severity, column: String? = nil, message: String) {
        self.severity = severity
        self.column = column
        self.message = message
    }

    public static func warning(_ message: String, column: String? = nil) -> ImportIssue {
        ImportIssue(severity: .warning, column: column, message: message)
    }

    public static func error(_ message: String, column: String? = nil) -> ImportIssue {
        ImportIssue(severity: .error, column: column, message: message)
    }
}

/// One parsed line, with whatever went wrong attached.
public struct ImportRow: Identifiable, Hashable, Sendable {
    /// 1-based line number in the file, header included — what the user sees in the
    /// preview table and what they would scroll to in the spreadsheet.
    public var lineNumber: Int
    /// `nil` only when the row has an error and cannot be built at all.
    public var subscription: Subscription?
    /// The category *name* from the file. The ID is resolved at `apply` time, because
    /// only then is it known whether missing categories may be created.
    public var categoryName: String
    public var issues: [ImportIssue]

    public var id: Int { lineNumber }

    public init(lineNumber: Int, subscription: Subscription?, categoryName: String, issues: [ImportIssue] = []) {
        self.lineNumber = lineNumber
        self.subscription = subscription
        self.categoryName = categoryName
        self.issues = issues
    }

    public var severity: ImportIssue.Severity? {
        issues.map(\.severity).max()
    }

    public var isImportable: Bool {
        subscription != nil && severity != .error
    }
}

/// What `CSVImporter.preview` hands the import sheet — enough to render the table, the
/// "create missing categories" toggle and the counts, without touching the document.
public struct ImportPreview: Hashable, Sendable {
    /// Headers as they appeared in the file.
    public var headers: [String]
    /// Headers nothing claimed, shown so the user knows what was dropped.
    public var unmatchedColumns: [String]
    public var rows: [ImportRow]
    /// Category names in the file that the document does not have yet, in file order.
    public var newCategoryNames: [String]
    /// What the rows came from, for the sheet's title: the file name ("subscriptions.csv"),
    /// or another source's own name. `nil` when there is nothing to name.
    public var sourceName: String?

    public init(
        headers: [String],
        unmatchedColumns: [String],
        rows: [ImportRow],
        newCategoryNames: [String],
        sourceName: String? = nil
    ) {
        self.headers = headers
        self.unmatchedColumns = unmatchedColumns
        self.rows = rows
        self.newCategoryNames = newCategoryNames
        self.sourceName = sourceName
    }

    /// The same preview with only `selected` rows (by line number), and only the new
    /// categories those rows use: what the sheet imports when some rows are unticked.
    public func keeping(_ selected: Set<Int>) -> ImportPreview {
        let kept = rows.filter { selected.contains($0.lineNumber) }
        let used = Set(kept.map { $0.categoryName.lowercased() })
        return ImportPreview(
            headers: headers,
            unmatchedColumns: unmatchedColumns,
            rows: kept,
            newCategoryNames: newCategoryNames.filter { used.contains($0.lowercased()) },
            sourceName: sourceName
        )
    }

    public var importableRows: [ImportRow] { rows.filter(\.isImportable) }
    public var importableCount: Int { importableRows.count }
    public var errorCount: Int { rows.count { $0.severity == .error } }
    public var isEmpty: Bool { rows.isEmpty }
}

/// What actually happened when the preview was applied.
public struct ImportResult: Hashable, Sendable {
    public var inserted: Int
    public var updated: Int
    /// Rows with an error, or rows whose category could not be created.
    public var skipped: Int
    public var createdCategories: [Category]

    public init(inserted: Int = 0, updated: Int = 0, skipped: Int = 0, createdCategories: [Category] = []) {
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.createdCategories = createdCategories
    }

    public var total: Int { inserted + updated }

    /// "Imported 10 subscriptions (1 updated), 1 skipped."
    public var summary: String {
        var parts = ["Obolo imported \(total) subscription\(total == 1 ? "" : "s")"]
        if updated > 0 { parts.append("\(updated) updated") }
        if !createdCategories.isEmpty { parts.append("\(createdCategories.count) new categor\(createdCategories.count == 1 ? "y" : "ies")") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: ", ") + "."
    }
}

/// File-level failures that stop an import before it starts.
public enum CSVImportError: Error, Hashable, Sendable, LocalizedError {
    case empty
    case noNameColumn(headers: [String])
    case noBillingColumn

    public var errorDescription: String? {
        switch self {
        case .empty:
            "That file has no rows."
        case .noNameColumn(let headers):
            headers.isEmpty
                ? "That file has no header row."
                : "The file has no “Name” column. The file has these columns: \(headers.joined(separator: ", "))."
        case .noBillingColumn:
            "Choose a subscription CSV with a “Price” or “Billing cycle” column."
        }
    }
}
