import AppKit
import CoreText
import SwiftUI
import OboloCore

/// The instrument design system: thin lines, mono labels, one orange, in a dark and a
/// light theme.
///
/// Each palette colour resolves against the appearance that `AppearanceSetting` selects for the window.
///
/// `Token` (the older, system-colour design) is left only behind `IconInitial`'s tinted
/// circle. Every other view takes its values from here.
enum DS {

    // MARK: - Colour

    /// Surfaces, lines, text and the action colour in light and dark appearances.
    enum Palette {
        /// Desktop behind the window and the gutter between nested panels. No text on it.
        static let bg000 = Color(dark: 0x0B0B0C, light: 0xE9E9EC)
        /// Window shell, its top and bottom bars.
        static let bg100 = Color(nsColor: bg100NS)
        static let bg100NS = NSColor.ds(dark: 0x131314, light: 0xF4F4F6)
        /// Panels inside the window.
        static let bg200 = Color(dark: 0x1A1A1B, light: 0xFFFFFF)
        /// Cells and controls inside a panel: calendar days, weekday pills, avatars,
        /// the hovered list row.
        static let bg300 = Color(dark: 0x242426, light: 0xF3F3F5)
        /// Toggle track when off; pressed state of `bg300` controls.
        static let bg400 = Color(dark: 0x2F2F31, light: 0xE9E9ED)

        /// 1px hairline: panel borders, row dividers, the line under column headers.
        /// Decorative only, never the only edge of a control.
        static let line = Color(dark: 0x2A2A2C, light: 0xE4E4E9)
        /// Borders of outline buttons, chips and selects; dotted gridlines; unfilled
        /// ticks and future bars. 3:1 on `bg100` and `bg200`.
        static let lineStrong = Color(dark: 0x6B6B70, light: 0xB4B4BC)

        static let ink = Color(dark: 0xF2F2F0, light: 0x141416)
        /// Mono labels, captions, secondary values. 4.5:1 down to `bg300`.
        static let inkMuted = Color(dark: 0x9A9A9F, light: 0x6B6B73)
        /// Out-of-range days, cancelled values, disabled controls. Not for text that
        /// must be read.
        static let inkDisabled = Color(dark: 0x5C5C60, light: 0xA9A9B1)

        /// The one action colour, the same in both themes. One primary button per view.
        static let accent = Color(hex: 0xF2703A)
        /// Text and icons on `accent`.
        static let accentInk = Color(dark: 0x150A05, light: 0xFFFFFF)
        /// Fill of the today cell and the trial-ends date, always with a 1px accent border.
        static let accentTint = Color(dark: 0x2B1A11, light: 0xFDECE3)

        /// Spend going down. Text or small arrows only.
        static let positive = Color(dark: 0x4ADE80, light: 0x1F9D55)
        /// Due within 7 days: text and small marks. Dark amber in light, for contrast.
        static let warning = Color(dark: 0xF5C542, light: 0xB58500)
        /// Price increase, failed payment, destructive confirm.
        static let danger = Color(dark: 0xFF6B5E, light: 0xDC3B2F)
        /// The label on a `danger` fill: near-black on the dark theme's red, white on
        /// the light theme's.
        static let dangerInk = Color(dark: 0x1A0806, light: 0xFFFFFF)

        /// The yearly-cycle marker: bright yellow in both themes, as a dot rather than
        /// text, while `warning` text turns amber in light.
        static let cycleYearly = Color(hex: 0xF5C542)

        /// A switch's picked option: `bg300` in dark; a white pill in light, where
        /// `bg300` would vanish on the track.
        static let segmentOn = Color(dark: 0x242426, light: 0xFFFFFF)
        /// The picked pill's edge: none in dark, a `line` hairline in light.
        static let segmentOnEdge = Color(nsColor: .ds(dark: 0x2A2A2C, light: 0xE4E4E9, darkAlpha: 0, lightAlpha: 1))
        /// The picked pill's soft shadow: none in dark, black at 8% in light.
        static let segmentShadow = Color(nsColor: .ds(dark: 0x000000, light: 0x000000, darkAlpha: 0, lightAlpha: 0.08))
        /// A switch's track edge: `line` in dark, none in light, where the track is
        /// `bg400` and needs no outline.
        static let segmentTrackEdge = Color(nsColor: .ds(dark: 0x2A2A2C, light: 0xE4E4E9, darkAlpha: 1, lightAlpha: 0))

