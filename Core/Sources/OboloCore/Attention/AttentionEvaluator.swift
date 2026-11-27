import Foundation

/// Picks the one `Attention` a subscription gets.
///
/// The priority order below is the whole of this type, so it is worth stating why it
/// runs the way it does:
///
/// 1. **Not billing → nothing to warn about.** A paused or cancelled item is already
///    out of the totals and already dimmed. Flagging it as an estimate would park it in
///    Needs attention forever with no useful fix. Cancelled keeps its end date because
///    the row has to render "ends 5 Sep".
/// 2. **Missing rate first**, because it is the only state that makes the *totals*
///    wrong, and the app promised the totals are honest.
/// 3. **Trial before due-soon**, because "trial converts in 3 days" is the surprise —
///    "renews in 3 days" is not, for something the user is already paying for.
/// 4. **No date before due-anything**, because there is no date to be due on.
/// 5. **Estimate last of the real states**, because it is chronic rather than urgent:
///    a due-soon estimate should say "due soon".
public enum AttentionEvaluator {

    public static func evaluate(
        subscription: Subscription,
        nextPayment: Date?,
        hasRate: Bool,
        dueSoonWindowDays: Int,
        today: Date,
        calendar: Calendar
    ) -> Attention {
        switch subscription.status {
        case .cancelled:
            return subscription.endsOn.map { .endsOn($0.startOfDay(in: calendar)) } ?? .none
        case .paused:
            return .none
        case .active, .trial:
            break
        }

        guard hasRate else { return .missingRate }

        if subscription.status == .trial, let endsOn = subscription.endsOn {
            return .trialEnds(endsOn.startOfDay(in: calendar))
        }
        guard subscription.anchorDate != nil, let nextPayment else { return .noDate }

        let days = RenewalSchedule.daysUntil(nextPayment, today: today, calendar: calendar)
        if days == 0 { return .dueToday }
        if days > 0 && days <= dueSoonWindowDays { return .dueSoon }

        if subscription.isEstimate { return .estimate }
        if let endsOn = subscription.endsOn { return .endsOn(endsOn.startOfDay(in: calendar)) }
        return .none
    }
}
