import Foundation

/// Where the main window is, which is also the filter applied to the All list.
public enum Section: Hashable, Sendable {
    case overview
    /// Renewing within `Section.upcomingWindowDays`.
    case upcoming
    /// One month at a time, every charge on the day it lands.
    case calendar
    case all
    case attention
    case pausedCancelled
    case category(Category.ID)

    /// Upcoming's window, which its empty list states in days.
    public static let upcomingWindowDays = 30

    /// The `.navigationTitle`. Category sections resolve their name from the document.
    public func title(in document: StoreDocument) -> String {
        switch self {
        case .overview: "Home"
        case .upcoming: "Upcoming"
        case .calendar: "Calendar"
        case .all: "All subscriptions"
        case .attention: "Needs attention"
        case .pausedCancelled: "Cancelled"
        case .category(let id): document.categories.first(id: id)?.name ?? Category.fallbackName
        }
    }
}
