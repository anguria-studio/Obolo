import SwiftUI
import OboloCore

// Shared controls for Settings panes.
//
// A pane is a scrolling column of sections. A section is a mono uppercase title, a card
// (bg-200, 1pt line, 16pt corners, 16pt side padding) whose rows are split by straight
// 1pt hairlines, and an optional footnote under it. A row is a 13pt title with an
// optional 11pt description and its control on the right, at least 42pt tall.
//
// The controls stay native where macOS draws them well: switches, checkboxes, text
// fields and steppers, tinted with the accent. Pop-up menus and buttons are drawn as
// the window's pills: `PrefMenu`, `PrefPicker` and `PrefButtonStyle`.

// MARK: - Page

/// A pane's scrolling column. Reports its content height so the window fits the pane.
struct PrefPage<Content: View>: View {
    let tab: PreferencesTab
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .measuringPaneHeight(tab)
    }
}

// MARK: - Section

/// A titled card of rows, with straight hairlines between them and an optional
/// footnote under the card.
struct PrefSection<Content: View, Footer: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .prefSectionTitle()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            PrefCard { content }
            VStack(alignment: .leading, spacing: 4) { footer }
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }
}

extension PrefSection where Footer == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { EmptyView() }
    }
}

/// The card on its own: each child view becomes a row, with a straight 1pt hairline
/// between neighbours.
struct PrefCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 {
                        Rectangle().fill(DS.Palette.line).frame(height: 1)
                    }
                    subview
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(border: 1)
    }
}

/// A footnote under a card: 11pt `inkDisabled`, or `danger` for an error.
struct PrefFootnote: View {
    let text: String
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        Text(text)
            .font(DSFonts.font(DSFonts.sansRegular, size: 11))
            .foregroundStyle(isError ? DS.Palette.danger : DS.Palette.inkDisabled)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rows

/// A row: title (13pt `ink`), optional description (11pt `inkMuted`) and a control on
/// the right; at least 42pt tall with 8pt above and below.
struct PrefRow<Control: View>: View {
    let title: String
    var description: String?
    /// The description in mono, for a row whose description is a file path.
    var isMonoDescription = false
    @ViewBuilder let control: Control

    init(
        _ title: String,
        _ description: String? = nil,
        isMonoDescription: Bool = false,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description
        self.isMonoDescription = isMonoDescription
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            PrefRowLabel(title: title, description: description, isMonoDescription: isMonoDescription)
                .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .prefRowPadding()
    }
}

extension PrefRow where Control == EmptyView {
    init(_ title: String, _ description: String? = nil) {
        self.init(title, description) { EmptyView() }
    }
}

/// A row's title and description, for rows that lay out their own control.
struct PrefRowLabel: View {
    let title: String
    var description: String?
    var isMonoDescription = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DSFonts.font(DSFonts.sansRegular, size: 13))
                .foregroundStyle(DS.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let description {
                Text(description)
                    .font(isMonoDescription
                          ? DSFonts.font(DSFonts.monoRegular, size: 11)
                          : DSFonts.font(DSFonts.sansRegular, size: 11))
                    .foregroundStyle(DS.Palette.inkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row with a native switch on the right.
struct PrefToggleRow: View {
    let title: String
    var description: String?
    @Binding var isOn: Bool

    init(_ title: String, _ description: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        self._isOn = isOn
    }

    var body: some View {
        PrefRow(title, description) {
            Toggle(title, isOn: $isOn)
                .prefSwitch()
        }
    }
}

/// A row with one pill button at its leading edge, such as "Add category". The help
/// text is also the button's accessibility label.
struct PrefButtonRow: View {
    let title: String
    let help: String
    let action: () -> Void

    init(_ title: String, help: String, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.action = action
    }

    var body: some View {
        HStack {
            Button(title, action: action)
                .prefButton()
                .help(help)
                .accessibilityLabel(help)
            Spacer(minLength: 0)
        }
        .prefRowPadding()
    }
}

/// A read-only value on the right of a row: mono 12 `inkMuted`.
struct PrefValue: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DSFonts.font(DSFonts.monoRegular, size: 12))
            .tracking(0.5)
            .foregroundStyle(DS.Palette.inkMuted)
            .lineLimit(1)
    }
}

// MARK: - Pills

/// A pop-up drawn as the window's pill: 26pt, full radius, 1pt `lineStrong` border (on
/// hover `inkMuted`), the value in mono 12 and a small chevron. The menu itself is the
/// system's.
struct PrefMenu<Items: View>: View {
    let value: String
    var accessibilityLabel: String?
    @ViewBuilder let items: Items

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ value: String, accessibilityLabel: String? = nil, @ViewBuilder items: () -> Items) {
        self.value = value
        self.accessibilityLabel = accessibilityLabel
        self.items = items()
    }

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 6) {
                Text(value)
                    .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                    .tracking(0.5)
                    .foregroundStyle(isEnabled ? DS.Palette.ink : DS.Palette.inkDisabled)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Palette.inkMuted)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 26)
            .overlay(
                Capsule().strokeBorder(
                    !isEnabled ? DS.Palette.line : isHovering ? DS.Palette.inkMuted : DS.Palette.lineStrong,
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .dsFocusRing(Capsule())
        .accessibilityLabel(accessibilityLabel ?? value)
    }
}

