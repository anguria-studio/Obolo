import SwiftUI
import OboloCore

/// An amount that is never cut with an ellipsis: in full when it fits, in whole units
/// when it does not ("1.245.722 €"), and as a last resort in whole units set smaller.
///
/// Seven- and eight-digit amounts are ordinary with a base currency such as yen, won,
/// rupiah or dong, so a figure with a fixed share of the width needs somewhere to go.
/// Style it from outside, as a `Text`.
struct FittingAmount: View {
    let value: Decimal
    let currency: String
    /// Written before the amount in every form: Vs avg's "+" or "−".
    var prefix = ""

    var body: some View {
        let compact = prefix + MoneyFormatting.compact(value, currency: currency)
        ViewThatFits(in: .horizontal) {
            Text(prefix + MoneyFormatting.amount(value, currency: currency))
            Text(compact)
            Text(compact).minimumScaleFactor(0.5)
        }
        .lineLimit(1)
    }

    /// The narrowest a row's name gets beside an amount that has the priority: room for
    /// a short name ("Software") whole, so a long amount drops its decimals before it
    /// takes all of the row.
    static let nameMinimumWidth: CGFloat = 72
}

/// Reports `minimumScale` of its content's width as its ideal width, so a
/// `ViewThatFits` takes the layout it sits in once the content fits at that scale; given
/// a width, it takes that much, between that floor and the content's own width. For a
/// `Text` with the same `minimumScaleFactor`, which shrinks to the width it is given.
struct ShrinkableWidth: Layout {
    let minimumScale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(.unspecified)
        let floor = natural.width * minimumScale
        let width = proposal.width.map { min(max($0, floor), natural.width) } ?? floor
        let size = content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    /// The content's own baselines, so a shrunk hero stays on the line it sits on.
    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        guard let content = subviews.first else { return nil }
        return bounds.minY + content.dimensions(in: ProposedViewSize(bounds.size))[guide]
    }
}
