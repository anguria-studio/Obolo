import Foundation

/// Reading numbers and dates out of cells a human typed.
///
/// The import path cannot assume the file came from this app: the reference file is a
/// Google Sheets export made on an Italian Mac by someone who sometimes writes `€14,99`
/// and sometimes `14.99`. Both parsers below are deliberately tolerant, and both return
/// `nil` rather than a plausible-looking wrong answer.
public enum ValueParsing {

    // MARK: - Money

    /// "14.99" · "€14,99" · "1,234.56" · "1.234,56" · "$ 24.40" · "" → `nil`.
    ///
    /// When both `.` and `,` are present, the last one is the decimal point. With three
    /// trailing digits, a single separator normally groups thousands. Currencies such as
    /// KWD support three decimal places, so their prices use the locale to break the tie.
    public static func decimal(
        _ text: String,
        currency: String? = nil,
        locale: Locale = .current
    ) -> Decimal? {
        var cleaned = ""
        for character in text {
            if let digit = character.wholeNumberValue, (0...9).contains(digit) {
                cleaned += String(digit)
            } else if character == "." || character == "," || character == "-" {
                cleaned.append(character)
            } else if String(character) == locale.decimalSeparator {
                cleaned.append(".")
            }
        }
        guard cleaned.contains(where: \.isNumber), !cleaned.dropFirst().contains("-") else { return nil }

        if let index = cleaned.lastIndex(where: { $0 == "." || $0 == "," }) {
            let separator = cleaned[index]
            let whole = cleaned[..<index].filter { $0 != "." && $0 != "," }
            let fraction = cleaned[cleaned.index(after: index)...]
            let usesBothSeparators = cleaned.contains(".") && cleaned.contains(",")

            if !usesBothSeparators, fraction.count == 3, whole.contains(where: \.isNumber),
               isGrouping(separator, in: cleaned[..<index], currency: currency, locale: locale) {
                cleaned = whole + fraction
            } else {
                cleaned = whole + "." + fraction
            }
        }

        // A stray leading separator ("-.5" is fine, ".5" is fine, ",5" became ".5").
        if cleaned.hasPrefix(".") { cleaned = "0" + cleaned }
        if cleaned.hasPrefix("-.") { cleaned = "-0" + cleaned.dropFirst() }

        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isGrouping(
        _ separator: Character,
        in whole: Substring,
        currency: String?,
        locale: Locale
    ) -> Bool {
        guard let currency, MoneyFormatting.fractionDigits(of: currency) >= 3 else { return true }
        if whole.contains(separator) { return true }
        let digits = whole.filter(\.isNumber)
        return String(separator) == locale.groupingSeparator
            && (1...3).contains(digits.count) && digits.first != "0"
    }

    // MARK: - Dates

    /// ISO `yyyy-MM-dd` first, then the Mac's own short and medium styles, then a few
    /// unambiguous fallbacks. The result is always the **start of that day** in the
    /// injected calendar's time zone, so day arithmetic later cannot be off by one.
    public static func date(_ text: String, calendar: Calendar, locale: Locale = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A string written as a day settles it here, either way. Handing an ISO shape
        // the calendar rejected to the formatters below would undo the check: they read
        // a hyphen as `yyyy/MM/dd`'s separator and roll 31 February forward into March.
        if ISODay.isDayShaped(trimmed) { return ISODay.parse(trimmed, calendar: calendar) }

        // The locale's own styles: what a Mac writes when a user types a date.
        for style in [DateFormatter.Style.short, .medium, .long] {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.dateStyle = style
            formatter.timeStyle = .none
            if let parsed = formatter.date(from: trimmed) {
                return calendar.startOfDay(for: parsed)
            }
        }

        // Explicit patterns, in decreasing order of how unambiguous they are.
        for pattern in ["yyyy/MM/dd", "yyyy.MM.dd", "d MMM yyyy", "d MMMM yyyy", "MMM d, yyyy", "dd-MM-yyyy", "dd/MM/yyyy"] {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.dateFormat = pattern
            if let parsed = formatter.date(from: trimmed) {
                return calendar.startOfDay(for: parsed)
            }
        }

        // Last resort: a full ISO-8601 timestamp, as written by this app's own export.
        return isoTimestamp(trimmed)
    }

    static func billingDay(_ text: String, calendar: Calendar, locale: Locale) -> BillingDay? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ISODay.isDayShaped(trimmed) { return BillingDay(isoDate: trimmed) }
        // A timestamp supplied for a billing field carries the day in its own offset.
        if trimmed.dropFirst(10).first == "T", isoTimestamp(trimmed) != nil {
            return BillingDay(isoDate: String(trimmed.prefix(10)))
        }
        return date(trimmed, calendar: calendar, locale: locale).map { BillingDay($0, calendar: calendar) }
    }

