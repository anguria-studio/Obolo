import AppKit
import SwiftUI
import OboloCore

/// The square in front of a subscription's name: its logo, or the letter that stands in
/// for one.
///
/// Four vocabularies, one diameter, so the All list's name column stays aligned whatever a row
/// chose: a fetched or dropped image, an emoji, an SF Symbol, or the first letter of the
/// name on a tinted square. 22pt unless a caller asks for another size; the glyph is
/// half the width of the square.
///
/// `.image` names a file in `LogoStore`, and a file that is missing — a document
/// restored onto a Mac that never fetched anything — falls back to the letter rather
/// than to a hole. That fallback is why every case still draws.
struct IconInitial: View {
    let subscription: Subscription
    var size: CGFloat = Token.Size.initialSmall

    var body: some View {
        ZStack {
            SubscriptionIcon.shape(size: size).fill(backing)
            glyph
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The logo on screen: the stored file this icon names, if it is there.
    private var image: NSImage? {
        guard case .image(let filename) = subscription.icon else { return nil }
        return LogoStore.shared.image(named: filename)
    }

    /// A logo sits on white rather than on the tint, the way a favicon does in a browser
    /// — most are opaque and cover it entirely, and the ones with transparency are
    /// almost always dark artwork that would disappear into a saturated circle.
    private var backing: Color {
        image == nil ? Token.color(subscription.tint) : .white
    }

    @ViewBuilder
    private var glyph: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                // Fills the square and is clipped by it: a wordmark that happens to be
                // wide loses its edges rather than floating in a letterbox.
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(SubscriptionIcon.shape(size: size))
        } else {
            switch subscription.icon {
            case .initial, .image, .letter:
                // `.image` lands here when the file is missing — see the note above.
                Text(Self.initial(of: subscription.name))
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Token.onTint(subscription.tint))
            case .emoji(let emoji):
                // Emoji carry their own colour, so the tinted circle behind them would
                // only muddy them: the fill drops to a wash and the glyph does the work.
                Text(emoji)
                    .font(.system(size: size * 0.55))
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(Token.onTint(subscription.tint))
            }
        }
    }

    /// The first *character* of the name, uppercased through the current locale —
    /// `İ` in Turkish, not `I`. Grapheme-wise, so a name that starts with an emoji or
    /// a combining mark yields one whole character rather than half of one.
    static func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "-" }
        return String(first).uppercased(with: .current)
    }
}
