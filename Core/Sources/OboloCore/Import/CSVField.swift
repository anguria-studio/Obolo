import Foundation

/// The columns an import understands, and every header spelling that maps onto them.
///
/// Two files have to work: the Google Sheets export the user already keeps (headers
/// like `Cost` and `A payment date (past or future)`) and this app's own export
/// (`Price`, `First payment`, plus the fields a spreadsheet has no column for). Matching
/// is case-insensitive and whitespace-collapsed, so `BILLING CYCLE` and
/// `Billing  cycle` both land.
public enum CSVField: String, CaseIterable, Hashable, Sendable {
    case id
    case name
    case category
    case price
    case currency
    case priceHistory
    case currentPriceSince
    case cycle
    case anchorDate
    case active
    case status
    case billingStoppedOn
    case endsOn
    case isEstimate
    case reminderLeadDays
    case paymentMethod
    case manageURL
    case website
    case tint
    case icon
    case notes
    case createdAt

    /// The header this app writes. Round-tripping its own export is the baseline the
    /// importer is tested against.
    public var exportHeader: String {
        switch self {
        case .id: "ID"
        case .name: "Name"
        case .category: "Category"
        case .price: "Price"
        case .currency: "Currency"
        case .priceHistory: "Price history"
        case .currentPriceSince: "Current price since"
        case .cycle: "Billing cycle"
        // The column holds the date every other date is calculated from, which is the
        // first payment far more often than it is the next one. Older exports spelled it
        // "Anchor date" and still import: the alias list below keeps them readable.
        case .anchorDate: "First payment"
        case .active: "Active"
        case .status: "Status"
        case .billingStoppedOn: "Billing stopped on"
        case .endsOn: "Ends on"
        case .isEstimate: "Is estimate"
        case .reminderLeadDays: "Reminder lead days"
        case .paymentMethod: "Payment method"
        case .manageURL: "Manage URL"
        case .website: "Website"
        case .tint: "Tint"
        case .icon: "Icon"
        case .notes: "Notes"
        case .createdAt: "Created at"
        }
    }

    /// Everything accepted on the way in, normalised. `exportHeader` is always included.
    public var aliases: [String] {
        let extra: [String] = switch self {
        case .id: ["identifier", "uuid"]
        case .name: ["subscription", "service"]
        case .category: []
        case .price: ["cost", "amount"]
        case .currency: ["ccy", "currency code"]
        case .priceHistory: ["price changes", "earlier prices", "old prices"]
        case .currentPriceSince: ["price since", "current price from"]
        case .cycle: ["cycle", "billing", "billing period", "frequency", "period"]
        case .anchorDate:
            ["a payment date (past or future)", "a payment date", "renews on", "next payment",
             "anchor date", "first payment date", "payment date", "renewal date", "date"]
        case .active: []
        case .status: []
        case .billingStoppedOn: ["billing stopped", "stopped billing", "cancelled on", "paused on"]
        case .endsOn: ["end date", "ends", "access ends"]
        case .isEstimate: ["estimate", "estimated", "price is an estimate"]
        case .reminderLeadDays: ["reminder", "reminder days", "lead days"]
        case .paymentMethod: ["payment", "paid with", "method"]
        // `url`, `link` and `website` all name the service rather than the cancellation
        // page — the user's own sheet spells that column "Website" — so they belong to
        // `.website`. Only the app's own "Manage URL" and the two explicit spellings of
        // it land here.
        case .manageURL: ["manage link", "manage page", "manage"]
        case .website: ["domain", "url", "link", "site", "web"]
        case .tint: ["colour", "color"]
        case .icon: []
        case .notes: ["note", "comment", "comments"]
        case .createdAt: ["created", "added", "added on"]
        }
        return ([exportHeader] + extra).map(CSVField.normalize)
    }

    /// Lowercased, trimmed, internal whitespace collapsed to single spaces.
    public static func normalize(_ header: String) -> String {
        header
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The field a header names, or `nil` if nothing claims it.
    public static func matching(header: String) -> CSVField? {
        let normalised = normalize(header)
        guard !normalised.isEmpty else { return nil }
        return CSVField.allCases.first { $0.aliases.contains(normalised) }
    }

    /// The header row this app writes, in order.
    public static let exportOrder: [CSVField] = [
        .id, .name, .category, .price, .currency, .priceHistory, .currentPriceSince,
        .cycle, .anchorDate, .status, .active,
        .billingStoppedOn, .endsOn, .isEstimate, .reminderLeadDays, .paymentMethod, .manageURL, .website,
        .tint, .icon, .notes, .createdAt
    ]
}
