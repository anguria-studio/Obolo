import AppKit
import UserNotifications

/// What happens when a reminder is shown, and when it is clicked.
///
/// A delegate, not a view, so it has no `@Environment(\.openWindow)` to open anything
/// with. A click therefore goes the way the status item's does, which needs no scene:
/// `MainWindowPresenter.open` with a `.subscription` route. The route waits in
/// `OboloIntentRouter`, in memory, until the main window exists and the document is
/// loaded, so a click with the window closed, or the click that launched the app,
/// still opens the subscription. It never travels as a link: the app's URL scheme has
/// no way to name a subscription.
///
/// Deliberately **not** `@MainActor`. `UNUserNotificationCenter` calls its delegate
/// from its own queue and hands over `UNNotification` / `UNNotificationResponse`,
/// neither of which is `Sendable`; isolating this type to the main actor would make
/// every one of those parameters an actor-boundary crossing the compiler is right to
/// reject. So the callbacks stay where the framework put them, turn the response into
/// a `Sendable` route, and hop to the main actor with that.
///
/// Set as the notification centre's delegate in `OboloApp.init`, which is early
/// enough: the delegate must be in place before the app finishes launching, or a
/// notification that launched the app is delivered to nobody.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    /// Show the banner even when Obolo is frontmost.
    ///
    /// The default is to swallow it, on the reasoning that a foreground app can say
    /// this itself. Obolo cannot: being frontmost says nothing about whether the
    /// window shows that payment, and a reminder that renders as nothing is a
    /// reminder that did not happen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard
            let route = Self.route(
                actionIdentifier: response.actionIdentifier,
                userInfo: response.notification.request.content.userInfo
            )
        else { return }

        await MainActor.run {
            MainWindowPresenter.open(route)
        }
    }

    /// The route a response asks for: the subscription that `NotificationScheduler`
    /// wrote into the reminder's `userInfo`. Only the notification itself, not a
    /// dismissal or a custom action, and nothing for a reminder with no readable ID.
    nonisolated static func route(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> OboloIntentRoute? {
        guard
            actionIdentifier == UNNotificationDefaultActionIdentifier,
            let raw = userInfo["subscriptionID"] as? String,
            let id = UUID(uuidString: raw)
        else { return nil }
        return .subscription(id)
    }
}