        /// The dim behind a sheet: `bg000` at 72% in dark, black at 14% in light.
        static let scrim = Color(nsColor: .ds(dark: 0x0B0B0C, light: 0x000000, darkAlpha: 0.72, lightAlpha: 0.14))
        /// A floating surface's shadow, used at 50%: black in dark, and black at 28% in
        /// light, so the same `.opacity(0.5)` gives about 14%.
        static let shadow = Color(nsColor: .ds(dark: 0x000000, light: 0x000000, darkAlpha: 1, lightAlpha: 0.28))
    }

    /// The design's category colours, by token name. Only the one the calendar's
    /// monthly marker uses is left.
    enum CategoryColor {
        static let violet = Color(hex: 0xA08CF8)
    }

    /// A category's colour: the twelve-hue palette, matched in
    /// intensity (OKLCH L .64–.78, C .14) and kept clear of the orange accent.
    static func category(_ hue: CategoryHue) -> Color {
        switch hue {
        case .rose: Color(hex: 0xF58397)
        case .magenta: Color(hex: 0xC86EB0)
        case .violet: Color(hex: 0xA793F4)
        case .blue: Color(hex: 0x5C8AE1)
        case .sky: Color(hex: 0x37BFFA)
        case .teal: Color(hex: 0x179FA5)
        case .mint: Color(hex: 0x28CDA7)
        case .green: Color(hex: 0x46A359)
        case .lime: Color(hex: 0xA5C65B)
        case .olive: Color(hex: 0xB09803)
        case .slate: Color(hex: 0x8EA1B4)
        case .gray: Color(hex: 0x7A7A80)
        }
    }

    /// The "Letter" icon's colours: category hues and white. `amber` (stored as such)
    /// now draws magenta, so nothing here sits near the accent.
    static func letterColor(_ color: LetterColor) -> Color {
        switch color {
        case .blue: category(CategoryHue.blue)
        case .green: category(CategoryHue.green)
        case .teal: category(CategoryHue.teal)
        case .rose: category(CategoryHue.rose)
        case .violet: category(CategoryHue.violet)
        case .amber: category(CategoryHue.magenta)
        case .gray: category(CategoryHue.gray)
        // White stays white in both themes: letter colours don't follow the theme.
        case .white: Color(hex: 0xF2F2F0)
        }
    }

    // MARK: - Radius, size

    enum Radius {
        /// Square category and cycle markers. Markers are never circles.
        static let mark: CGFloat = 2
        /// Selected rows in a chart legend, numbered badges.
        static let xs: CGFloat = 6
        /// Calendar day cells, small inputs.
        static let md: CGFloat = 12
        /// Panels and the sheets' cards: the window's corner (about 26) less the 8pt gap,
        /// so a panel follows the window's curve. A fixed value, not
        /// `ConcentricRectangle`: the panels sit between the top and bottom bars, far
        /// from any window corner, so there is no corner to be concentric with.
        static let lg: CGFloat = 18
    }

    enum Size {
        /// The window's content: 640 × 640, including the 52pt top bar.
        static let window: CGFloat = 640
        static let topBar: CGFloat = 52
        static let bottomBar: CGFloat = 60
        /// Inset of the panels from the window edge, and the gap between two panels.
        static let gutter: CGFloat = 8
        /// Pills in the window chrome (Add, ⋮, tools).
        static let control: CGFloat = 34
        /// Pills inside a panel.
        static let controlInPanel: CGFloat = 28
        /// Markers in lists and chips.
        static let marker: CGFloat = 10
        /// Markers in calendar cells.
        static let markerSmall: CGFloat = 6
    }

    /// The hairline. The design's 1px is one point, not one device pixel.
    static let hairline: CGFloat = 1
}

// MARK: - Hex colours

extension Color {
    /// An sRGB colour from a 0xRRGGBB literal, the way the tokens file writes them.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// One colour per theme: `dark` in a dark appearance, `light` in a light one.
    init(dark: UInt32, light: UInt32) {
        self.init(nsColor: .ds(dark: dark, light: light))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// A colour that resolves against the appearance it is drawn in.
    static func ds(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            DS.isDark(appearance)
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        }
    }
}

extension AppearanceSetting {
    /// The appearance every window takes: `nil` follows macOS.
    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .auto: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}

