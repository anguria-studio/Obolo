import Foundation
import OboloCore
import Testing

/// The one-time pass that fetches dark versions for logos saved before there were any.
/// Only the cases that open no connection: who is skipped, and the flag.
@MainActor
@Suite("Dark logo catch-up")
struct DarkLogoCatchUpTests {
    private func model(icons: [Icon]) -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OboloDarkLogoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        var document = StoreDocument.initial()
        for (index, icon) in icons.enumerated() {
            var subscription = Subscription(
                name: "Service \(index)",
                categoryID: document.fallbackCategoryID,
                price: 5,
                currency: "EUR",
                cycle: .monthly,
                anchorDate: BillingDay(isoDate: "2026-05-28")!
            )
            subscription.icon = icon
            subscription.website = "example.com"
            document.subscriptions.append(subscription)
        }
        let model = AppModel(
            store: DocumentStore(url: directory.appending(path: "obolo.json")),
            deviceStateStore: DeviceStateStore(url: directory.appending(path: DeviceStateStore.fileName)),
            document: document,
            cloudSyncService: DisabledCloudSyncService(),
            autoload: false
        )
        return (model, directory)
    }

    private func defaults() -> (UserDefaults, String) {
        let suite = "OboloDarkLogoTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("Letters, emoji and logo files that are not on disk are skipped, and the pass is marked done")
    func skipsWhatHasNoLogo() async {
        let (model, directory) = model(icons: [.initial, .emoji("🎵"), .image("\(UUID().uuidString).png")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        await model.fetchDarkLogosOnce(defaults: defaults)
        #expect(defaults.bool(forKey: AppModel.darkLogoCatchUpKey))
    }

    @Test("Once marked done it does not run again")
    func runsOnce() async {
        let (model, directory) = model(icons: [])
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppModel.darkLogoCatchUpKey)

        await model.fetchDarkLogosOnce(defaults: defaults)
        #expect(defaults.bool(forKey: AppModel.darkLogoCatchUpKey))
    }
}