    private static func isoTimestamp(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let parsed = iso.date(from: text) { return parsed }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text)
    }

    // MARK: - Price history

    /// Reads `2023-01-20=10.00 EUR;2024-01-20=15.00 USD` in file order.
    /// `Subscription` then sorts the entries. The older form without a currency uses
    /// the subscription currency.
    ///
    /// Every entry is read on its own: one unreadable pair loses that pair and is
    /// reported, rather than losing the history or refusing the row. That is the same
    /// rule the importer applies to a row inside a file.
    public static func priceHistory(
        _ text: String,
        currency: String,
        calendar: Calendar,
        locale: Locale = .current
    ) -> (changes: [PriceChange], unreadable: Bool) {
        var changes: [PriceChange] = []
        var unreadable = false

        for entry in text.split(separator: ";") {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            let priceAndCurrency = parts.count == 2
                ? parseHistoricalPrice(String(parts[1]), defaultCurrency: currency, locale: locale)
                : nil
            guard parts.count == 2,
                  let date = billingDay(String(parts[0]), calendar: calendar, locale: locale),
                  let priceAndCurrency,
                  priceAndCurrency.price >= 0
            else {
                unreadable = true
                continue
            }
            changes.append(
                PriceChange(
                    effectiveFrom: date,
                    price: priceAndCurrency.price,
                    currency: priceAndCurrency.currency
                )
            )
        }
        return (changes, unreadable)
    }

    private static func parseHistoricalPrice(
        _ text: String,
        defaultCurrency: String,
        locale: Locale
    ) -> (price: Decimal, currency: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        var currency = Subscription.normalizedCurrency(defaultCurrency)

        if let last = fields.last {
            let code = Subscription.normalizedCurrency(last)
            if code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) {
                currency = code
                fields.removeLast()
            }
        }

        guard currency.count == 3,
              let price = decimal(fields.joined(separator: " "), currency: currency, locale: locale)
        else { return nil }
        return (price, currency)
    }

    // MARK: - Booleans

    /// "Yes" · "true" · "1" · "y" — and their opposites.
    public static func boolean(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "y", "true", "1", "on": true
        case "no", "n", "false", "0", "off": false
        default: nil
        }
    }
}

/// The one reader of a `yyyy-MM-dd` day in the package: CSV import and the exchange
/// rate feed both come through here.
///
/// Built from components rather than through a `DateFormatter`, so the day cannot pick
/// up a time zone from anywhere but the calendar it was given, and **checked by reading
/// the result back**. That check is the whole point: `Calendar` answers a request for
/// 31 February with 3 March rather than with nothing, so a date that survives the
/// arithmetic is not proof that it was ever written down. A day that does not read back
/// as the digits that were typed did not exist, and `nil` is the honest answer.
public enum ISODay {

    /// `"2026-08-24"` → the start of that day in `calendar`. `nil` for anything that is
    /// not four digits, two digits, two digits — or that names a day the calendar does
    /// not have.
    public static func parse(_ text: String, calendar: Calendar) -> Date? {
        guard let (year, month, day) = fields(of: text),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let built = calendar.date(from: components) else { return nil }
        let start = calendar.startOfDay(for: built)

        // 2026-02-31 lands on 3 March, 2026-13-01 on January 2027: both arrive here as
        // a perfectly good `Date` for a day nobody typed.
        let readBack = calendar.dateComponents([.year, .month, .day], from: start)
        guard readBack.year == year, readBack.month == month, readBack.day == day else { return nil }
        return start
    }

    /// Whether `text` is written as a day: three numbers, four digits and then at most
    /// two and two. It says nothing about whether that day exists — `parse` decides
    /// that — only that no other reading of the string is worth trying.
    static func isDayShaped(_ text: String) -> Bool {
        fields(of: text) != nil
    }

    /// The three numbers, or `nil` when the string is not in that shape at all.
    private static func fields(of text: String) -> (year: Int, month: Int, day: Int)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts[0].count == 4, parts[1].count <= 2, parts[2].count <= 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return (year, month, day)
    }
}
