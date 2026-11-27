import Foundation
import Testing

@Suite("Shared application paths")
struct AppPathsTests {
    @Test("Store and icon paths use one Obolo support directory")
    func sharedPaths() {
        let root = URL(fileURLWithPath: "/tmp/example-group", isDirectory: true)

        #expect(
            AppPaths.storeURL(in: root).path
                == "/tmp/example-group/Library/Application Support/Obolo/obolo.json"
        )
        #expect(
            AppPaths.iconsDirectory(in: root).path
                == "/tmp/example-group/Library/Application Support/Obolo/Icons"
        )
        #expect(
            AppPaths.deviceStateURL(in: root).path
                == "/tmp/example-group/Library/Application Support/Obolo/device.json"
        )
        #expect(
            AppPaths.cloudSyncStateURL(in: root).path
                == "/tmp/example-group/Library/Application Support/Obolo/cloud-sync.json"
        )
        #expect(
            AppPaths.cloudSyncBackupsDirectory(in: root).path
                == "/tmp/example-group/Library/Application Support/Obolo/iCloud Backups"
        )
    }
}
