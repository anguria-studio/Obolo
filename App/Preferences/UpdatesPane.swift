#if OBOLO_DIRECT
import SwiftUI

struct UpdatesPane: View {
    @Bindable private var updates = DirectUpdates.shared

    var body: some View {
        PrefPage(tab: .updates) {
            PrefSection {
                PrefToggleRow(
                    "Check for updates automatically",
                    "Obolo checks GitHub for new versions and asks before installing.",
                    isOn: $updates.automaticallyChecks
                )
                PrefRow("Check for updates") {
                    Button("Check Now") { updates.controller.checkForUpdates(nil) }
                        .prefButton()
                        .disabled(!updates.canCheck)
                }
            }
        }
    }
}
#endif
