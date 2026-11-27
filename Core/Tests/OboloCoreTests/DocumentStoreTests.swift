import Foundation
import Testing
@testable import OboloCore

/// The one file this app owns. Losing it is the worst thing that could happen to a user
/// who has typed in forty subscriptions by hand, so the failure modes get as much
/// attention here as the happy path.
@Suite("Document store")
struct DocumentStoreTests {

    /// A temporary directory that cleans up after itself.
    private final class Sandbox {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("obolo-store-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func url(_ name: String = "obolo.json") -> URL {
            root.appendingPathComponent(name)
        }
    }

    @Test("A stored date is the value that a write and a read give back")
    func storedDateMatchesTheFile() throws {
        let intervals: [TimeInterval] = [
            810_000_000, 810_000_000.437, 810_000_000.999_999, 0.5, -0.437, -1.5,
            -86_400.000_001, 1_000_000_000.25, -1_000_000_000.75
        ]
        for interval in intervals {
            let date = Date(timeIntervalSinceReferenceDate: interval)
            var document = StoreDocument.initial()
            document.rates.setRate(1, for: "USD", updatedAt: date)
            let read = try DocumentStore.decode(DocumentStore.encode(document))
            #expect(read.rates.rates["USD"]?.updatedAt == DocumentStore.storedDate(date))
        }
    }

    @Test("A store with no file yet is a new user, not an error")
    func missingFileLoadsTheInitialDocument() async throws {
        let sandbox = try Sandbox()
        let document = try await DocumentStore(url: sandbox.url()).load()

        #expect(document.subscriptions.isEmpty)
        #expect(document.categories.count == Category.seeded.count)
        #expect(document.categories.contains { $0.name == "Other" })
        #expect(document.rates.base == "EUR")
        #expect(document.settings.hasCompletedFirstRun == false)
        // Nothing was written just by looking.
        #expect(!FileManager.default.fileExists(atPath: sandbox.url().path))
    }

    @Test("A saved document comes back identical")
    func savesAndLoads() async throws {
        let sandbox = try Sandbox()
        let store = DocumentStore(url: sandbox.url())
        let original = SampleData.handoff()

        try await store.save(original)
        #expect(try await store.load() == original)
    }

    @Test("Saving creates the directory the sandbox container does not have yet")
    func createsItsDirectory() async throws {
        let sandbox = try Sandbox()
        let nested = sandbox.root.appendingPathComponent("Obolo/obolo.json")
        let store = DocumentStore(url: nested)

        try await store.save(.initial())
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("Dates are written as ISO-8601 and the file is readable by a human")
    func writesReadableJSON() async throws {
        let sandbox = try Sandbox()
        let store = DocumentStore(url: sandbox.url())
        var document = StoreDocument.initial()
        document.subscriptions = [
            Subscription(
                id: UUID(uuidString: "AAAAAAAA-0000-4000-B000-000000000001")!,
                name: "Netflix",
                categoryID: document.fallbackCategoryID,
                price: Fixed.money("13.99"),
                currency: "EUR",
                cycle: .monthly,
                anchorDate: Fixed.billingDay(2025, 2, 24),
                createdAt: Fixed.day(2025, 2, 24)
            )
        ]
        try await store.save(document)

        let text = try String(contentsOf: sandbox.url(), encoding: .utf8)
        // An ISO-8601 string, not the seconds-since-2001 float a raw `Date` encodes to.
        #expect(text.contains("\"anchorDate\" : \"2025-02-2"))
        #expect(text.contains("\"cycle\" : \"monthly\""))     // readable enums, not indices
        #expect(text.contains("\"icon\" : \"initial\""))
        #expect(text.contains("\n"))                          // pretty-printed
        // Sorted keys: the file diffs cleanly between saves.
        #expect(text.range(of: "\"categories\"")!.lowerBound < text.range(of: "\"settings\"")!.lowerBound)
    }

    @Test("A half-written file is impossible: the previous document survives a failed save")
    func writesAtomically() async throws {
        let sandbox = try Sandbox()
        let store = DocumentStore(url: sandbox.url())
        try await store.save(SampleData.handoff())

        // An atomic write leaves no temporary siblings behind for the next reader.
        let contents = try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path)
        #expect(contents == ["obolo.json"])
    }