extension DS {
    /// Whether `appearance` is one of the dark ones (including high contrast).
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }
}

// MARK: - Type

/// Geist and Geist Mono, bundled under the SIL Open Font License
/// (`App/Resources/Fonts/Geist-OFL.txt`).
///
/// The fonts are registered for this process the first time any style is read, so no
/// launch code has to remember to do it. A style whose face is missing (the hostless
/// test bundle has no fonts) falls back to the system font at the same size, which is
/// what `Font.custom` does for an unknown name.
enum DSFonts {
    static let sansRegular = "Geist-Regular"
    static let sansMedium = "Geist-Medium"
    static let monoRegular = "GeistMono-Regular"
    static let monoMedium = "GeistMono-Medium"

    /// Runs once per process. A face that is already available (installed by the user,
    /// or registered earlier) reports a duplicate, which is harmless.
    static let registered: Bool = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        let fonts = urls.filter { $0.lastPathComponent.hasPrefix("Geist") }
        guard !fonts.isEmpty else { return false }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
        return true
    }()

    static func font(_ name: String, size: CGFloat) -> Font {
        _ = registered
        return .custom(name, fixedSize: size)
    }
}

/// One entry of the design's type ramp: face, size, line height and tracking together,
/// because a SwiftUI `Font` cannot carry tracking or line height on its own.
///
/// Apply with `.dsStyle(_:)`. Tracking is stored in points (em × size).
struct DSTextStyle: Sendable {
    let face: String
    let size: CGFloat
    let lineHeight: CGFloat
    let tracking: CGFloat
    let uppercase: Bool
    /// Tabular figures. Geist Mono is monospaced already; this matters for the sans
    /// hero numbers.
    let tabular: Bool

    var font: Font {
        let font = DSFonts.font(face, size: size)
        return tabular ? font.monospacedDigit() : font
    }

    // Numbers (Geist)

    /// The one hero figure per card. Unit at 24pt in `inkMuted`.
    static let numXL = DSTextStyle(face: DSFonts.sansRegular, size: 44, lineHeight: 48, tracking: -0.44, uppercase: false, tabular: true)
    /// Large input values and secondary figures.
    static let numLG = DSTextStyle(face: DSFonts.sansRegular, size: 32, lineHeight: 36, tracking: -0.32, uppercase: false, tabular: true)

    // Text (Geist)

    /// List row titles (subscription names).
    static let heading = DSTextStyle(face: DSFonts.sansMedium, size: 17, lineHeight: 22, tracking: 0, uppercase: false, tabular: false)
    /// Buttons, form values, running text.
    static let body = DSTextStyle(face: DSFonts.sansRegular, size: 15, lineHeight: 20, tracking: 0, uppercase: false, tabular: false)
    /// Primary and outline buttons both use the regular body font.
    static let button = DSTextStyle(face: DSFonts.sansRegular, size: 15, lineHeight: 20, tracking: 0, uppercase: false, tabular: false)
    /// Helper text under fields, tooltips.
    static let bodySmall = DSTextStyle(face: DSFonts.sansRegular, size: 13, lineHeight: 18, tracking: 0, uppercase: false, tabular: false)

    // Mono (Geist Mono)

    /// UPPERCASE metadata: panel labels, row captions, switch options, the status line.
    static let label = DSTextStyle(face: DSFonts.monoMedium, size: 12, lineHeight: 16, tracking: 0.96, uppercase: true, tabular: true)
    /// The 10pt caption under a row title ("AI TOOLS · MONTHLY").
    static let labelSmall = DSTextStyle(face: DSFonts.monoMedium, size: 10, lineHeight: 14, tracking: 0.8, uppercase: true, tabular: true)
    /// Sentence-case column headers above a list.
    static let column = DSTextStyle(face: DSFonts.monoRegular, size: 13, lineHeight: 18, tracking: 0.52, uppercase: false, tabular: true)
    /// Amounts, dates and counts in rows and cells.
    static let data = DSTextStyle(face: DSFonts.monoRegular, size: 14, lineHeight: 20, tracking: 0.28, uppercase: false, tabular: true)
    /// The amount at the end of a list row.
    static let dataLG = DSTextStyle(face: DSFonts.monoRegular, size: 17, lineHeight: 22, tracking: 0.34, uppercase: false, tabular: true)
}

