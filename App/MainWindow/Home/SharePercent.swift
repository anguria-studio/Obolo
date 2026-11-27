import Foundation

/// A share of a total as a whole percent, for Home's lists: "57%".
///
/// A share above zero that rounds to 0% reads "<1%" (spoken "less than 1%"), so a
/// category or a subscription that costs something never reads "0%" next to one that
/// takes nearly all of the total. A true zero still reads "0%".
enum SharePercent {
    /// The visible text, or with `spoken` the words for VoiceOver.
    static func text(_ share: Double, spoken: Bool = false, locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0)).locale(locale)
        let text = share.formatted(style)
        // Whatever the locale's rounding gives, "0%" is only for nothing at all.
        guard share > 0, text == 0.0.formatted(style) else { return text }
        let one = 0.01.formatted(style)
        return spoken ? "less than \(one)" : "<\(one)"
    }
}
