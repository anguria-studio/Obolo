import Foundation
import Testing

/// Home's shares never read "0%" for something that costs money: a share above zero
/// that rounds to nothing reads "<1%".
@Suite("Share percent")
struct SharePercentTests {

    private static let locale = Locale(identifier: "en_US")

    private static func text(_ share: Double, spoken: Bool = false) -> String {
        SharePercent.text(share, spoken: spoken, locale: locale)
    }

    @Test("Only a true zero reads 0%")
    func zero() {
        #expect(Self.text(0) == "0%")
        #expect(Self.text(0, spoken: true) == "0%")
    }

    @Test("A share above zero that rounds to 0% reads <1%")
    func belowOnePercent() {
        #expect(Self.text(0.000_000_1) == "<1%")
        #expect(Self.text(0.004) == "<1%")
        // Half a percent rounds to even, so to 0%: it still costs something.
        #expect(Self.text(0.005) == "<1%")
        #expect(Self.text(0.004, spoken: true) == "less than 1%")
    }

    @Test("From 1% up, whole percents as before")
    func wholePercents() {
        #expect(Self.text(0.0149) == "1%")
        #expect(Self.text(0.5) == "50%")
        #expect(Self.text(0.999) == "100%")
        #expect(Self.text(1) == "100%")
        #expect(Self.text(0.5, spoken: true) == "50%")
    }

    @Test("The locale still writes the percent")
    func locale() {
        let french = Locale(identifier: "fr_FR")
        #expect(SharePercent.text(0.004, locale: french) == "<" + 0.01.formatted(.percent.precision(.fractionLength(0)).locale(french)))
        #expect(SharePercent.text(0.5, locale: french) == 0.5.formatted(.percent.precision(.fractionLength(0)).locale(french)))
    }
}