extension View {
    /// Sets face, tracking, case and line height from one ramp entry. Colour is left to
    /// the caller, except where a style always has one (see `dsLabel()`).
    func dsStyle(_ style: DSTextStyle) -> some View {
        modifier(DSTextStyleModifier(style: style))
    }

    /// The mono UPPERCASE label in `inkMuted`, the design's metadata voice.
    func dsLabel() -> some View {
        dsStyle(.label).foregroundStyle(DS.Palette.inkMuted)
    }
}

extension Text {
    /// A value in `ink` inside a line set in `inkMuted`: "12 shown · 48,00 € / mo".
    static func ink(_ string: String) -> Text {
        Text(string).foregroundStyle(DS.Palette.ink)
    }
}

private struct DSTextStyleModifier: ViewModifier {
    let style: DSTextStyle

    func body(content: Content) -> some View {
        content
            .font(style.font)
            .tracking(style.tracking)
            .textCase(style.uppercase ? .uppercase : nil)
            // Line height above the face's own. Approximate: SwiftUI adds this between
            // lines, and single-line labels take their height from the frame anyway.
            .lineSpacing(max(0, style.lineHeight - style.size * 1.2))
    }
}

// MARK: - Markers and surfaces

/// The square category marker. 10pt in lists and chips, 6–8pt in calendar cells.
/// Never a circle: circles are for logos.
struct CategoryMarker: View {
    let color: Color
    var size: CGFloat = DS.Size.marker

    init(_ hue: CategoryHue, size: CGFloat = DS.Size.marker) {
        self.color = DS.category(hue)
        self.size = size
    }

    init(color: Color, size: CGFloat = DS.Size.marker) {
        self.color = color
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.mark, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension DS {
    /// A panel's outline: 18pt continuous corners (`Radius.lg`). Only panels and the
    /// sheets' cards use it; everything inside them stays on the fixed scale.
    static var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
    }
}

extension View {
    /// A `bg200` panel: 18pt corners (`DS.panelShape`) and a 1px `line` border. Depth
    /// comes from nesting, never from a shadow.
    func dsPanel() -> some View {
        dsCard(border: DS.hairline)
    }

    /// A `bg200` card in `DS.panelShape` with a `line` border of `border` points, the
    /// panels' and the sheets' cards alike.
    func dsCard(border: CGFloat) -> some View {
        background(DS.panelShape.fill(DS.Palette.bg200))
            .overlay(DS.panelShape.strokeBorder(DS.Palette.line, lineWidth: border))
            .clipShape(DS.panelShape)
    }
}

// MARK: - Buttons

/// The filled orange pill. One per screen. `mono` sets its label in Geist Mono, for a
/// pill inside a popover, where every button is mono.
struct DSPrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = DS.Size.control
    var mono = false

    func makeBody(configuration: Configuration) -> some View {
        DSPrimaryButton(configuration: configuration, height: height, mono: mono)
    }

    private struct DSPrimaryButton: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let mono: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .dsStyle(mono ? .column : .button)
                .foregroundStyle(isEnabled ? DS.Palette.accentInk : DS.Palette.inkDisabled)
                .padding(.horizontal, 14)
                .frame(height: height)
                .background(
                    // Disabled: a neutral pill, so orange only ever means "you can".
                    Capsule().fill(isEnabled ? DS.Palette.accent : DS.Palette.bg400)
                        .brightness(isEnabled && configuration.isPressed ? -0.08 : isEnabled && isHovering ? 0.04 : 0)
                )
                .contentShape(Capsule())
                .onHover { isHovering = $0 }
        }
    }
}

/// The filled `danger` pill with a dark label, in mono: a popover's Delete.
struct DSDangerButtonStyle: ButtonStyle {
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        DSDangerButton(configuration: configuration, height: height)
    }

    private struct DSDangerButton: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .dsStyle(.column)
                .foregroundStyle(DS.Palette.dangerInk)
                .padding(.horizontal, 12)
                .frame(height: height)
                .background(
                    Capsule().fill(DS.Palette.danger)
                        .brightness(configuration.isPressed ? -0.08 : isHovering ? 0.04 : 0)
                )
                .contentShape(Capsule())
                .onHover { isHovering = $0 }
        }
    }
}

