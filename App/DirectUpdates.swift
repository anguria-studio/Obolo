#if OBOLO_DIRECT
import Combine
import Observation
import Sparkle
import SwiftUI

@MainActor
@Observable
final class DirectUpdates {
    static let shared = DirectUpdates()

    let controller: SPUStandardUpdaterController
    private(set) var canCheck = false
    private var automaticChecks = false

    var automaticallyChecks: Bool {
        get { automaticChecks }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    @ObservationIgnored private var availabilityObservation: AnyCancellable?
    @ObservationIgnored private var preferenceObservation: AnyCancellable?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        availabilityObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheck = $0 }
        preferenceObservation = controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticChecks = $0 }
    }
}

struct CheckForUpdatesButton: View {
    private let updates = DirectUpdates.shared

    var body: some View {
        Button("Check for Updates…") { updates.controller.checkForUpdates(nil) }
            .disabled(!updates.canCheck)
    }
}
#endif
