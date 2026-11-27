import Foundation
import OboloCore
import Testing

/// Undo after delete, "Mark cancelled" from a row, and the backup list.
@MainActor
@Suite("Sheets and dialogs")
struct SheetsAndDialogsTests {
    private func model(names: [String]) -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OboloSheetsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        var document = StoreDocument.initial()
        for name in names {
            document.subscriptions.append(Subscription(
                name: name,
                categoryID: document.fallbackCategoryID,
                price: 9,
                currency: "EUR",
                cycle: .monthly,
                anchorDate: BillingDay(isoDate: "2026-05-28")!
            ))
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

    @Test("A second delete replaces the message; Undo brings back the second only")
    func undoIsOneAtATime() {
        let (model, directory) = model(names: ["Netflix", "Spotify", "iCloud"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let netflix = model.document.subscriptions[0]
        let spotify = model.document.subscriptions[1]

        model.delete(netflix.id)
        let firstMessage = model.undoMessageID
        #expect(model.lastDeletedName == "Netflix")

        model.delete(spotify.id)
        #expect(model.lastDeletedName == "Spotify")
        #expect(model.undoMessageID != firstMessage)

        model.undoDelete()
        #expect(model.document.subscription(id: spotify.id) == spotify)
        #expect(model.document.subscription(id: netflix.id) == nil)
        #expect(!model.canUndoDelete)
    }

    @Test("Holding the message keeps Undo open")
    func holdKeepsUndo() async throws {
        let (model, directory) = model(names: ["Netflix"])
        defer { try? FileManager.default.removeItem(at: directory) }
        model.delete(model.document.subscriptions[0].id)
        model.holdUndo(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.canUndoDelete)
        model.holdUndo(false)
        #expect(model.canUndoDelete)
    }

    @Test("Mark cancelled from a row opens the detail on the question")
    func requestCancelOpensDetail() {
        let (model, directory) = model(names: ["Netflix"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = model.document.subscriptions[0].id
        model.section = .all
        model.requestCancel(id)
        #expect(model.cancelPromptID == id)
        #expect(model.isShowingSubscriptionDetail)
        #expect(model.selectedID == id)
    }

    @Test("CSV selection updates totals and only offers categories used by selected rows")
    func importSelectionSummary() throws {
        var document = StoreDocument.initial()
        let existing = Subscription(name: "Existing plan", categoryID: document.fallbackCategoryID, price: 5, currency: "EUR", cycle: .monthly)
        document.subscriptions = [existing]
        document.rates.setRate(Decimal(string: "0.5")!, for: "USD", updatedAt: .distantPast)
        let csv = """
        ID,Name,Category,Price,Currency,Billing cycle,First payment
        ,Service 1,Mobile,12,EUR,monthly,2026-05-28
        ,Service 2,mobile,24,USD,yearly,2026-05-28
        ,Service 3,News,5,GBP,monthly,
        ,EXISTING PLAN,Music,3,EUR,monthly,2026-05-28
        \(existing.id),Renamed plan,Music,4,EUR,monthly,2026-05-28
        ,Broken plan,Music,unreadable,EUR,monthly,2026-05-28
        """
        let preview = try CSVImporter.preview(data: Data(csv.utf8), document: document, locale: Locale(identifier: "en_US"))
        let selection = ImportPreviewSelection(preview: preview, document: document)
        #expect(selection.selected == [2, 3, 4])
        #expect(selection.detailsByLine[5]?.knownSubscription?.id == existing.id)
        #expect(selection.detailsByLine[6]?.knownSubscription?.id == existing.id)
        #expect(selection.checkCount == 3)
        #expect(selection.errorCount == 1)
        #expect(selection.selectedMonthly == 13)
        #expect(selection.selectedNewCategories == ["Mobile", "News"])

        selection.setSelected(2, to: false)
        #expect(selection.selectedMonthly == 1)
        #expect(selection.selectedNewCategories == ["Mobile", "News"])
        selection.setSelected(3, to: false)
        #expect(selection.selectedMonthly == 0)
        #expect(selection.selectedNewCategories == ["News"])
        selection.setSelected(4, to: false)
        #expect(selection.selectedNewCategories.isEmpty)
        selection.setSelected(7, to: true)
        #expect(selection.selected.isEmpty)

        selection.selectAll(true)
        #expect(selection.allSelected)
        #expect(selection.selectedMonthly == 20)
        #expect(selection.selected == [2, 3, 4, 5, 6])
        #expect(selection.selectedNewCategories == preview.keeping(selection.selected).newCategoryNames)
        selection.selectAll(false)
        #expect(!selection.allSelected)
        #expect(selection.selectedMonthly == 0)
        #expect(selection.selectedNewCategories.isEmpty)

        selection.setSelected(3, to: true)
        document.rates.setRate(1, for: "USD", updatedAt: .distantPast)
        let refreshed = ImportPreviewSelection(preview: preview, document: document, selected: selection.selected)
        #expect(refreshed.selected == [3])
        #expect(refreshed.selectedMonthly == 2)

        let replacementCSV = "Name,Price\nReplacement service,8"
        let replacement = try CSVImporter.preview(data: Data(replacementCSV.utf8), document: document, locale: Locale(identifier: "en_US"))
        let replaced = ImportPreviewSelection(preview: replacement, document: document)
        #expect(replaced.selected == [2])
        #expect(replaced.selectedMonthly == 8)
    }

    @Test("The backup list reads the copies beside the store, newest first, with counts")
    func backupList() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OboloBackupList-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backups = directory.appending(path: AppPaths.cloudSyncBackupsDirectoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)

        var older = StoreDocument.initial()
        older.subscriptions = []
        var newer = StoreDocument.initial()
        newer.subscriptions = [Subscription(name: "A", categoryID: newer.fallbackCategoryID, price: 1, currency: "EUR", cycle: .monthly)]
        let olderURL = backups.appending(path: "older.json")
        let newerURL = backups.appending(path: "newer.json")
        try DocumentStore.encode(older).write(to: olderURL)
        try DocumentStore.encode(newer).write(to: newerURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: olderURL.path)
        try Data("not a backup".utf8).write(to: backups.appending(path: "notes.txt"))

        let entries = BackupLibrary.entries(besideStoreAt: directory.appending(path: "obolo.json"))
        #expect(entries.map(\.url.lastPathComponent) == ["newer.json", "older.json"])
        #expect(entries.map(\.subscriptionCount) == [1, 0])
        #expect(entries.first?.countText == "1 subscription")
    }

    @Test("The confirmation names the backup by its day")
    func backupQuestion() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = Date(timeIntervalSince1970: 1_795_600_000)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let entry = BackupEntry(url: URL(fileURLWithPath: "/tmp/x.json"), date: yesterday, subscriptionCount: 3)
        #expect(entry.question(now: now, calendar: calendar).hasPrefix("Restore the backup from yesterday at "))
        let chosen = BackupEntry(url: URL(fileURLWithPath: "/tmp/Obolo 2026.json"), date: now, subscriptionCount: nil, isChosenFile: true)
        #expect(chosen.question(now: now, calendar: calendar) == "Restore “Obolo 2026.json”?")
    }
}