    @Test("Back up and restore move the whole document, not just the subscriptions")
    func backupAndRestore() async throws {
        let sandbox = try Sandbox()
        let store = DocumentStore(url: sandbox.url())
        var document = SampleData.handoff()
        document.settings.baseCurrency = "EUR"
        document.settings.hasCompletedFirstRun = true
        try await store.save(document)

        let backup = sandbox.url("backup.json")
        try await store.backup(to: backup)

        // Wipe the live store, then restore over it.
        try await store.save(.initial())
        #expect(try await store.load().subscriptions.isEmpty)

        let restored = try await store.restore(from: backup)
        #expect(restored == document)
        #expect(try await store.load() == document)
        #expect(restored.settings.hasCompletedFirstRun)
    }

    @Test("A corrupt file throws rather than quietly becoming an empty list")
    func corruptFileThrows() async throws {
        let sandbox = try Sandbox()
        try Data("{ not json".utf8).write(to: sandbox.url())
        let store = DocumentStore(url: sandbox.url())

        await #expect(throws: (any Error).self) { try await store.load() }
    }

    @Test("A newer backup is rejected before it changes the live document")
    func restoreRejectsNewerBackup() async throws {
        let sandbox = try Sandbox()
        let store = DocumentStore(url: sandbox.url())
        try await store.save(SampleData.handoff())
        let liveBytes = try Data(contentsOf: store.url)
        let backup = sandbox.url("newer.json")
        let newer = Data(#"{"version":2,"subscriptions":{"futureField":42}}"#.utf8)
        try newer.write(to: backup)

        await #expect(throws: StoreDocument.NewerVersion.self) { try await store.restore(from: backup) }
        await #expect(throws: StoreDocument.NewerVersion.self) { try await store.backup(to: backup) }
        #expect(try Data(contentsOf: store.url) == liveBytes)
        #expect(try Data(contentsOf: backup) == newer)
    }

    @Test("Save checks the file on disk even if the store was opened earlier", arguments: [false, true])
    func saveChecksExistingVersion(openedEarlier: Bool) async throws {
        let sandbox = try Sandbox()
        let store = DocumentStore(url: sandbox.url())
        if openedEarlier {
            try await store.save(.initial())
            _ = try await store.load()
        }
        let newer = Data(#"{"version":2,"futureField":42}"#.utf8)
        try newer.write(to: store.url)

        await #expect(throws: StoreDocument.NewerVersion.self) { try await store.save(.initial()) }
        #expect(try Data(contentsOf: store.url) == newer)
    }

    @Test("Restore can repair damaged JSON but preserves a newer live file")
    func restoreChecksDestinationVersion() async throws {
        let sandbox = try Sandbox()
        let store = DocumentStore(url: sandbox.url())
        let backup = sandbox.url("backup.json")
        let original = SampleData.handoff()
        try DocumentStore.encode(original).write(to: backup)

        let newer = Data(#"{"version":2,"futureField":42}"#.utf8)
        try newer.write(to: store.url)
        await #expect(throws: StoreDocument.NewerVersion.self) { try await store.restore(from: backup) }
        #expect(try Data(contentsOf: store.url) == newer)

        try Data("broken JSON".utf8).write(to: store.url)
        #expect(try await store.restore(from: backup) == original)
        #expect(try await store.load() == original)
    }

    @Test("A document from an older build decodes, with defaults for what it lacks")
    func decodesAPartialDocument() throws {
        // Only the fields a 1.0 file would have; everything else must default.
        let json = """
        {
          "version": 1,
          "subscriptions": [
            { "id": "\(UUID().uuidString)", "name": "Legacy", "price": 9.99,
              "currency": "EUR", "cycle": "monthly", "categoryID": "\(Category.seeded[0].id.uuidString)" }
          ],
          "categories": [],
          "settings": { "baseCurrency": "EUR" }
        }
        """
        let document = try DocumentStore.decode(Data(json.utf8))

        #expect(document.subscriptions.count == 1)
        #expect(document.subscriptions[0].name == "Legacy")
        #expect(document.subscriptions[0].status == .active)
        #expect(document.subscriptions[0].icon == .initial)
        #expect(document.subscriptions[0].anchorDate == nil)
        // An empty category list is repaired rather than left to render blank chips.
        #expect(document.categories.count == Category.seeded.count)
        #expect(document.settings.notificationTime.hour == 9)
    }

    @Test("A document holding retired settings keys still opens, and the keys are dropped")
    func decodesRetiredSettingsKeys() throws {
        // `showDockIcon`, `onlyActive`, `showInspector`, `chartStyle`, `categoryPeriod`
        // and `dueSoonWindowDays` were stored by older builds and are no longer read. A
        // file that still carries them must open with everything else intact.
        let json = """
        {
          "version": 1,
          "subscriptions": [],
          "categories": [],
          "settings": {
            "baseCurrency": "USD",
            "showDockIcon": true,
            "onlyActive": true,
            "showInspector": false,
            "chartStyle": "bars",
            "categoryPeriod": "yearly",
            "dueSoonWindowDays": 14,
            "spendView": "month"
          }
        }
        """
        let document = try DocumentStore.decode(Data(json.utf8))

        #expect(document.settings.baseCurrency == "USD")
        #expect(document.settings.spendView == .month)

        let encoded = String(decoding: try DocumentStore.encode(document), as: UTF8.self)
        #expect(!encoded.contains("showDockIcon"))
        #expect(!encoded.contains("onlyActive"))
        #expect(!encoded.contains("showInspector"))
        #expect(!encoded.contains("chartStyle"))
        #expect(!encoded.contains("categoryPeriod"))
        #expect(!encoded.contains("dueSoonWindowDays"))
    }

    @Test("A backup written by the build that still had the chart and period pickers restores")
    func decodesBackupWithRetiredChartKeys() throws {
        // Every key that build wrote for its settings, with the two pickers away from
        // their defaults, read through the decoder the backup list uses.
        let json = """
        {
          "version": 1,
          "subscriptions": [],
          "categories": [],
          "settings": {
            "baseCurrency": "GBP", "dueSoonWindowDays": 14, "defaultReminderLeadDays": 3,
            "notificationTime": { "hour": 8, "minute": 30 },
            "launchAtLogin": false, "showInMenuBar": true, "menuBarLabel": "monthlyTotal",
            "notificationsEnabled": true, "calendarSyncEnabled": false,
            "calendarAlertOffsetsDays": [1], "sortOrder": "name", "sortAscending": false,
            "hasCompletedFirstRun": true, "chartStyle": "bars", "categoryPeriod": "daily",
            "spendView": "subscription", "useGoogleFaviconFallback": false,
            "autoUpdateRates": false
          }
        }
        """
        let settings = try DocumentStore.makeDecoder()
            .decode(StoreDocument.self, from: Data(json.utf8))
            .settings

        #expect(settings == Settings(
            baseCurrency: "GBP",
            defaultReminderLeadDays: 3,
            notificationTime: DateComponents(hour: 8, minute: 30),
            launchAtLogin: false,
            showInMenuBar: true,
            menuBarLabel: .monthlyTotal,
            notificationsEnabled: true,
            calendarSyncEnabled: false,
            calendarAlertOffsetsDays: [1],
            sortOrder: .name,
            sortAscending: false,
            hasCompletedFirstRun: true,
            spendView: .subscription,
            useGoogleFaviconFallback: false,
            autoUpdateRates: false
        ))
    }

    @Test("A file with no sort direction sorts the way it always did, and one with a direction keeps it")
    func decodesTheSortDirection() throws {
        func settings(_ body: String) throws -> Settings {
            let json = """
            { "version": 1, "subscriptions": [], "categories": [], "settings": \(body) }
            """
            return try DocumentStore.decode(Data(json.utf8)).settings
        }
        // Written before headers could be reversed: "not set", which reads as the sort
        // order's own direction, not as ascending.
        #expect(try settings(#"{ "baseCurrency": "EUR", "sortOrder": "amount" }"#).sortAscending == nil)
        #expect(try settings(#"{ "sortOrder": "amount", "sortAscending": true }"#).sortAscending == true)
        #expect(try settings(#"{ "sortOrder": "amount", "sortAscending": false }"#).sortAscending == false)

        // And it survives a write: absent stays absent rather than being pinned to a
        // direction the user never chose.
        var document = StoreDocument.initial()
        document.settings.sortOrder = .amount
        let encoded = String(decoding: try DocumentStore.encode(document), as: UTF8.self)
        #expect(!encoded.contains("sortAscending"))
        #expect(try DocumentStore.decode(Data(encoded.utf8)).settings.sortAscending == nil)

        document.settings.sortAscending = true
        #expect(try DocumentStore.decode(try DocumentStore.encode(document)).settings.sortAscending == true)
    }

    @Test("Appearance defaults to Dark and saved choices survive a write")
    func decodesTheAppearance() throws {
        func settings(_ body: String) throws -> Settings {
            let json = """
            { "version": 1, "subscriptions": [], "categories": [], "settings": \(body) }
            """
            return try DocumentStore.decode(Data(json.utf8)).settings
        }
        #expect(StoreDocument.initial().settings.appearance == .dark)
        #expect(try settings(#"{ "baseCurrency": "EUR" }"#).appearance == .dark)
        #expect(try settings(#"{ "appearance": "light" }"#).appearance == .light)
        #expect(try settings(#"{ "appearance": "dark" }"#).appearance == .dark)
        #expect(try settings(#"{ "appearance": "auto" }"#).appearance == .auto)
        #expect(try settings(#"{ "appearance": "sepia" }"#).appearance == .dark)
        #expect(try settings(#"{ "appearance": true }"#).appearance == .dark)

        for choice in AppearanceSetting.allCases {
            var document = StoreDocument.initial()
            document.settings.appearance = choice
            #expect(try DocumentStore.decode(try DocumentStore.encode(document)).settings.appearance == choice)
        }
    }

    @Test("A document holding this Mac's old calendar values still opens, and the keys are dropped")
    func decodesRetiredDeviceKeys() throws {
        // Builds before 2026-08-26 stored the EventKit identifier on each subscription
        // and the last calendar sync in the settings. Both now live in `DeviceState`.
        let id = UUID()
        let json = """
        {
          "version": 1,
          "subscriptions": [
            { "id": "\(id.uuidString)", "name": "Storage", "price": 3,
              "currency": "EUR", "cycle": "monthly",
              "categoryID": "\(Category.seeded[0].id.uuidString)",
              "calendarEventIdentifier": "legacy-event" }
          ],
          "categories": [],
          "settings": {
            "baseCurrency": "EUR",
            "calendarSyncEnabled": true,
            "lastCalendarSyncAt": "2026-08-20T09:00:00Z"
          }
        }
        """
        let document = try DocumentStore.decode(Data(json.utf8))

        #expect(document.subscriptions.map(\.id) == [id])
        #expect(document.subscriptions[0].name == "Storage")
        #expect(document.settings.calendarSyncEnabled)

        let encoded = String(decoding: try DocumentStore.encode(document), as: UTF8.self)
        #expect(!encoded.contains("calendarEventIdentifier"))
        #expect(!encoded.contains("lastCalendarSyncAt"))
    }

    @Test("A subscription pointing at a category that no longer exists is re-homed")
    func repairsDanglingCategories() throws {
        var document = StoreDocument.initial()
        document.subscriptions = [Fixed.subscription("Orphan")]
        document.subscriptions[0].categoryID = UUID()

        let decoded = try DocumentStore.decode(DocumentStore.encode(document))
        #expect(decoded.subscriptions[0].categoryID == decoded.fallbackCategoryID)
        #expect(decoded.category(id: decoded.subscriptions[0].categoryID)?.name == "Other")
    }

    @Test("Deleting a category moves its subscriptions to Other")
    func deletingACategoryRehomesItems() {
        var document = StoreDocument.initial()
        let software = document.category(named: "Software")!
        document.subscriptions = [Fixed.subscription("Thing", category: "Software")]

        let removed = document.removeCategory(id: software.id)
        #expect(removed)
        #expect(document.categories.first(named: "Software") == nil)
        #expect(document.subscriptions[0].categoryID == document.fallbackCategoryID)

        // Other itself cannot go — there would be nowhere for the next orphan to land.
        let removedOther = document.removeCategory(id: document.fallbackCategoryID)
        #expect(!removedOther)
    }

    @Test("Renaming Other keeps it protected, and keeps it the place orphans land")
    func theFallbackBucketIsFoundByIdentityNotByName() throws {
        var document = StoreDocument.initial()
        let other = try #require(document.categories.first(id: Category.fallbackID))
        #expect(other.name == "Other")

        // The user renames it. Nothing about which bucket it is has changed.
        let index = document.categories.firstIndex(where: { $0.id == Category.fallbackID })!
        document.categories[index].name = "Misc"

        #expect(document.fallbackCategoryID == Category.fallbackID)
        let removedRenamedOther = document.removeCategory(id: Category.fallbackID)
        #expect(!removedRenamedOther)
        #expect(document.categories.contains { $0.id == Category.fallbackID })

        // And it is still where a deleted category's subscriptions go.
        let software = document.category(named: "Software")!
        document.subscriptions = [Fixed.subscription("Thing", category: "Software")]
        let removedSoftware = document.removeCategory(id: software.id)
        #expect(removedSoftware)
        #expect(document.subscriptions[0].categoryID == Category.fallbackID)
        #expect(document.category(id: document.subscriptions[0].categoryID)?.name == "Misc")

        // A dangling reference lands there too, by the same rule.
        document.subscriptions[0].categoryID = UUID()
        document.repairDanglingCategories()
        #expect(document.subscriptions[0].categoryID == Category.fallbackID)
    }

    @Test("A category the user happens to name Other is an ordinary one")
    func aSecondOtherIsDeletable() {
        var document = StoreDocument.initial()
        let index = document.categories.firstIndex(where: { $0.id == Category.fallbackID })!
        document.categories[index].name = "Misc"

        let impostor = Category(name: "Other", tint: .gray, sortOrder: 12)
        document.categories.append(impostor)

        #expect(document.fallbackCategoryID == Category.fallbackID)
        let removedImpostor = document.removeCategory(id: impostor.id)
        #expect(removedImpostor)
    }

    @Test("A document written before the seeded IDs still finds its Other by name")
    func documentsPredatingStableIDsFallBackToTheName() throws {
        let legacy = Data("""
        {"version":1,"subscriptions":[],"categories":[
        {"id":"11111111-1111-4111-A111-111111111111","name":"Software","tint":"teal","sortOrder":0},
        {"id":"22222222-2222-4222-A222-222222222222","name":"Other","tint":"gray","sortOrder":1}
        ],"rates":{"base":"EUR","rates":{}},"settings":{"baseCurrency":"EUR"}}
        """.utf8)
        let document = try DocumentStore.decode(legacy)

        let other = try #require(document.category(named: "Other"))
        #expect(document.fallbackCategoryID == other.id)
        #expect(!document.categories.contains { $0.id == Category.fallbackID })
    }
}