/// The outline pill: 1px `lineStrong`, no fill.
struct DSSecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = DS.Size.control
    var mono = false

    func makeBody(configuration: Configuration) -> some View {
        DSSecondaryButton(configuration: configuration, height: height, mono: mono)
    }

    private struct DSSecondaryButton: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let mono: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .dsStyle(mono ? .column : .button)
                .foregroundStyle(DS.Palette.ink)
                .padding(.horizontal, mono ? 12 : 14)
                .frame(height: height)
                .background(Capsule().fill(configuration.isPressed ? DS.Palette.bg400 : isHovering ? DS.Palette.bg300 : .clear))
                .overlay(Capsule().strokeBorder(DS.Palette.lineStrong, lineWidth: DS.hairline))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { isHovering = $0 }
        }
    }
}

/// An icon button with no border: `inkMuted` at rest, `ink` on hover.
struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = DS.Size.control

    func makeBody(configuration: Configuration) -> some View {
        DSIconButton(configuration: configuration, size: size)
    }

    private struct DSIconButton: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isHovering && isEnabled ? DS.Palette.ink : DS.Palette.inkMuted)
                .frame(width: size, height: size)
                .background(Circle().fill(configuration.isPressed ? DS.Palette.bg300 : .clear))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
                .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Segmented switch

