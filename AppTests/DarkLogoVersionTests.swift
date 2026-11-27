import AppKit
import Foundation
import OboloCore
import Testing

/// Where a logo's dark version is written, kept and removed: every path that stores a
/// logo, and every path that removes one. Each model and store has a folder of its own
/// and a fetcher that answers without a network.
@MainActor
@Suite("Dark logo versions")
struct DarkLogoVersionTests {

    // MARK: - iCloud arrivals (LogoStore)

    @Test("An iCloud arrival of the logo already on disk keeps its dark version")
    func sameArrivalKeepsDark() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let filename = try store.store(imageData: png(.systemRed), for: id)
        try store.storeDark(imageData: png(.systemBlue), besideLogo: filename)
        let arrivals = Arrivals(store)

        // The same image as it was first sent, and as this Mac wrote it.
        #expect(try store.storeArrived(imageData: png(.systemRed), for: id) == false)
        let onDisk = try Data(contentsOf: directory.appending(path: filename))
        #expect(try store.storeArrived(imageData: onDisk, for: id) == false)

        #expect(store.darkImage(for: filename) != nil)
        #expect(exists(LogoStore.darkFilename(for: filename), in: directory))
        #expect(arrivals.ids.isEmpty)
    }

    @Test("A new logo from iCloud removes the old dark version and asks for its own, once")
    func newArrivalClearsDark() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let filename = try store.store(imageData: png(.systemRed), for: id)
        try store.storeDark(imageData: png(.systemBlue), besideLogo: filename)
        let arrivals = Arrivals(store)

        // What another Mac sends is its own file, encoded there.
        let (otherMac, otherDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        let sent = try Data(contentsOf: otherDirectory.appending(
            path: otherMac.store(imageData: png(.systemGreen), for: id)
        ))

        #expect(try store.storeArrived(imageData: sent, for: id))
        #expect(store.darkImage(for: filename) == nil)
        #expect(!exists(LogoStore.darkFilename(for: filename), in: directory))
        #expect(arrivals.ids == [id])

        // The same logo again, with the next change to the row: nothing to do.
        #expect(try store.storeArrived(imageData: sent, for: id) == false)
        #expect(arrivals.ids == [id])
    }

    @Test("CloudKit replay installs a same-filename replacement after restart and retries a failed file write")
    func replayInstallsAssetOnlyChange() throws {
        let (logos, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let filename = try logos.store(imageData: png(.systemRed), for: id)
        try logos.storeDark(imageData: png(.systemBlue), besideLogo: filename)
        let arrivals = Arrivals(logos)
        let plan = Subscription(id: id, name: "Mail", icon: .image(filename), categoryID: Category.fallbackID,
                                price: 10, currency: "EUR", cycle: .monthly)
        let base = SyncedDocument(document: StoreDocument(subscriptions: [plan]))
        let record = SyncRecord.subscription(try #require(base.subscriptions.first))
        let name = CloudKitRecordCodec.recordID(for: record.id).recordName
        var state = CloudSyncStateFile(baseDocument: base)
        state.stageRemoteChanges(SyncChangeSet(changes: [.save(record)]))
        let replacement = png(.systemGreen)
        state.pendingRemoteAssets[name] = replacement
        let queue = CloudSyncStateStore(url: directory.appending(path: "queue.json"))
        try queue.save(state)
        state = try #require(try queue.load())
        let remote = try #require(state.pendingRemoteDocument)
        #expect(SyncChangeSet(from: base, to: remote).changes.isEmpty)
        var renamed = plan
        renamed.name = "Local rename"
        let local = SyncedDocument(document: StoreDocument(subscriptions: [renamed]))
        let result = try SyncMerge.merge(base: base, local: local, remote: remote, today: Date(), calendar: .current)

        // A regular file in place of the icons directory makes the first write fail.
        let blockedPath = directory.appending(path: "blocked")
        try Data().write(to: blockedPath)
        #expect(throws: (any Error).self) {
            try CloudKitSyncService.installRemoteAssets(from: state, result: result, in: LogoStore(directory: blockedPath))
        }
        state = try #require(try queue.load())
        try CloudKitSyncService.installRemoteAssets(from: state, result: result, in: logos)
        #expect(arrivals.ids == [id])
        #expect(logos.darkImage(for: filename) == nil)
        // Already installed on the second pass, including after a crash before acknowledgement.
        #expect(try logos.storeArrived(imageData: replacement, for: id) == false)
        try CloudKitSyncService.installRemoteAssets(from: state, result: result, in: logos)
        #expect(arrivals.ids == [id])
        state.finishRemoteMerge(with: result, localDocument: result.document, iconFingerprints: [:])
        #expect(state.pendingRemoteAssets.isEmpty)
        let renamedRecord = try #require(local.subscriptions.first)
        #expect(state.pendingChanges == [.save(.subscription(renamedRecord))])
    }

    @Test("A logo arriving where there was none is written and asks for its dark version")
    func firstArrival() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let arrivals = Arrivals(store)

        #expect(try store.storeArrived(imageData: png(.systemRed), for: id))
        #expect(store.image(named: LogoStore.filename(for: id)) != nil)
        #expect(arrivals.ids == [id])
    }

    // MARK: - iCloud arrivals (AppModel)

    @Test("A logo that arrives through iCloud gets the site's dark version on this Mac")
    func arrivalFetchesDark() async throws {
        let fetcher = FakeLogoFetcher(dark: png(.systemBlue))
        let setup = makeModel(fetcher: fetcher, start: .logoNotOnDisk)
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        #expect(try setup.store.storeArrived(imageData: png(.systemRed), for: setup.id))
        await setup.model.arrivedLogosTask?.value

        #expect(await fetcher.darkRequests == ["example.com"])
        #expect(setup.store.darkImage(for: setup.filename) != nil)
        #expect(setup.model.arrivedLogosTask == nil)
    }

    @Test("The same logo arriving again asks the site for nothing")
    func sameArrivalAsksNothing() async throws {
        let fetcher = FakeLogoFetcher(dark: png(.systemBlue))
        let setup = makeModel(fetcher: fetcher, start: .logo)
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        #expect(try setup.store.storeArrived(imageData: png(.systemRed), for: setup.id) == false)
        #expect(setup.model.arrivedLogosTask == nil)
        #expect(await fetcher.darkRequests.isEmpty)
    }

    @Test("A logo with a dark version, or a row with no logo, asks the site for nothing")
    func arrivalWithNothingToFetch() async throws {
        let fetcher = FakeLogoFetcher(dark: png(.systemBlue))
        for start in [Start.noLogo, .logoAndDark] {
            let setup = makeModel(fetcher: fetcher, start: start)
            defer { try? FileManager.default.removeItem(at: setup.directory) }
            await setup.model.fetchDarkVersion(ofArrivedLogo: setup.id)
        }
        #expect(await fetcher.darkRequests.isEmpty)
    }

    @Test("A dark version that answers after the website changed is not kept")
    func arrivalAfterWebsiteChange() async throws {
        let fetcher = FakeLogoFetcher(dark: png(.systemBlue))
        let setup = makeModel(fetcher: fetcher, start: .logo)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        await fetcher.hold()

        async let fetched: Void = setup.model.fetchDarkVersion(ofArrivedLogo: setup.id)
        await fetcher.waitForDarkRequest()
        var edited = try #require(setup.model.subscription(setup.id))
        edited.website = "other.example"
        setup.model.update(edited)
        await fetcher.release()
        await fetched

        #expect(setup.store.darkImage(for: setup.filename) == nil)
        try await setup.model.flushSave()
    }

    // MARK: - Fetching (the form, the missing-logos pass)

    @Test("Fetch logo keeps the site's dark version beside the logo")
    func fetchStoresDark() async throws {
        let fetcher = FakeLogoFetcher(logo: png(.systemRed), dark: png(.systemBlue))
        let setup = makeModel(fetcher: fetcher, start: .noLogo)
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        #expect(await setup.model.fetchLogo(for: setup.id))
        #expect(setup.model.subscription(setup.id)?.icon == .image(setup.filename))
        #expect(setup.store.darkImage(for: setup.filename) != nil)
        try await setup.model.flushSave()
    }

    @Test("A new website's logo never keeps the old site's dark version")
    func websiteChangeReplacesDark() async throws {
        let fetcher = FakeLogoFetcher(logo: png(.systemGreen), dark: nil)
        let setup = makeModel(fetcher: fetcher, start: .logoAndDark)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let dark = LogoStore.darkFilename(for: setup.filename)
        let oldDark = try Data(contentsOf: setup.directory.appending(path: dark))

        // What the form's Save does when the website changed.
        var edited = try #require(setup.model.subscription(setup.id))
        edited.website = "other.example"
        setup.model.update(edited)
        #expect(await setup.model.fetchLogo(for: setup.id))
        #expect(await fetcher.requests == ["other.example"])
        #expect(setup.store.darkImage(for: setup.filename) == nil)
        #expect(!exists(dark, in: setup.directory))

        // A new site with a dark version of its own puts that one there.
        await fetcher.answer(logo: png(.systemGreen), dark: png(.systemPurple))
        #expect(await setup.model.fetchLogo(for: setup.id))
        #expect(try Data(contentsOf: setup.directory.appending(path: dark)) != oldDark)
        try await setup.model.flushSave()
    }

    // MARK: - Removing a logo

    @Test("Use initial removes the dark version with the logo")
    func useInitialRemovesDark() async throws {
        let setup = makeModel(fetcher: FakeLogoFetcher(), start: .logoAndDark)
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        var edited = try #require(setup.model.subscription(setup.id))
        edited.icon = .initial
        setup.model.update(edited)

        #expect(!exists(setup.filename, in: setup.directory))
        #expect(!exists(LogoStore.darkFilename(for: setup.filename), in: setup.directory))
        try await setup.model.flushSave()
    }

    @Test("Undo brings a deleted row back with its dark version; the final delete removes it")
    func deleteAndUndoKeepDark() async throws {
        let setup = makeModel(fetcher: FakeLogoFetcher(), rows: 2, start: .logoAndDark)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        let dark = LogoStore.darkFilename(for: setup.filename)

        model.delete(setup.id)
        #expect(exists(dark, in: setup.directory))
        model.undoDelete()
        #expect(model.subscription(setup.id)?.icon == .image(setup.filename))
        #expect(setup.store.darkImage(for: setup.filename) != nil)

        // A second delete makes the first one final.
        model.delete(setup.id)
        let other = try #require(model.document.subscriptions.first?.id)
        model.delete(other)
        #expect(!exists(setup.filename, in: setup.directory))
        #expect(!exists(dark, in: setup.directory))
        try await model.flushSave()
    }

    @Test("Restoring a backup leaves logos and their dark versions as they are")
    func restoreKeepsDark() async throws {
        let setup = makeModel(fetcher: FakeLogoFetcher(), start: .logoAndDark)
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        let backup = setup.directory.appending(path: "backup.json")
        try await DocumentStore(url: backup).save(setup.model.document)
        try await setup.model.restore(from: backup)

        #expect(setup.model.subscription(setup.id)?.icon == .image(setup.filename))
        #expect(setup.store.darkImage(for: setup.filename) != nil)
        try await setup.model.flushSave()
    }

    // MARK: - Helpers

    private func makeStore() -> (LogoStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OboloDarkVersionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (LogoStore(directory: directory), directory)
    }

    enum Start { case noLogo, logoNotOnDisk, logo, logoAndDark }

    struct Setup {
        let model: AppModel
        let store: LogoStore
        /// The model's store, its device state and its logos, all in one folder.
        let directory: URL
        /// The first row, on example.com, and the logo file named after it.
        let id: Subscription.ID
        let filename: String
    }

    /// A model with `rows` rows on example.com, its own folder and `fetcher`. The first
    /// row starts as `start` says, with a red logo and a blue dark version.
    private func makeModel(fetcher: FakeLogoFetcher, rows: Int = 1, start: Start) -> Setup {
        let (store, directory) = makeStore()
        var document = StoreDocument.initial()
        for index in 0..<rows {
            var subscription = Subscription(
                name: "Service \(index)",
                categoryID: document.fallbackCategoryID,
                price: 5,
                currency: document.settings.baseCurrency,
                cycle: .monthly,
                anchorDate: BillingDay(isoDate: "2026-05-28")!
            )
            subscription.website = "example.com"
            document.subscriptions.append(subscription)
        }
        let id = document.subscriptions[0].id
        let filename = LogoStore.filename(for: id)
        switch start {
        case .noLogo:
            document.subscriptions[0].icon = .initial
        case .logoNotOnDisk:
            document.subscriptions[0].icon = .image(filename)
        case .logo, .logoAndDark:
            _ = try? store.store(imageData: png(.systemRed), for: id)
            if start == .logoAndDark {
                try? store.storeDark(imageData: png(.systemBlue), besideLogo: filename)
            }
            document.subscriptions[0].icon = .image(filename)
        }
        let model = AppModel(
            store: DocumentStore(url: directory.appending(path: "obolo.json")),
            deviceStateStore: DeviceStateStore(url: directory.appending(path: DeviceStateStore.fileName)),
            document: document,
            rateService: NoRates(),
            cloudSyncService: DisabledCloudSyncService(),
            autoload: false
        )
        model.logos = store
        model.logoFetcher = fetcher
        return Setup(model: model, store: store, directory: directory, id: id, filename: filename)
    }

    private func exists(_ filename: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: filename).path(percentEncoded: false))
    }

    /// A 64-pixel square of one colour, large enough for `LogoStore` to keep.
    private func png(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}

