import SwiftUI
import OboloCore

/// A subscription's icon in the instrument style.
///
/// A subscription shows its logo, fetched from its website and cached by `LogoStore`.
/// Without a logo, the fallback is an orange Geist Mono initial on a `bg300` square
/// with a 1pt `line` border.
///
/// Calendar days with payments already use `bg300`, so their fallback tiles share
/// the day's "+N" chip fill of `bg400`.
///
/// Tile corners are about a quarter of the icon's size. In the calendar, readable
/// logo marks sit directly on the day cell.
///
/// Icons people picked before the rule (an emoji, an SF Symbol) keep drawing as they did
/// until the icon is changed, so no one's choice is lost. A cancelled subscription's icon
/// sits at 40%.
///
/// Lists and forms put the site's dark-mode icon on a dark square in Dark. Other logos
/// in those views sit on white.
///
/// Rendering only: nothing here fetches. `LogoStore` reads a cached file or answers nil.
struct SubscriptionIcon: View {
    let subscription: Subscription
    var size: CGFloat = 24
    var isCancelled = false
    /// The letter tile's fill, for a tile that sits on `bg300` (the Calendar's days).
    var fallbackFill: Color = DS.Palette.bg300
    var calendarCanvas: CalendarLogo.Canvas?
    /// A logo fetched in the form but not saved yet (its light and dark images), drawn in
    /// place of the stored one while the icon is in logo mode.
    var unsavedLogo: (logo: NSImage, dark: NSImage?)?

    @Environment(\.colorScheme) private var colorScheme

    /// The icon's outline: 22 → 5, 24 → 6, 28 → 7, 48 → 12, 52 → 12.
    static func shape(size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: min((size / 4).rounded(.down), 12), style: .continuous)
    }

    private var shape: RoundedRectangle { Self.shape(size: size) }

    var body: some View {
        content
            .frame(width: size, height: size)
            .opacity(isCancelled ? 0.4 : 1)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let unsavedLogo, subscription.icon == .initial || subscription.icon.imageFilename != nil {
            logo(unsavedLogo.logo, dark: unsavedLogo.dark)
        } else {
            stored
        }
    }

    @ViewBuilder
    private var stored: some View {
        switch subscription.icon {
        case .image(let filename):
            if let calendarCanvas {
                if let logo = LogoStore.shared.calendarLogo(named: filename, on: calendarCanvas) {
                    calendarLogo(logo)
                } else {
                    fallback
                }
            } else if let image = LogoStore.shared.image(named: filename) {
                logo(image, dark: LogoStore.shared.darkImage(for: filename))
            } else if colorScheme == .dark, let dark = LogoStore.shared.darkImage(for: filename) {
                logo(dark, dark: dark)
            } else {
                fallback
            }
        case .emoji, .symbol:
            // Chosen before the logo-or-letter rule: kept as the person chose it.
            IconInitial(subscription: subscription, size: size)
        case .initial:
            fallback
        case .letter(let color):
            // Picked on purpose: the colour, with the letter in accent-ink.
            Text(IconInitial.initial(of: subscription.name))
                .font(DSFonts.font(DSFonts.monoMedium, size: (size * 0.42).rounded()))
                .foregroundStyle(DS.Palette.accentInk)
                .frame(width: size, height: size)
                .background(shape.fill(DS.letterColor(color)))
        }
    }

    @ViewBuilder
    private func calendarLogo(_ logo: CalendarLogo) -> some View {
        let mark = Image(nsImage: logo.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
        switch logo.treatment {
        case .mark:
            mark.frame(width: size, height: size)
        case .tile:
            mark.frame(width: size, height: size).clipShape(shape)
        case .needsBacking:
            mark.padding(size * 0.14)
                .frame(width: size, height: size)
                .background(shape.fill(colorScheme == .dark ? Color.white : Color(hex: 0x242426)))
        }
    }

    /// A logo: the site's own dark icon on the calm dark square in the dark UI, where it
    /// has one; otherwise the logo on white.
    @ViewBuilder
    private func logo(_ image: NSImage, dark: NSImage?) -> some View {
        if colorScheme == .dark, let dark {
            // The site's own dark-mode icon, made for a dark background: on the
            // calm dark square rather than on white.
            Image(nsImage: dark)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .padding(size * 0.14)
                .frame(width: size, height: size)
                .background(shape.fill(DS.Palette.bg300))
                .overlay(shape.strokeBorder(DS.Palette.line, lineWidth: DS.hairline))
                .clipShape(shape)
        } else {
            // A logo sits on white, the way a favicon does in a browser. On the light
            // theme's white panels it takes a 1pt `line` edge, like the letter tiles, so
            // the square still reads.
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .background(Color.white)
                .clipShape(shape)
                .overlay {
                    if colorScheme == .light {
                        shape.strokeBorder(DS.Palette.line, lineWidth: DS.hairline)
                    }
                }
        }
    }

    private var fallback: some View {
        Text(IconInitial.initial(of: subscription.name))
            .font(DSFonts.font(DSFonts.monoMedium, size: (size * 0.42).rounded()))
            .foregroundStyle(DS.Palette.accent)
            .frame(width: size, height: size)
            .background(shape.fill(fallbackFill))
            .overlay(shape.strokeBorder(DS.Palette.line, lineWidth: DS.hairline))
    }
}