/// A `PrefMenu` that picks one of a list of values.
struct PrefPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var accessibilityLabel: String?

    var body: some View {
        PrefMenu(
            options.first { $0.value == selection }?.title ?? "–",
            accessibilityLabel: accessibilityLabel
        ) {
            Picker(accessibilityLabel ?? "", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// The window's buttons: outline pills, 26pt, mono 12. Destructive ones in `danger`;
/// disabled ones `inkDisabled` on a `line` border.
struct PrefButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, isDestructive: isDestructive)
    }

    private struct Pill: View {
        let configuration: ButtonStyleConfiguration
        let isDestructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let tone = isDestructive ? DS.Palette.danger : DS.Palette.ink
            configuration.label
                .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                .tracking(0.5)
                .lineLimit(1)
                .foregroundStyle(isEnabled ? tone : DS.Palette.inkDisabled)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(configuration.isPressed ? DS.Palette.bg300 : .clear))
                .overlay(
                    Capsule().strokeBorder(
                        !isEnabled ? DS.Palette.line
                            : isDestructive ? DS.Palette.danger
                            : isHovering ? DS.Palette.inkMuted : DS.Palette.lineStrong,
                        lineWidth: 1
                    )
                )
                .contentShape(Capsule())
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

extension View {
    /// A row's vertical rhythm: 8pt above and below, at least 42pt tall. For rows that
    /// lay out their own content instead of using `PrefRow`.
    func prefRowPadding() -> some View {
        padding(.vertical, 8)
            .frame(minHeight: 42)
    }

    /// A row's native switch: small, with its label hidden.
    func prefSwitch() -> some View {
        dsSwitch()
            .controlSize(.small)
    }

    /// The window's outline pill button.
    func prefButton(destructive: Bool = false) -> some View {
        buttonStyle(PrefButtonStyle(isDestructive: destructive))
            .dsFocusRing(Capsule())
    }

    /// Section titles: Geist Mono 11, uppercase, tracking .08em, `inkMuted`.
    func prefSectionTitle() -> some View {
        font(DSFonts.font(DSFonts.monoMedium, size: 11))
            .tracking(0.88)
            .textCase(.uppercase)
            .foregroundStyle(DS.Palette.inkMuted)
    }
}

/// A small on/off chip (the calendar's "Alert me" offsets): 22pt, mono 10 uppercase;
/// on: `ink` border on `bg300`; off: `lineStrong` border, `inkMuted` text.
struct PrefChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DSFonts.font(DSFonts.monoMedium, size: 10))
            .tracking(0.88)
            .textCase(.uppercase)
            .foregroundStyle(isOn ? DS.Palette.ink : DS.Palette.inkMuted)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(isOn || configuration.isPressed ? DS.Palette.bg300 : .clear))
            .overlay(Capsule().strokeBorder(isOn ? DS.Palette.ink : DS.Palette.lineStrong, lineWidth: 1))
            .contentShape(Capsule())
    }
}

// MARK: - Row icon buttons

/// The small icon buttons at a row's end (remove, back to automatic): `inkMuted`, `ink`
/// on hover, `danger` on hover for a destructive one, `inkDisabled` when disabled.
struct RowIconButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        Icon(configuration: configuration, isDestructive: isDestructive)
    }

    private struct Icon: View {
        let configuration: ButtonStyleConfiguration
        let isDestructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(
                    !isEnabled ? DS.Palette.inkDisabled
                        : isHovering ? (isDestructive ? DS.Palette.danger : DS.Palette.ink)
                        : DS.Palette.inkMuted
                )
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(configuration.isPressed ? DS.Palette.bg300 : .clear)
                )
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

