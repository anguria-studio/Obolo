import SwiftUI
import OboloCore

/// Preferences → General: logo lookup, startup and menu bar behavior.
struct GeneralPane: View {

    @Bindable var settings: SettingsStore
    var model: AppModel
    @State private var logoMessage: String?


    var body: some View {
        PrefPage(tab: .general) {
            appearance
            logos
            startup
        }
    }

    // MARK: - Appearance

    private var appearance: some View {
        PrefSection("Appearance") {
            PrefRow("Theme", "Dynamic follows macOS.") {
                PrefPicker(
                    selection: $settings.appearance,
                    options: AppearanceSetting.allCases.map { ($0, $0.displayName) },
                    accessibilityLabel: "Theme"
                )
            }
        }
    }

    // MARK: - Logos

    private var logos: some View {
        PrefSection("Logos") {
            PrefRow(logoTitle, logoDescription) {
                Button(model.isFetchingLogos ? "Fetching" : "Fetch logos") { fetchLogos() }
                    .prefButton()
                    .disabled(model.isFetchingLogos || model.missingLogoCount == 0)
            }
            PrefToggleRow(
                "Look up missing logos with Google",
                "If a website’s icon is missing or too small, Obolo sends its domain to Google to look for a better copy.",
                isOn: $settings.useGoogleFaviconFallback
            )
        } footer: {
            if let logoMessage { PrefFootnote(logoMessage) }
        }
    }

    private var logoTitle: String {
        guard let progress = model.logoFetchProgress else {
            let missing = model.missingLogoCount
            switch missing {
            case 0: return "Every subscription has a logo"
            case 1: return "1 subscription has no logo"
            default: return "\(missing) subscriptions have no logo"
            }
        }
        return "Fetching \(progress.done) of \(progress.total)"
    }

    private var logoDescription: String {
        model.missingLogoCount == 0 && model.logoFetchProgress == nil
            ? "Nothing to look up. A subscription needs a website before Obolo can find its logo."
            : "Obolo looks for a sharp icon on each subscription’s website."
    }

    private func fetchLogos() {
        logoMessage = nil
        Task {
            let result = await model.fetchMissingLogos()
            let fetched = result.fetched == 1 ? "1 logo" : "\(result.fetched) logos"
            let failed = result.failed == 1 ? "1 subscription" : "\(result.failed) subscriptions"
            logoMessage = result.failed == 0
                ? "Obolo fetched \(fetched)."
                : "Obolo fetched \(fetched). It found no logo for \(failed)."
        }
    }

    // MARK: - Startup and menu bar

    private var startup: some View {
        PrefSection("Startup & menu bar") {
            PrefToggleRow("Open at login", "Obolo runs in the background when you log in.", isOn: $settings.launchAtLogin)
            PrefToggleRow("Show in menu bar", "A status item next to the clock.", isOn: $settings.showInMenuBar)
            // Only while there is a menu bar item to word.
            if settings.showInMenuBar {
                PrefRow("Menu bar shows") {
                    PrefPicker(
                        selection: $settings.menuBarLabel,
                        options: MenuBarLabelStyle.allCases.map { ($0, $0.displayName) },
                        accessibilityLabel: "Menu bar shows"
                    )
                }
            }
        } footer: {
            // Only when the system and the switch disagree. The switch keeps saying what
            // the system does, not what the user asked for: macOS is either holding the
            // request for approval, has refused it, or has refused to let go of a login
            // item the user just turned off. Every one of them ends in the same place.
            if let attention = settings.loginItemAttention {
                PrefFootnote(attention.message, isError: true)
                    .accessibilityIdentifier("general.loginItemWarning")
            }
        }
    }
}

// MARK: - Preview

#Preview("General") {
    GeneralPane(settings: .preview(), model: .handoffPreview())
        .frame(width: PrefMetrics.width, height: 520)
}
