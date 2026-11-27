import SwiftUI

/// "Netflix deleted · Undo · ⌘Z": the pill after a delete. `bg300`
/// with a 1pt `lineStrong` edge and a popover's shadow, 40pt tall. Hovering it holds the
/// undo window open (`onHover`).
struct UndoMessage: View {
    let name: String
    let onUndo: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text("\(name) deleted")
                .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                .foregroundStyle(DS.Palette.ink)
                .lineLimit(1)
            Button(action: onUndo) {
                Text("Undo")
                    // Regular, as every button's label is.
                    .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                    .foregroundStyle(DS.Palette.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .dsFocusRing(Capsule())
            Text("⌘Z")
                .dsStyle(.labelSmall)
                .foregroundStyle(DS.Palette.inkDisabled)
                .padding(.trailing, 6)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(Capsule().fill(DS.Palette.bg300))
        .overlay(Capsule().strokeBorder(DS.Palette.lineStrong, lineWidth: DS.hairline))
        .shadow(color: DS.Palette.shadow.opacity(0.5), radius: 20, y: 18)
        .fixedSize()
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) deleted")
        .accessibilityIdentifier("window.undo")
    }
}

#Preview("Undo") {
    UndoMessage(name: "Netflix", onUndo: {}, onHover: { _ in })
        .padding(40)
        .background(DS.Palette.bg100)
}
