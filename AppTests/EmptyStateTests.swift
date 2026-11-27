import Foundation
import OboloCore
import Testing

/// The empty Home and All, and first run without a first-run window.
@MainActor
@Suite("Empty state and first run")
struct EmptyStateTests {
    private func model(_ document: StoreDocument, autoload: Bool = false) -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OboloEmptyStateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let model = AppModel(
            store: DocumentStore(url: directory.appending(path: "obolo.json")),
            deviceStateStore: DeviceStateStore(url: directory.appending(path: DeviceStateStore.fileName)),
            document: document,
            cloudSyncService: DisabledCloudSyncService(),
            autoload: autoload
        )
        return (model, directory)
    }

    private func subscription(in document: StoreDocument) -> Subscription {
        Subscription(
            name: "Fitness",
            categoryID: document.fallbackCategoryID,
            price: 9,
            currency: "EUR",
            cycle: .monthly,
            anchorDate: BillingDay(isoDate: "2026-05-28")!
        )
    }

    @Test("A handed-in document with nothing in it is empty; one subscription is not")
    func emptyPredicate() {
        let document = StoreDocument.initial()
        let (model, directory) = model(document)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(model.hasNoSubscriptions)

        model.add(subscription(in: document))
        #expect(!model.hasNoSubscriptions)
    }

    @Test("Before the disk has answered, the list is not called empty")
    func notEmptyBeforeLoad() {
        let (model, directory) = model(.initial(), autoload: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Synchronously after init the load has not run yet.
        #expect(!model.isLoaded)
        #expect(!model.hasNoSubscriptions)
    }

    @Test("The first subscription completes first run, in the same change")
    func firstAddCompletesFirstRun() {
        let document = StoreDocument.initial()
        #expect(!document.settings.hasCompletedFirstRun)
        let (model, directory) = model(document)
        defer { try? FileManager.default.removeItem(at: directory) }

        model.add(subscription(in: document))
        #expect(model.document.settings.hasCompletedFirstRun)
        #expect(model.settings.hasCompletedFirstRun)
    }

    @Test("The reminders step names the default lead time from Settings")
    func reminderStepFollowsSetting() {
        #expect(EmptyHomeView.reminderStepDetail(leadDays: 0) == "Mac notifications, on the day by default.")
        #expect(EmptyHomeView.reminderStepDetail(leadDays: 1) == "Mac notifications, 1 day before by default.")
        #expect(EmptyHomeView.reminderStepDetail(leadDays: 2) == "Mac notifications, 2 days before by default.")
        #expect(EmptyHomeView.reminderStepDetail(leadDays: 7) == "Mac notifications, 1 week before by default.")
        #expect(
            EmptyHomeView.reminderStepDetail(leadDays: StoreDocument.initial().settings.defaultReminderLeadDays)
                == "Mac notifications, 2 days before by default."
        )
    }
}
