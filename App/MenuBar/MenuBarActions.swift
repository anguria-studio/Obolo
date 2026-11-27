import AppKit
import SwiftUI
import OboloCore

// MARK: - Scene identifiers

/// The `id:` strings the scenes in `OboloApp` are declared with, in one place so a
/// caller and a scene declaration cannot drift apart.
enum OboloWindow {
    static let main = "main"
}

extension Notification.Name {
    /// The app posts this notification when an App Intent requests a view.
    static let oboloOpenIntentRoute = Notification.Name("obolo.openIntentRoute")
}

// MARK: - Opening the main window

/// Opens the single main window or moves its existing instance to the front.
@MainActor
enum MainWindowPresenter {
    private static var activationRequested = false

    /// Opens the main window on `route`'s destination, for a caller with no scene and so
    /// no `openWindow`: the status item and a clicked reminder.
    ///
    /// The route always goes to `OboloIntentRouter`, in memory, and waits there until
    /// the window has the loaded document, so one that arrives during launch is not
    /// lost. A window that is around takes it at once. With none (it was closed, a
    /// menu-bar-only launch, or a launch whose window is not built yet), the app also
    /// opens `OboloIntentLink.window`, which carries nothing and only makes SwiftUI
    /// create the main window (the scene handles "intent" links); that window takes the
    /// route when it appears. The route itself never becomes a link, so nothing outside
    /// the process can ask for a subscription's detail. The link is opened with this
    /// very app, not whichever app claims the scheme, so a second copy never answers it.
    static func open(_ route: OboloIntentRoute) {
        AppDelegate.setPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        OboloIntentRouter.shared.request(route)
        // After the route is queued, never before: the window the link builds takes
        // whatever is waiting as it appears, and there is nothing in the link to take.
        if let link = windowLink(hasMainWindow: hasMainWindow) {
            NSWorkspace.shared.open(
                [link],
                withApplicationAt: Bundle.main.bundleURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    /// The link `open(_:)` sends after queueing a route: none when a main window is
    /// there to take the route, and otherwise the one that only builds the window.
    nonisolated static func windowLink(hasMainWindow: Bool) -> URL? {
        hasMainWindow ? nil : OboloIntentLink.window
    }

    static func present(openWindow: () -> Void) {
        activationRequested = true
        AppDelegate.setPolicy(.regular)
        NSApp.unhide(nil)

        if let window = mainWindow {
            focusRepeatedly(window)
            return
        }

        openWindow()
        DispatchQueue.main.async {
            guard let window = mainWindow else { return }
            focusRepeatedly(window)
        }
    }

    /// Activates a normal Finder, Dock, or Xcode launch after SwiftUI creates its window.
    static func activateAfterLaunch() {
        activationRequested = true
        AppDelegate.setPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let window = mainWindow {
            focusRepeatedly(window)
        }
    }

    static func windowDidAttach(_ window: NSWindow) {
        guard activationRequested else { return }
        focusRepeatedly(window)
    }

    /// Whether the main window is open: on screen or in the Dock. A closed window can
    /// linger in `NSApp.windows` with no view behind it to answer a route.
    static var hasMainWindow: Bool {
        guard let window = mainWindow else { return false }
        return window.isVisible || window.isMiniaturized
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier == MainWindowIdentityView.identifier }
    }

    private static func focusRepeatedly(_ window: NSWindow) {
        focus(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focus(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard window.isVisible || window.isMiniaturized else { return }
            focus(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard window.isVisible || window.isMiniaturized else {
                activationRequested = false
                return
            }
            focus(window)
            activationRequested = false
        }
    }

    private static func focus(_ window: NSWindow) {
        NSApp.unhide(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Assigns an identifier that does not depend on SwiftUI's scene implementation.
struct MainWindowIdentityView: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("Obolo.mainWindow")

    func makeNSView(context: Context) -> NSView {
        IdentityView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class IdentityView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.identifier = MainWindowIdentityView.identifier
            MainWindowPresenter.windowDidAttach(window)
        }
    }
}

/// Routes every request through `MainWindowPresenter` and applies its destination.
@MainActor
struct OpenMainWindow {
    let model: AppModel
    let openWindow: OpenWindowAction

    /// Opens the window, optionally moving to a section and selecting a row.
    func callAsFunction(section: OboloCore.Section? = nil, selecting id: Subscription.ID? = nil) {
        perform {
            if let section { model.section = section }
            if let id { reveal(id) }
        }
    }

    private func perform(_ action: @MainActor () -> Void) {
        MainWindowPresenter.present {
            openWindow(id: OboloWindow.main)
        }
        action()
    }

    /// Selects a row and makes sure it is somewhere the user can see it.
    ///
    /// Selecting a subscription the current section filters out would open the
    /// Detail on a row that is not in the list behind it — so a section that does not
    /// contain the row gives way to one that does. Home and Calendar also give way:
    /// their main content is not the subscription list even though their ledger scope
    /// contains every subscription.
    private func reveal(_ id: Subscription.ID) {
        if model.section == .overview
            || model.section == .calendar
            || !model.rows.contains(where: { $0.id == id }) {
            let isBilling = model.subscription(id)?.status.isBilling ?? true
            model.section = isBilling ? .all : .pausedCancelled
        }
        // After `section`, never before: assigning a section drops a selection that is
        // no longer on screen.
        model.selectSubscriptionRow(id)
    }
}
