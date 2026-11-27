import Foundation

/// Writes every field, so that export → import is lossless.
///
/// Dates go out as ISO `yyyy-MM-dd` (and a full ISO-8601 timestamp for `createdAt`)
/// rather than in the user's locale: this file is both a backup and something the user
/// may paste back into a spreadsheet, and `03/04/2027` means two different days
/// depending on who opens it.
///
/// `Active` is written alongside `Status` even though it is redundant, because the
/// user's Google Sheet has that column and re-importing there should keep working.
public enum CSVExporter {

    public static func csv(_ document: StoreDocument) -> String {
        let header = CSVField.exportOrder.map(\.exportHeader)
        let categories = Dictionary(document.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let rows = document.subscriptions.map { subscription in
            CSVField.exportOrder.map { field in
                CSVParser.spreadsheetSafe(
                    cell(
                        field,
                        of: subscription,
                        categoryName: categories[subscription.categoryID] ?? Category.fallbackName
                    )
                )
            }
        }
        return CSVParser.serialize([header] + rows)
    }

    public static func export(_ document: StoreDocument) -> Data {
        Data(csv(document).utf8)
    }

    private static func cell(_ field: CSVField, of subscription: Subscription, categoryName: String) -> String {
        switch field {
        case .id: subscription.id.uuidString
        case .name: subscription.name
        case .category: categoryName
        case .price: price(subscription.price)
        case .currency: subscription.currency
        case .priceHistory: history(subscription)
        case .currentPriceSince: subscription.currentPriceSince?.isoDate ?? ""
        case .cycle: subscription.cycle.encoded
        case .anchorDate: subscription.anchorDate?.isoDate ?? ""
        // A paused row exports as cancelled, as it imports.
        case .status: (subscription.status == .paused ? Status.cancelled : subscription.status).rawValue
        case .active: subscription.status.isBilling ? "Yes" : "No"
        case .billingStoppedOn:
            subscription.billingStoppedOn?.isoDate ?? ""
        case .endsOn: subscription.endsOn?.isoDate ?? ""
        case .isEstimate: subscription.isEstimate ? "Yes" : "No"
        case .reminderLeadDays: subscription.reminderLeadDays.map(String.init) ?? ""
        case .paymentMethod: subscription.paymentMethod
        case .manageURL: subscription.manageURL?.absoluteString ?? ""
        case .website: subscription.website ?? ""
        case .tint: subscription.tint.rawValue
        case .icon: subscription.icon.encoded
        case .notes: subscription.notes
        case .createdAt: timestamp(subscription.createdAt)
        }
    }

    /// `2023-01-20=10.00 EUR;2024-01-20=15.00 USD` — one cell for the whole price
    /// history, ISO days and plain figures, oldest first.
    ///
    /// One cell rather than a column per change, because the number of changes is not
    /// fixed and a spreadsheet with a ragged right edge is not a spreadsheet. It stays
    /// readable by eye, which is what a backup has to be.
    private static func history(_ subscription: Subscription) -> String {
        subscription.priceChanges
            .map {
                $0.effectiveFrom.isoDate
                    + "=" + price($0.price) + " " + $0.currency
            }
            .joined(separator: ";")
    }

    /// At least two decimal places, a period, and no grouping in any locale. A fourth
    /// digit disambiguates a three-place price from a grouped integer on re-import.
    private static func price(_ value: Decimal) -> String {
        let fractionDigits = max(0, -value.exponent)
        let minimum = fractionDigits == 3 ? 4 : 2
        return value.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never)
                .precision(.fractionLength(minimum...max(minimum, fractionDigits)))
        )
    }

    /// Full ISO-8601 with the offset — `createdAt` is an instant, not a day.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
