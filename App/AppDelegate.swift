import AppKit
import SwiftUI

/// Keeps the app out of the Dock and ⌘-Tab while it is only a status item.
///
/// AppKit's activation policy decides that: `.regular` apps have a Dock icon and a
/// ⌘-Tab entry, `.accessory` apps have neither but keep their menu bar extra. The
/// policy follows the windows. A login launch starts `.accessory`; the first real
/// window to become main — opened from the menu bar item, a Finder relaunch, or Settings —
/// promotes the app to `.regular`; closing the last such window demotes it again, so
/// no Dock icon lingers with nothing behind it.
///
/// The launch Apple event names the reason for the launch, so a Finder or Dock launch,
/// which carries no login flag, keeps its window and its Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Run before the app quits, so the 250 ms debounced save is not the edit the user
    /// loses. Assigned in `OboloApp.init`, which runs however the app was started, a
    /// login launch with no window included; a `nil` hook means there is nothing to
    /// flush. Static so that assignment does not depend on whether
    /// `@NSApplicationDelegateAdaptor` has built this instance yet.
    static var flushBeforeTerminate: (@MainActor () async -> Void)?

    /// True while a login launch is still settling: SwiftUI can present the restored
    /// window just after `applicationDidFinishLaunching`, and without this the window
    /// observer would promote the app straight back to the Dock.
    private var isSettlingLoginLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeWindows()
        if Self.launchedAsLoginItem {
            isSettlingLoginLaunch = true
            Self.setPolicy(.accessory)
            closeMainWindows()
            // Sweep once more on the next runloop turn for the late-presented window.
            DispatchQueue.main.async {
                self.closeMainWindows()
                self.isSettlingLoginLaunch = false
            }
        } else {
            MainWindowPresenter.activateAfterLaunch()
        }
        #if OBOLO_DIRECT
        DirectUpdates.shared.controller.startUpdater()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `applicationWillTerminate` is too late to await anything — the process is gone
    /// before a task runs. `terminateLater` is the AppKit way to say "one moment": the
    /// quit waits for `reply(toApplicationShouldTerminate:)`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let flush = Self.flushBeforeTerminate else { return .terminateNow }
        Task {
            await flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Policy follows the windows

    private func observeWindows() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
    }

    /// A real window is on screen: make sure the app has a Dock icon to go with it.
    @objc private func windowDidBecomeMain(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        if isSettlingLoginLaunch {
            // The restored window arriving late on a login launch: not a request to
            // open the app, so close it rather than promote for it.
            window.close()
            return
        }
        guard NSApp.activationPolicy() != .regular else { return }
        Self.setPolicy(.regular)
        // The policy flip re-registers the app with the window server, which can drop
        // key focus from the window that triggered it. Reassert it next turn.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The last real window is closing: return to the menu bar.
    ///
    /// Checked on the next turn, because at `willClose` the window is still visible.
    /// This applies however the app was launched: a Dock icon with no window behind it
    /// is exactly the state this delegate exists to avoid.
    @objc private func windowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow else { return }
        DispatchQueue.main.async {
            let remaining = NSApp.windows.filter {
                $0 !== closing && $0.canBecomeMain && $0.isVisible
            }
            guard remaining.isEmpty, NSApp.activationPolicy() == .regular else { return }
            Self.setPolicy(.accessory)
            // An accessory app with no windows has nothing to be active for; hiding
            // hands focus to the next app the way ⌘H would. The status item is
            // unaffected, and `activate` unhides.
            NSApp.hide(nil)
        }
    }

    static func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
    }

    // MARK: - Login launch

    /// Only windows that can become main: the status item's own window and panels must
    /// survive, or the menu bar item dies with the launch.
    private func closeMainWindows() {
        for window in NSApp.windows where window.canBecomeMain && window.isVisible {
            window.close()
        }
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return false
        }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }
}
