import Foundation
import Testing
@testable import OboloCore

struct SyncedDocumentTests {
    @Test("An unknown menu bar label style reads as Icon only")
    func unknownMenuBarLabel() throws {
        let unknown = try JSONDecoder().decode(Settings.self, from: Data(#"{"menuBarLabel":"popoverTotals"}"#.utf8))
        #expect(unknown.menuBarLabel == .iconOnly)
        let known = try JSONDecoder().decode(Settings.self, from: Data(#"{"menuBarLabel":"nextRenewal"}"#.utf8))
        #expect(known.menuBarLabel == .nextRenewal)
    }

    @Test func projectionKeepsUserData() throws {
        let category = Category(
            id: UUID(uuidString: "A0000000-0000-4000-A000-000000000001")!,
            name: "Work",
            tint: .violet,
            sortOrder: 3
        )
        let subscriptionID = UUID(uuidString: "B0000000-0000-4000-A000-000000000001")!
        let iconName = "B0000000-0000-4000-A000-000000000001.png"
        let historyDate = Date(timeIntervalSince1970: 1_700_000_000)
        let historyDay = Fixed.billingDay(2023, 11, 14)
        let currentDay = Fixed.billingDay(2024, 3, 9)
        let subscription = Subscription(
            id: subscriptionID,
            name: "Example",
            icon: .image(iconName),
            tint: .cyan,
            categoryID: category.id,
            price: 12.50,
            currency: "USD",
            priceChanges: [PriceChange(effectiveFrom: historyDay, price: 10, currency: "USD")],
            currentPriceSince: currentDay,
            cycle: .custom(months: 5),
            anchorDate: historyDay,
            status: .trial,
            billingStoppedOn: nil,
            endsOn: currentDay,
            isEstimate: true,
            reminderLeadDays: 7,
            paymentMethod: "Card",
            manageURL: URL(string: "https://example.com/account"),
            website: "example.com",
            notes: "Team plan",
            createdAt: historyDate
        )
        let manualDate = Date(timeIntervalSince1970: 1_720_000_000)
        let document = StoreDocument(
            subscriptions: [subscription],
            categories: [category],
            rates: RateTable(
                base: "EUR",
                rates: ["USD": Rate(value: 0.91, updatedAt: manualDate, source: .manual)]
            ),
            settings: Settings(
                baseCurrency: "EUR",
                defaultReminderLeadDays: 3
            )
        )

        let projection = SyncedDocument(document: document)
        let decoded = try JSONDecoder().decode(
            SyncedDocument.self,
            from: JSONEncoder().encode(projection)
        )

        #expect(decoded == projection)
        #expect(decoded.schemaVersion == SyncedDocument.currentSchemaVersion)
        #expect(decoded.categories == [category])
        #expect(decoded.preferences == SyncedPreferences(
            baseCurrency: "EUR",
            defaultReminderLeadDays: 3
        ))
        #expect(decoded.manualRates["USD"] == SyncedManualRate(value: 0.91, updatedAt: manualDate))
        #expect(decoded.subscriptions.count == 1)
        #expect(decoded.subscriptions[0].subscription == subscription)
        #expect(decoded.subscriptions[0].icon == .image(iconName))
    }

    @Test("A projection holds each date as the store file keeps it")
    func projectionUsesTheStoredDatePrecision() throws {
        let instant = Date(timeIntervalSinceReferenceDate: 810_000_000.437)
        let subscription = Subscription(
            name: "Created this session",
            categoryID: Category.fallbackID,
            price: 12,
            currency: "EUR",
            priceChanges: [PriceChange(effectiveFrom: Fixed.billingDay(2026, 7, 1), price: 10, currency: "EUR")],
            currentPriceSince: Fixed.billingDay(2026, 8, 1),
            cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 7, 1),
            status: .cancelled,
            billingStoppedOn: Fixed.billingDay(2026, 8, 3),
            endsOn: Fixed.billingDay(2026, 9, 1),
            createdAt: instant
        )
        let inMemory = StoreDocument(
            subscriptions: [subscription],
            rates: RateTable(
                base: "EUR",
                rates: ["USD": Rate(value: 0.9, updatedAt: instant.addingTimeInterval(0.6), source: .manual)]
            )
        )

        // What the next launch reads: the store file has no fractions of a second.
        let reloaded = try DocumentStore.decode(DocumentStore.encode(inMemory))
        #expect(reloaded != inMemory)

        #expect(SyncedDocument(document: inMemory) == SyncedDocument(document: reloaded))
    }

    @Test func projectionExcludesDeviceDataAndAutomaticRates() throws {
        let markerDate = Date(timeIntervalSince1970: 1_730_000_000)
        let subscription = Subscription(
            name: "Private local state",
            categoryID: Category.fallbackID,
            price: 9,
            currency: "GBP",
            cycle: .monthly
        )
        let settings = Settings(
            baseCurrency: "EUR",
            defaultReminderLeadDays: 4,
            notificationTime: DateComponents(hour: 6, minute: 37),
            launchAtLogin: false,
            showInMenuBar: false,
            menuBarLabel: .monthlyTotal,
            notificationsEnabled: false,
            calendarSyncEnabled: true,
            calendarIdentifier: "calendar-marker",
            calendarAlertOffsetsDays: [8],
            sortOrder: .amount,
            sortAscending: true,
            hasCompletedFirstRun: true,
            spendView: .month,
            useGoogleFaviconFallback: false,
            autoUpdateRates: false
        )
        let document = StoreDocument(
            subscriptions: [subscription],
            rates: RateTable(
                base: "EUR",
                rates: [
                    "USD": Rate(value: 0.9, updatedAt: markerDate, source: .manual),
                    "GBP": Rate(value: 1.1, updatedAt: markerDate, source: .automatic)
                ],
                automaticAsOf: markerDate,
                lastCheckedAt: markerDate
            ),
            settings: settings
        )

        let data = try JSONEncoder().encode(SyncedDocument(document: document))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let subscriptionJSON = try #require((json["subscriptions"] as? [[String: Any]])?.first)
        let preferencesJSON = try #require(json["preferences"] as? [String: Any])
        let ratesJSON = try #require(json["manualRates"] as? [String: Any])

        #expect(subscriptionJSON["calendarEventIdentifier"] == nil)
        #expect(Set(preferencesJSON.keys) == [
            "baseCurrency", "dueSoonWindowDays", "defaultReminderLeadDays"
        ])
        #expect(Set(ratesJSON.keys) == ["USD"])

