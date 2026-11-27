import Foundation
import OboloCore

extension AppModel {
    /// Creates a preview with sample subscriptions, a fixed date and a temporary store.
    ///
    /// `#Preview` bodies compile in Release too, so this is not under `#if DEBUG`.
    static func handoffPreview(_ configure: (inout StoreDocument) -> Void = { _ in }) -> AppModel {
        var document = SampleData.handoff()
        configure(&document)
        return AppModel(
            store: DocumentStore(
                url: FileManager.default.temporaryDirectory
                    .appending(path: "obolo-preview-\(UUID().uuidString).json")
            ),
            document: document,
            calendar: SampleData.referenceCalendar,
            clock: { SampleData.referenceToday },
            autoload: false
        )
    }
}
