import Foundation
import OboloCore
import Testing

@Suite("Device-local state")
struct DeviceStateTests {
    @Test("EventKit identifiers stay keyed to their subscription")
    func eventIdentifiers() {
        let first = UUID()
        let second = UUID()
        var state = DeviceState.initial()

        state.setCalendarEventIdentifier("event-1", for: first)
        state.setCalendarEventIdentifier("event-2", for: second)
        state.setCalendarEventIdentifier(nil, for: first)

        #expect(state.calendarEventIdentifier(for: first) == nil)
        #expect(state.calendarEventIdentifier(for: second) == "event-2")
        #expect(state.allCalendarEventIdentifiers == ["event-2"])
    }

    @Test("The device store round-trips and a missing file starts empty")
    func storeRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OboloDeviceStateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = DeviceStateStore(url: directory.appending(path: DeviceStateStore.fileName))
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await store.load() == .initial())

        let subscriptionID = UUID()
        var state = DeviceState(
            lastCalendarSyncAt: Date(timeIntervalSince1970: 1_700_000_000),
            cloudSyncEnabled: true
        )
        state.setCalendarEventIdentifier("event-1", for: subscriptionID)
        try await store.save(state)

        #expect(try await store.load() == state)
    }

    @Test("An old device file keeps cloud sync off")
    func oldDeviceStateKeepsCloudSyncOff() throws {
        let data = Data("""
        {
          "version": 1,
          "calendarEventIdentifiers": {}
        }
        """.utf8)

        let state = try JSONDecoder().decode(DeviceState.self, from: data)

        #expect(!state.cloudSyncEnabled)
    }
}