        let allKeys = Self.allKeys(in: json)
        let excludedKeys: Set<String> = [
            "calendarEventIdentifier",
            "notificationTime",
            "launchAtLogin",
            "showInMenuBar",
            "menuBarLabel",
            "notificationsEnabled",
            "calendarSyncEnabled",
            "calendarIdentifier",
            "calendarAlertOffsetsDays",
            "lastCalendarSyncAt",
            "sortAscending",
            "showInspector",
            "hasCompletedFirstRun",
            "chartStyle",
            "categoryPeriod",
            "spendView",
            "useGoogleFaviconFallback",
            "autoUpdateRates",
            "automaticAsOf",
            "lastCheckedAt",
            "source"
        ]
        #expect(allKeys.isDisjoint(with: excludedKeys))
    }

    @Test func applyingAProjectionKeepsLocalSettingsAndAutomaticRates() {
        let checkedAt = Date(timeIntervalSince1970: 1_730_000_000)
        let manualDate = Date(timeIntervalSince1970: 1_740_000_000)
        var local = StoreDocument.initial()
        local.settings.showInMenuBar = false
        local.settings.notificationsEnabled = false
        local.settings.calendarSyncEnabled = true
        local.rates = RateTable(
            base: "EUR",
            rates: [
                "USD": Rate(value: 0.9, updatedAt: checkedAt, source: .automatic),
                "GBP": Rate(value: 1.1, updatedAt: checkedAt, source: .manual)
            ],
            automaticAsOf: checkedAt,
            lastCheckedAt: checkedAt
        )
        let remoteSubscription = Subscription(
            name: "Remote plan",
            categoryID: Category.fallbackID,
            price: 12,
            currency: "USD",
            cycle: .monthly
        )
        let projection = SyncedDocument(
            subscriptions: [SyncedSubscription(remoteSubscription)],
            categories: Category.seeded,
            preferences: SyncedPreferences(
                baseCurrency: "EUR",
                dueSoonWindowDays: 12,
                defaultReminderLeadDays: 5
            ),
            manualRates: [
                "CAD": SyncedManualRate(value: 0.7, updatedAt: manualDate)
            ]
        )

        let result = projection.applying(to: local)

        #expect(result.subscriptions == [remoteSubscription])
        #expect(result.settings.defaultReminderLeadDays == 5)
        #expect(!result.settings.showInMenuBar)
        #expect(!result.settings.notificationsEnabled)
        #expect(result.settings.calendarSyncEnabled)
        #expect(result.rates.rates["USD"]?.source == .automatic)
        #expect(result.rates.rates["CAD"] == Rate(
            value: 0.7,
            updatedAt: manualDate,
            source: .manual
        ))
        #expect(result.rates.rates["GBP"] == nil)
        #expect(result.rates.automaticAsOf == checkedAt)
        #expect(result.rates.lastCheckedAt == checkedAt)
    }

    @Test func applyingANewBaseDropsAutomaticRatesForTheOldBase() {
        let checkedAt = Date(timeIntervalSince1970: 1_730_000_000)
        var local = StoreDocument.initial()
        local.rates = RateTable(
            base: "EUR",
            rates: [
                "USD": Rate(value: 0.9, updatedAt: checkedAt, source: .automatic)
            ],
            automaticAsOf: checkedAt,
            lastCheckedAt: checkedAt
        )
        let projection = SyncedDocument(
            subscriptions: [],
            categories: Category.seeded,
            preferences: SyncedPreferences(
                baseCurrency: "GBP",
                dueSoonWindowDays: 7,
                defaultReminderLeadDays: 2
            ),
            manualRates: [
                "EUR": SyncedManualRate(value: 1.2, updatedAt: checkedAt)
            ]
        )

        let result = projection.applying(to: local)

        #expect(result.settings.baseCurrency == "GBP")
        #expect(result.rates.base == "GBP")
        #expect(result.rates.rates["USD"] == nil)
        #expect(result.rates.rates["EUR"]?.source == .manual)
        #expect(result.rates.automaticAsOf == nil)
        #expect(result.rates.lastCheckedAt == nil)
    }

    @Test func applyingAChangeSetUpdatesOnlyNamedRecords() {
        let first = SyncedSubscription(Subscription(
            name: "First plan",
            categoryID: Category.fallbackID,
            price: 5,
            currency: "EUR",
            cycle: .monthly
        ))
        let second = SyncedSubscription(Subscription(
            name: "Second plan",
            categoryID: Category.fallbackID,
            price: 8,
            currency: "EUR",
            cycle: .monthly
        ))
        let remote = SyncedSubscription(Subscription(
            name: "Remote plan",
            categoryID: Category.fallbackID,
            price: 12,
            currency: "EUR",
            cycle: .monthly
        ))
        let source = SyncedDocument(
            subscriptions: [first, second],
            categories: Category.seeded,
            preferences: SyncedPreferences(
                baseCurrency: "EUR",
                dueSoonWindowDays: 7,
                defaultReminderLeadDays: 2
            ),
            manualRates: [
                "USD": SyncedManualRate(value: 0.9, updatedAt: .distantPast)
            ]
        )

        let result = source.applying(SyncChangeSet(changes: [
            .delete(.subscription(first.id)),
            .save(.subscription(remote)),
            .delete(.manualRate("usd"))
        ]))

        #expect(!result.subscriptions.contains { $0.id == first.id })
        #expect(result.subscriptions.contains { $0.id == second.id })
        #expect(result.subscriptions.contains { $0.id == remote.id })
        #expect(result.manualRates.isEmpty)
        #expect(result.categories == source.categories)
        #expect(result.preferences == source.preferences)
    }

    // MARK: - The retired due-soon window

    @Test("Preferences that differ only in the retired due-soon window are equal and hash equal")
    func retiredWindowIsNotPartOfEquality() {
        let older = SyncedPreferences(baseCurrency: "EUR", dueSoonWindowDays: 21, defaultReminderLeadDays: 2)
        let current = SyncedPreferences(baseCurrency: "EUR", defaultReminderLeadDays: 2)

        #expect(current.dueSoonWindowDays == Settings.paymentHighlightWindowDays)
        #expect(older == current)
        #expect(older.hashValue == current.hashValue)
        #expect(Set([older, current]).count == 1)
        let olderRecord = SyncRecord.preferences(SyncedPreferencesRecord(preferences: older))
        let currentRecord = SyncRecord.preferences(SyncedPreferencesRecord(preferences: current))
        #expect(olderRecord == currentRecord)
        #expect(olderRecord.hashValue == currentRecord.hashValue)

        // The other two fields still count.
        #expect(older != SyncedPreferences(baseCurrency: "GBP", dueSoonWindowDays: 21, defaultReminderLeadDays: 2))
        #expect(older != SyncedPreferences(baseCurrency: "EUR", dueSoonWindowDays: 21, defaultReminderLeadDays: 3))
    }

    @Test("A preferences record from this build decodes with the previous build's shape")
    func newPreferencesDecodeWithThePreviousShape() throws {
        let current = SyncedPreferencesRecord(preferences: SyncedPreferences(
            settings: Settings(baseCurrency: "GBP", defaultReminderLeadDays: 3)
        ))

        let decoded = try JSONDecoder().decode(
            PreviousPreferencesRecord.self,
            from: JSONEncoder().encode(current)
        )

        #expect(decoded == PreviousPreferencesRecord(
            schemaVersion: SyncedDocument.currentSchemaVersion,
            preferences: PreviousSyncedPreferences(
                baseCurrency: "GBP",
                dueSoonWindowDays: 7,
                defaultReminderLeadDays: 3
            )
        ))
    }

    @Test("A preferences record from the previous build decodes, whatever window it holds")
    func previousPreferencesDecode() throws {
        for window in [1, 7, 14, 30] {
            let previous = PreviousPreferencesRecord(
                schemaVersion: 1,
                preferences: PreviousSyncedPreferences(
                    baseCurrency: "USD",
                    dueSoonWindowDays: window,
                    defaultReminderLeadDays: 4
                )
            )

            let decoded = try JSONDecoder().decode(
                SyncedPreferencesRecord.self,
                from: JSONEncoder().encode(previous)
            )

            #expect(decoded.schemaVersion == 1)
            #expect(decoded.preferences == SyncedPreferences(baseCurrency: "USD", defaultReminderLeadDays: 4))
            #expect(decoded.preferences.dueSoonWindowDays == window)
        }
    }

    /// `SyncedPreferences` and its record as the build before the retirement declared
    /// them: synthesised `Codable`, every key required.
    private struct PreviousSyncedPreferences: Codable, Equatable {
        var baseCurrency: String
        var dueSoonWindowDays: Int
        var defaultReminderLeadDays: Int
    }

    private struct PreviousPreferencesRecord: Codable, Equatable {
        var schemaVersion: Int
        var preferences: PreviousSyncedPreferences
    }

    private static func allKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { result, pair in
                result.formUnion(allKeys(in: pair.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: []) { result, element in
                result.formUnion(allKeys(in: element))
            }
        }
        return []
    }
}
