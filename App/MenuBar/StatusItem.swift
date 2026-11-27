import AppKit
import Observation
import OboloCore

/// The menu bar item: the glyph, and per Settings › General › "Menu bar shows" the
/// monthly total ("129 €") or the next payment ("Spotify · today") beside it.
///
/// A left click opens the main window on Home
/// (bringing it forward, or out of the Dock, or creating it when the app runs with no
/// window); a right click or a Control-click shows a plain menu: Add subscription…,
/// Settings…, Quit Obolo.
///
/// An AppKit status item rather than SwiftUI's `MenuBarExtra`, which can only open its
/// own content on a click and has no right-click menu.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var model: AppModel?
    private var item: NSStatusItem?

    /// Starts showing the item, following "Show in menu bar" and the label setting from
    /// then on.
    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        update()
    }

    // MARK: Keeping up with the settings

    private func update() {
        guard let model else { return }
        withObservationTracking {
            render(model)
        } onChange: { [weak self] in
            // After the change has landed; then watch again.
            DispatchQueue.main.async { self?.update() }
        }
    }

    private func render(_ model: AppModel) {
        // The initial document enables the item before the saved preference is known.
        guard model.isLoaded else { return }
        guard model.settings.showInMenuBar else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? makeItem()
        self.item = item
        guard let button = item.button else { return }

        let state = model.ledger.menuBarLabel(style: model.document.settings.menuBarLabel)
        button.image = Self.glyph
        button.imagePosition = state.title == nil ? .imageOnly : .imageLeading
        // About 5pt between the glyph and the words: a leading space in the menu bar's
        // own font.
        button.title = state.title.map { " " + $0 } ?? ""
        button.font = NSFont.menuBarFont(ofSize: 0)
        // Dimmed only when nothing is tracked.
        button.appearsDisabled = state.isDimmed
        button.setAccessibilityLabel(state.title.map { "Obolo, \($0)" } ?? "Obolo")
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Obolo"
        }
        return item
    }

    /// The menu-bar template: macOS tints it with the menu bar.
    private static let glyph: NSImage? = {
        let image = NSImage(resource: .menuBarIcon)
        image.isTemplate = true
        return image
    }()

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let wantsMenu = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if wantsMenu {
            showMenu(from: sender)
        } else {
            MainWindowPresenter.open(.home)
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Add subscription", action: #selector(addSubscription), keyEquivalent: "").target = self
        let settings = menu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Obolo", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        // Shown under the item, then let go, so the next left click opens the window
        // again instead of this menu.
        guard let item else { return }
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    @objc private func addSubscription() {
        MainWindowPresenter.open(.addSubscription(SubscriptionFormPrefill()))
    }

    @objc private func openSettings() {
        AppDelegate.setPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // The app menu's own Settings… item: it opens the SwiftUI Settings scene the
        // way ⌘, does.
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let index = appMenu.items.firstIndex(where: {
               $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
           }) {
            appMenu.performActionForItem(at: index)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