// MARK: - Tab bar

/// Settings tabs as 80 × 48 tiles: an 18pt line icon over a mono 9 label.
/// The selected one `ink` on a `bg300` tile with a `line`
/// border; the others `inkMuted`, `ink` on hover.
struct PrefTabBar: View {
    @Binding var selection: PreferencesTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PreferencesTab.allCases, id: \.self) { tab in
                PrefTabButton(tab: tab, isSelected: selection == tab) { selection = tab }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PrefTabButton: View {
    let tab: PreferencesTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                PrefTabIcon(tab: tab).frame(width: 18, height: 18)
                Text(tab.title)
                    .font(DSFonts.font(DSFonts.monoMedium, size: 9))
                    .tracking(0.8)
                    .textCase(.uppercase)
            }
            .foregroundStyle(isSelected || isHovering ? DS.Palette.ink : DS.Palette.inkMuted)
            .padding(.top, 7)
            .frame(width: 80, height: 48, alignment: .top)
            // The picked tab: bg300 in dark, a white pill with a soft shadow in light, as
            // the switches' picked option.
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? DS.Palette.segmentOn : .clear)
                    .shadow(color: isSelected ? DS.Palette.segmentShadow : .clear, radius: 1, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isSelected ? DS.Palette.line : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .dsFocusRing(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The tabs' line icons, in the gear's style: 24-unit box, 1.4 stroke, mitred.
struct PrefTabIcon: View {
    let tab: PreferencesTab

    var body: some View {
        if tab == .general {
            GearIcon()
        } else {
            Canvas { context, size in
                let scale = min(size.width, size.height) / 24
                context.stroke(
                    Self.path(tab).applying(CGAffineTransform(scaleX: scale, y: scale)),
                    with: .style(.foreground),
                    style: StrokeStyle(lineWidth: 1.4 * scale, lineCap: .butt, lineJoin: .miter, miterLimit: 4)
                )
            }
            .accessibilityHidden(true)
        }
    }

    private static func path(_ tab: PreferencesTab) -> Path {
        var path = Path()
        func poly(_ points: [(CGFloat, CGFloat)], closed: Bool) {
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            if closed { path.closeSubpath() }
        }
        switch tab {
        case .general:
            break
        case .reminders:
            // A bell: M6 17 V10.5 L8 6 H16 L18 10.5 V17 L19.5 18.5 H4.5 Z M10 21 H14
            poly([(6, 17), (6, 10.5), (8, 6), (16, 6), (18, 10.5), (18, 17), (19.5, 18.5), (4.5, 18.5)], closed: true)
            poly([(10, 21), (14, 21)], closed: false)
        case .categories:
            for (x, y) in [(4.5, 4.5), (13.5, 4.5), (4.5, 13.5), (13.5, 13.5)] as [(CGFloat, CGFloat)] {
                poly([(x, y), (x + 6, y), (x + 6, y + 6), (x, y + 6)], closed: true)
            }
        case .currencies:
            poly([(12, 3.5), (19.5, 8), (19.5, 16), (12, 20.5), (4.5, 16), (4.5, 8)], closed: true)
            poly([(15, 9), (11, 9), (9.5, 12), (11, 15), (15, 15)], closed: false)
            poly([(8.5, 11), (13, 11)], closed: false)
            poly([(8.5, 13), (13, 13)], closed: false)
        case .data:
            poly([(4, 9), (20, 9), (20, 15), (4, 15)], closed: true)
            poly([(4, 9), (7, 4.5), (17, 4.5), (20, 9)], closed: false)
            poly([(16, 12), (17, 12)], closed: false)
        #if OBOLO_DIRECT
        case .updates:
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 7,
                        startAngle: .degrees(5), endAngle: .degrees(315), clockwise: false)
            poly([(17, 2.5), (17, 7), (12.5, 7)], closed: false)
        #endif
        }
        return path
    }
}

extension PreferencesTab {
    var title: String {
        switch self {
        case .general: "General"
        case .reminders: "Reminders"
        case .categories: "Categories"
        case .currencies: "Currencies"
        case .data: "Data"
        #if OBOLO_DIRECT
        case .updates: "Updates"
        #endif
        }
    }
}
