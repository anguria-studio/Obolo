import SwiftUI
import OboloCore

/// Confirms cancellation inside the detail actions menu or the last card of the Edit sheet.
///
/// The one question is when access ends: the next payment date by default (that payment
/// will not be charged), today, or any day from the picker. The subscription stays in
/// the list with its history and counts until then.
struct CancelPrompt: View {
    let name: String
    @Binding var endDate: BillingDay
    let today: Date
    let calendar: Calendar
    let onKeep: () -> Void
    let onConfirm: () -> Void

    private var endsToday: Bool {
        endDate <= BillingDay(today, calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Mark \(name) as cancelled?")
                .font(DSFonts.font(DSFonts.sansMedium, size: 15))
                .foregroundStyle(DS.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("It stays in your list with its history, and counts until access ends.")
                .dsStyle(.bodySmall)
                .foregroundStyle(DS.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: 10) {
                Text("Access ends")
                    .dsLabel()
                    .frame(maxWidth: .infinity, alignment: .leading)
                DatePill(date: $endDate, today: today, calendar: calendar)
                    .fixedSize()
            }
            .padding(.top, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(DS.Palette.lineStrong).frame(height: DS.hairline)
            }
            .padding(.top, 12)

            Text(endsToday ? "Moves to Inactive now." : "Moves to Inactive after that day.")
                .font(DSFonts.font(DSFonts.sansRegular, size: 12))
                .foregroundStyle(DS.Palette.inkDisabled)
                .padding(.top, 6)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Keep", action: onKeep)
                    .buttonStyle(DSSecondaryButtonStyle(height: 30, mono: true))
                    .dsFocusRing(Capsule())
                    .keyboardShortcut(.cancelAction)
                Button("Mark cancelled", action: onConfirm)
                    .buttonStyle(DSPrimaryButtonStyle(height: 30, mono: true))
                    .dsFocusRing(Capsule())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        // The popover panel pads it (12pt), like the date picker.
        .accessibilityElement(children: .contain)
    }

    /// Where access ends by default: the next payment, which will not be charged, or
    /// today when there is none.
    static func defaultEnd(for id: Subscription.ID, model: AppModel) -> BillingDay {
        let today = BillingDay(model.today, calendar: model.calendar)
        guard let next = model.summary(id)?.nextPayment else { return today }
        return max(today, BillingDay(next, calendar: model.calendar))
    }
}

#Preview("Cancel prompt") {
    @Previewable @State var end = BillingDay(Calendar.current.date(byAdding: .day, value: 8, to: .now)!, calendar: .current)
    CancelPrompt(name: "Claude Max", endDate: $end, today: .now, calendar: .current, onKeep: {}, onConfirm: {})
        .padding(6)
        .frame(width: 268)
        .background(DS.Palette.bg300)
}