/// The pill switch: the window's Home · Calendar · All, and the chart switch on Home.
///
/// In dark, a `bg200` capsule with a 1px `line` border and 3pt inset, the selected
/// option a `bg300` capsule. In light, a `bg400` track with no border, the selected
/// option a white pill with a hairline and a soft shadow. Selected text is `ink`, the
/// others `inkMuted` mono labels.
struct DSSegmentedSwitch<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let selection: Value?
    let onSelect: (Value) -> Void
    var accessibilityLabel: String = "Sections"
    /// 26 in the window chrome, 24 inside a panel.
    var itemHeight: CGFloat = 26
    var itemPadding: CGFloat = 14
    /// `bg200` in the chrome; `bg100` inside a panel, so the track reads as a well. Dark
    /// theme only: in light the track is always `bg400`, under a white picked pill.
    var trackFill: Color = DS.Palette.bg200
    /// Spread the options across the whole width (the icon popover's Logo | Letter).
    var fillsWidth = false

    @Namespace private var namespace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    onSelect(option.value)
                } label: {
                    Text(option.title)
                        .dsStyle(.label)
                        .foregroundStyle(isSelected ? DS.Palette.ink : DS.Palette.inkMuted)
                        .padding(.horizontal, itemPadding)
                        .frame(maxWidth: fillsWidth ? .infinity : nil)
                        .frame(height: itemHeight)
                        .background {
                            if isSelected {
                                // bg300 in dark; in light a white pill with a hairline
                                // and a soft shadow, so it stands off the bg400 track.
                                Capsule()
                                    .fill(DS.Palette.segmentOn)
                                    .overlay(Capsule().strokeBorder(DS.Palette.segmentOnEdge, lineWidth: DS.hairline))
                                    .shadow(color: DS.Palette.segmentShadow, radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .dsFocusRing(Capsule())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(colorScheme == .light ? DS.Palette.bg400 : trackFill))
        .overlay(Capsule().strokeBorder(DS.Palette.segmentTrackEdge, lineWidth: DS.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Popover panel

extension View {
    /// A popover's content, built like the date picker: `bg200` inside the system
    /// popover, which draws its own border, corners and shadow. 8pt in a menu, 12pt in
    /// anything else.
    func dsPopoverPanel(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(DS.Palette.bg200)
    }
}

// MARK: - Focus

/// Whether the last thing the user did was a key press rather than a click.
///
/// macOS keeps the focus ring on a control after it is clicked when Full Keyboard Access
/// is on. The design wants a ring only while someone is moving through the window with
/// the keyboard, so focus rings here read this before they draw.
@MainActor
@Observable
final class InputModality {
    static let shared = InputModality()

    private(set) var isKeyboard = false
    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            let keyboard = event.type == .keyDown
            MainActor.assumeIsolated {
                if InputModality.shared.isKeyboard != keyboard {
                    InputModality.shared.isKeyboard = keyboard
                }
            }
            return event
        }
    }
}

extension View {
    /// A compact native switch whose visible label is supplied by its row.
    func dsSwitch() -> some View {
        toggleStyle(.switch)
            .labelsHidden()
            .fixedSize()
            .dsFocusRing(Capsule())
    }

    /// Replaces the system focus ring with the design's: a 1.5pt `ink` outline in
    /// `shape`, drawn only while the focus was reached from the keyboard. Apply it to the
    /// `Button` (or other focusable view) itself.
    func dsFocusRing<S: InsettableShape>(_ shape: S) -> some View {
        modifier(DSFocusRing(shape: shape))
    }
}

private struct DSFocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        // Start observing before the first Tab can give this control focus.
        let isKeyboard = InputModality.shared.isKeyboard
        content
            .focusEffectDisabled()
            .focused($isFocused)
            .overlay {
                shape
                    .strokeBorder(DS.Palette.ink, lineWidth: 1.5)
                    .opacity(isFocused && isKeyboard ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    /// Fades the last 20pt of a scroll view while there is more below, so a list that
    /// continues past the panel says so without a scroll bar. Once scrolled to the end,
    /// or when everything fits, the last row is drawn in full. Apply it to the
    /// `ScrollView` itself.
    func dsScrollFade() -> some View {
        modifier(DSScrollFade())
    }
}

private struct DSScrollFade: ViewModifier {
    @State private var moreBelow = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
            } action: { _, isMore in
                moreBelow = isMore
            }
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(
                        colors: [.black, .black.opacity(moreBelow ? 0 : 1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 20)
                }
                .animation(.easeOut(duration: 0.15), value: moreBelow)
            }
    }
}

// MARK: - Motion

/// The design's motion: slow, ease-out, never a bounce or an overshoot.
enum DSMotion {
    /// cubic-bezier(.22, .61, .36, 1): fast start, long soft landing.
    static func easeOutCubic(_ duration: Double) -> Animation {
        .timingCurve(0.22, 0.61, 0.36, 1, duration: duration)
    }

    /// A slab settling into the stack.
    static let settle = easeOutCubic(1.0)
    /// A month bar growing from the baseline.
    static let grow = easeOutCubic(0.7)
    /// Hover movement (a lifted slab, the call-out). Critically damped, so it eases out
    /// like the curve above with no overshoot, but when the target changes mid-move it
    /// keeps its speed instead of restarting, which a timing curve cannot do.
    static let glide = Animation.smooth(duration: 0.4, extraBounce: 0)
}

// MARK: - Motion

/// Changes that take effect immediately, including bar-chart hover and selection.
/// The tick strip sets its own timing for each step.
enum Motion {
    /// No animation: the change is simply there.
    static let snap: Animation? = nil
}

// MARK: - Popover rows

/// Popover rows highlight on hover, press and keyboard focus. The fill uses `ink`
/// at 4% over `bg300`, with 10pt corners and a 0.1 s ease-out.
struct PopoverRowStyle: ButtonStyle {
    /// A `bg300` cell that goes to `bg400` on hover, press and keyboard focus, as in the
    /// ⋮ menu. Off: a plain row that lights to `ink` at 4%.
    var isCell = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isCell: isCell)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let isCell: Bool
        @State private var isHovering = false
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let lit = configuration.isPressed || isHovering || (isFocused && InputModality.shared.isKeyboard)
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isCell ? (lit ? DS.Palette.bg400 : DS.Palette.bg300) : DS.Palette.ink.opacity(lit ? 0.04 : 0))
                )
                .animation(.easeOut(duration: 0.1), value: lit)
                .onHover { isHovering = $0 }
        }
    }
}

extension View {
    /// The surface of a list that drops over the window rather than in a system popover
    /// (Home's needs-attention list, All's category list): `bg300` in 16pt continuous
    /// corners, a 1pt `lineStrong` border and a deep shadow.
    func dsDropdownSurface() -> some View {
        background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Palette.bg300))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Palette.lineStrong, lineWidth: DS.hairline))
            .shadow(color: DS.Palette.shadow.opacity(0.5), radius: 20, y: 18)
    }
}

/// The line between two groups of rows in the recovery panel's backups popover:
/// `lineStrong` at half strength, inset 6pt from the sides with 4pt above and below.
struct PopoverDivider: View {
    var body: some View {
        Rectangle().fill(DS.Palette.lineStrong.opacity(0.5)).frame(height: DS.hairline)
            .padding(.horizontal, 6).padding(.vertical, 4)
    }
}
