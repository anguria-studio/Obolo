import Foundation
import OboloCore

enum AppPathsError: Error, Equatable {
    case appGroupUnavailable(String)
}

/// File locations for Obolo.
///
/// The app composition root and the Shortcuts actions use this helper, so both read the
/// same document and icon directory from the registered App Group container, which is
/// where the store lives.
enum AppPaths {
    static let appGroupIdentifier = "group.studio.anguria.obolo"
    static let directoryName = "Obolo"
    static let cloudSyncStateFileName = "cloud-sync.json"
    static let cloudSyncBackupsDirectoryName = "iCloud Backups"

    static func containerURL(fileManager: FileManager = .default) throws -> URL {
        guard let url = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw AppPathsError.appGroupUnavailable(appGroupIdentifier)
        }
        return url
    }

    static func supportDirectory(in containerURL: URL) -> URL {
        containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func storeURL(in containerURL: URL) -> URL {
        supportDirectory(in: containerURL)
            .appendingPathComponent(DocumentStore.fileName, isDirectory: false)
    }

    static func storeURL(fileManager: FileManager = .default) throws -> URL {
        storeURL(in: try containerURL(fileManager: fileManager))
    }

    static func deviceStateURL(in containerURL: URL) -> URL {
        supportDirectory(in: containerURL)
            .appendingPathComponent(DeviceStateStore.fileName, isDirectory: false)
    }

    static func deviceStateURL(fileManager: FileManager = .default) throws -> URL {
        deviceStateURL(in: try containerURL(fileManager: fileManager))
    }

    static func cloudSyncStateURL(in containerURL: URL) -> URL {
        supportDirectory(in: containerURL)
            .appendingPathComponent(cloudSyncStateFileName, isDirectory: false)
    }

    static func cloudSyncStateURL(fileManager: FileManager = .default) throws -> URL {
        cloudSyncStateURL(in: try containerURL(fileManager: fileManager))
    }

    static func cloudSyncBackupsDirectory(in containerURL: URL) -> URL {
        supportDirectory(in: containerURL)
            .appendingPathComponent(cloudSyncBackupsDirectoryName, isDirectory: true)
    }

    static func iconsDirectory(in containerURL: URL) -> URL {
        supportDirectory(in: containerURL)
            .appendingPathComponent("Icons", isDirectory: true)
    }

    static func iconsDirectory(fileManager: FileManager = .default) throws -> URL {
        iconsDirectory(in: try containerURL(fileManager: fileManager))
    }
}
