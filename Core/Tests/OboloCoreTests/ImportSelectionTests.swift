import Foundation
import Testing
@testable import OboloCore

/// The import sheet's row checkboxes: only the ticked rows go in, and only
/// the new categories they use are created.
@Suite("Import selection")
struct ImportSelectionTests {
    private func row(_ line: Int, _ name: String, category: String) -> ImportRow {
        ImportRow(
            lineNumber: line,
            subscription: Subscription(
                name: name,
                categoryID: Category.fallbackID,
                price: 5,
                currency: "EUR",
                cycle: .monthly,
                anchorDate: Fixed.billingDay(2026, 5, 28)
            ),
            categoryName: category
        )
    }

    @Test("Keeping rows drops the others and the new categories only they used")
    func keepsSelectedRows() {
        let preview = ImportPreview(
            headers: ["Name", "Category"],
            unmatchedColumns: ["Card"],
            rows: [row(2, "Gym", category: "Fitness"), row(3, "eSIM", category: "Mobile"), row(4, "Paper", category: "News")],
            newCategoryNames: ["Mobile", "News"],
            sourceName: "subscriptions.csv"
        )
        let kept = preview.keeping([2, 3])
        #expect(kept.rows.map(\.lineNumber) == [2, 3])
        #expect(kept.newCategoryNames == ["Mobile"])
        #expect(kept.sourceName == "subscriptions.csv")
        #expect(kept.unmatchedColumns == ["Card"])
        #expect(preview.keeping([]).rows.isEmpty)
    }
}
