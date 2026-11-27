import Foundation
import OboloCore

/// The words of "Delete <name>?", asked in place: in the detail's ⋮ popover and in the
/// Edit sheet's last card. Each place draws the question in its own layout; only the
/// text is shared, so the two always say the same thing.
enum DeletePrompt {
    /// "Delete Claude Max?", or "Delete subscription?" without a name.
    static func title(name: String?) -> String {
        "Delete \(name ?? "subscription")?"
    }

    /// What goes with the subscription: its payments so far and their total, and the
    /// way to keep them.
    @MainActor
    static func message(for id: Subscription.ID?, model: AppModel) -> String {
        guard let id, let paid = model.summary(id)?.paidSoFar, paid.count > 0 else {
            return "To keep its history, mark it as cancelled instead."
        }
        let total = paid.totalsByCurrency
            .sorted { $0.key < $1.key }
            .map { MoneyFormatting.amount($0.value, currency: $0.key) }
            .joined(separator: " + ")
        let noun = paid.count == 1 ? "payment" : "payments"
        return "This also removes \(paid.count) \(noun) of history (\(total)). To keep the history, mark it as cancelled instead."
    }
}