/// The ids `LogoStore.logoDidArrive` was told, in order.
@MainActor
private final class Arrivals {
    private(set) var ids: [UUID] = []

    init(_ store: LogoStore) {
        store.logoDidArrive = { [weak self] id in self?.ids.append(id) }
    }
}

/// Answers every fetch with what it was given, and records what it was asked for. A
/// held dark fetch waits for `release`.
private actor FakeLogoFetcher: LogoFetching {
    private var logo: Data?
    private var dark: Data?
    private(set) var requests: [String] = []
    private(set) var darkRequests: [String] = []
    private var isHeld = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    init(logo: Data? = nil, dark: Data? = nil) {
        self.logo = logo
        self.dark = dark
    }

    func answer(logo: Data?, dark: Data?) {
        self.logo = logo
        self.dark = dark
    }

    func hold() { isHeld = true }

    func release() {
        isHeld = false
        held.forEach { $0.resume() }
        held.removeAll()
    }

    func waitForDarkRequest() async {
        guard darkRequests.isEmpty else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func fetchWithDarkVariant(domain: String, allowGoogleFallback: Bool) async -> (logo: Data?, dark: Data?) {
        requests.append(domain)
        return logo == nil ? (nil, nil) : (logo, dark)
    }

    func fetchDarkVersion(domain: String) async -> Data? {
        darkRequests.append(domain)
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        if isHeld { await withCheckedContinuation { held.append($0) } }
        return dark
    }
}

/// Rates are not under test: nothing is ever asked for.
private struct NoRates: RateFetching {
    func fetch(base: String, symbols: [String]) async throws -> (asOf: Date, ratesToBase: [String: Decimal]) {
        (Date(timeIntervalSince1970: 0), [:])
    }
}
