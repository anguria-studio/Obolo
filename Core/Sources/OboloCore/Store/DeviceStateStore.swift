import Foundation

/// Atomic storage for state that belongs to one Mac.
public actor DeviceStateStore {
    public nonisolated let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static let fileName = "device.json"

    public func load() throws -> DeviceState {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .initial()
        }
        return try DocumentStore.makeDecoder().decode(
            DeviceState.self,
            from: Data(contentsOf: url)
        )
    }

    public func save(_ state: DeviceState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try DocumentStore.makeEncoder().encode(state)
        try data.write(to: url, options: [.atomic])
    }
}
