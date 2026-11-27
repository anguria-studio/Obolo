import Foundation
import OboloCore

enum SubscriptionEditorFocus: Equatable {
    case name
    case newPriceChange
    case firstPayment
}

/// One presentation of a sheet in the main window. Its identity owns the form's draft.
struct WindowSheet: Identifiable {
    enum Content: Equatable {
        case add(SubscriptionFormPrefill)
        case edit(Subscription.ID, focus: SubscriptionEditorFocus)
        case duplicate(Subscription)
        case reactivate(Subscription)
        case importPreview(ImportPreview)
    }

    let id = UUID()
    let content: Content

    /// The stored row that must still exist for the sheet to stay open.
    var editedSubscriptionID: Subscription.ID? {
        switch content {
        case .edit(let id, _): id
        case .reactivate(let subscription): subscription.id
        case .add, .duplicate, .importPreview: nil
        }
    }
}
