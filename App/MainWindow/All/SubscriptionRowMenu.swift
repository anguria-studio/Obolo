import AppKit
import SwiftUI
import OboloCore

/// A subscription's actions: the right-click menu on a row in All.
struct SubscriptionRowMenu: View {
    let model: AppModel
    let id: Subscription.ID

    var body: some View {
        if let subscription = model.subscription(id) {
            Button("Edit") { model.presentEdit(id) }
            Button("Duplicate") { model.presentDuplicate(id) }

            Divider()

            // Cancelling preserves the payment history. Reactivate resumes billing.
            if subscription.status == .cancelled || subscription.status == .paused {
                Button("Reactivate") { model.setStatus(.active, for: id) }
            } else {
                Button("Mark cancelled") { model.requestCancel(id) }
            }

            Divider()

            Button("Open manage page") {
                if let url = subscription.manageURL { NSWorkspace.shared.open(url) }
            }
            .disabled(subscription.manageURL == nil)

            Divider()

            Button("Delete", role: .destructive) { model.pendingDelete = id }
        }
    }
}
