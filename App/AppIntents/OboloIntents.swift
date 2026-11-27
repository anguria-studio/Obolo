import AppIntents
import Foundation
import OboloCore

enum NextRenewalResult: Equatable, Sendable {
    case renewal(name: String, amount: String, datePhrase: String)
    case noRenewal
    case unavailable
    case updateRequired(StoreDocument.NewerVersion)

    var message: String {
        switch self {
        case let .renewal(name, amount, datePhrase):
            "\(name) renews \(datePhrase) for \(amount)."
        case .noRenewal:
            "No active subscription has a renewal date."
        case .unavailable:
            "Obolo cannot read the data. Open Obolo to recover it."
        case .updateRequired(let error):
            error.localizedDescription
        }
    }
}

struct NextRenewalReader: Sendable {
    let store: DocumentStore
    let today: Date
    let calendar: Calendar
    let locale: Locale

    func read() async -> NextRenewalResult {
        // A missing store can mean that the app moved a corrupt store aside. The
        // recovery note distinguishes that state from a new installation.
        if !FileManager.default.fileExists(atPath: store.url.path(percentEncoded: false)),
           RecoverySidecar.read(besideStoreAt: store.url) != nil {
            return .unavailable
        }

        do {
            return Self.result(
                for: try await store.load(),
                today: today,
                calendar: calendar,
                locale: locale
            )
        } catch let error as StoreDocument.NewerVersion {
            return .updateRequired(error)
        } catch {
            return .unavailable
        }
    }

    static func result(
        for document: StoreDocument,
        today: Date,
        calendar: Calendar,
        locale: Locale = .current
    ) -> NextRenewalResult {
        let ledger = Ledger(document: document, today: today, calendar: calendar)
        guard let renewal = ledger.upcoming(within: .max).first,
              let date = renewal.nextPayment
        else { return .noRenewal }

        let amount = MoneyFormatting.amount(
            renewal.price,
            currency: renewal.currency,
            estimate: renewal.isEstimate,
            locale: locale
        )
        let datePhrase = Self.datePhrase(
            for: date,
            today: today,
            calendar: calendar,
            locale: locale
        )
        return .renewal(name: renewal.name, amount: amount, datePhrase: datePhrase)
    }

    private static func datePhrase(
        for date: Date,
        today: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let days = RenewalSchedule.daysUntil(date, today: today, calendar: calendar)
        if days <= DateFormatting.relativeWindowDays {
            return DateFormatting.renewal(date, today: today, calendar: calendar, locale: locale)
        }
        return "on \(DateFormatting.absolute(date, today: today, calendar: calendar, locale: locale))"
    }
}

struct ShowNextRenewalIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Next Renewal"
    static let description = IntentDescription("This action shows the next subscription renewal.")
    @available(macOS, deprecated: 26.0, message: "Use supportedModes.")
    static let openAppWhenRun = false
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result: NextRenewalResult
        do {
            result = await NextRenewalReader(
                store: DocumentStore(url: try AppPaths.storeURL()),
                today: Date(),
                calendar: .autoupdatingCurrent,
                locale: .current
            ).read()
        } catch {
            result = .unavailable
        }

        return .result(value: result.message, dialog: "\(result.message)")
    }
}

/// A destination the main window can be asked for. Only the app asks, in this
/// process: through `OboloIntentRouter`, which keeps it in memory until the window
/// takes it. A route has no link of its own; the few that an outside caller may name
/// are `OboloIntentLink`s, which the window turns into routes.
enum OboloIntentRoute: Equatable, Sendable {
    /// The main window on Home: the menu bar item's left click.
    case home
    case upcoming
    case addSubscription(SubscriptionFormPrefill)
    /// The main window on one subscription's detail: a clicked reminder. A subscription
    /// that is gone by the time the route is taken opens the window with no detail.
    ///
    /// Deliberately not an `OboloIntentLink`: the URL scheme is open to every app,
    /// page and script on the Mac, and nothing outside Obolo needs to open a detail.
    case subscription(Subscription.ID)
}

/// The app's own `studio.anguria.obolo://intent` links: what a Shortcuts action opens
/// the app with. Anything on the Mac can open these, so each case is one an outside
/// caller is allowed to ask for, and there is no case for a subscription.
enum OboloIntentLink: Equatable, Sendable {
    case home
    case upcoming
    case addSubscription(SubscriptionFormPrefill)

    private static let scheme = "studio.anguria.obolo"
    private static let host = "intent"

    /// A link with no destination behind it. Opening it only makes SwiftUI build the
    /// main window (the scene handles every "intent" link), and the window then takes
    /// whatever route is already waiting in `OboloIntentRouter`. `init?(url:)` does not
    /// recognise its path, so it never queues anything itself.
    static let window = makeURL(path: "/window")

    /// The route the window takes for this link.
    var route: OboloIntentRoute {
        switch self {
        case .home: .home
        case .upcoming: .upcoming
        case .addSubscription(let prefill): .addSubscription(prefill)
        }
    }

    var url: URL {
        switch self {
        case .home:
            return Self.makeURL(path: "/home")
        case .upcoming:
            return Self.makeURL(path: "/upcoming")
        case .addSubscription(let prefill):
            var items: [URLQueryItem] = []
            if let name = prefill.name { items.append(URLQueryItem(name: "name", value: name)) }
            if let price = prefill.price {
                items.append(URLQueryItem(name: "price", value: NSDecimalNumber(decimal: price).stringValue))
            }
            if let currency = prefill.currency {
                items.append(URLQueryItem(name: "currency", value: currency))
            }
            if let cycle = prefill.cycle {
                items.append(URLQueryItem(name: "cycle", value: cycle.encoded))
            }
            if let anchorDate = prefill.anchorDate {
                items.append(URLQueryItem(name: "anchor", value: anchorDate.isoDate))
            }
            return Self.makeURL(path: "/add-subscription", queryItems: items)
        }
    }

    private static func makeURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        // The fixed scheme and host always make a valid URL.
        return components.url!
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.host
        else { return nil }

        switch components.path {
        case "/home":
            self = .home
        case "/upcoming":
            self = .upcoming
        case "/add-subscription":
            let values = Dictionary(
                components.queryItems?.compactMap { item in
                    item.value.map { (item.name, $0) }
                } ?? [],
                uniquingKeysWith: { _, last in last }
            )
            let price = values["price"].flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
            let cycle = values["cycle"].flatMap(BillingCycle.init(parsing:))
            let anchorDate = values["anchor"].flatMap(BillingDay.init(isoDate:))
            self = .addSubscription(
                SubscriptionFormPrefill(
                    name: values["name"],
                    price: price,
                    currency: values["currency"],
                    cycle: cycle,
                    anchorDate: anchorDate
                )
            )
        default:
            // `/window`, and `/subscription`, which an earlier build answered.
            return nil
        }
    }
}

/// The routes waiting for the main window, in the order they were asked for. In memory
/// only: a route that no window has taken goes with the process.
@MainActor
final class OboloIntentRouter {
    static let shared = OboloIntentRouter()

    private var pendingRoutes: [OboloIntentRoute] = []

    /// Queues `route` and tells the main window, if one is listening, to take it.
    ///
    /// `.home` asks only for the window. With another route already waiting (a
    /// reminder clicked during launch, then the menu bar item), the window opens on
    /// that one: `.home` adds nothing to the queue and does not send the window away
    /// from it.
    func request(_ route: OboloIntentRoute) {
        if route != .home || pendingRoutes.isEmpty {
            pendingRoutes.append(route)
        }
        NotificationCenter.default.post(name: .oboloOpenIntentRoute, object: nil)
    }

    func takePendingRoute(activeSheet: WindowSheet? = nil) -> OboloIntentRoute? {
        guard let route = pendingRoutes.first else { return nil }
        // A different Add waits at the front of the queue so the current draft can
        // be saved or cancelled. The same Add can bring its existing draft forward.
        if case .addSubscription(let prefill) = route,
           let activeSheet, activeSheet.content != .add(prefill) {
            return nil
        }
        return pendingRoutes.removeFirst()
    }
}

struct OpenUpcomingSubscriptionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Upcoming Subscriptions"
    static let description = IntentDescription("This action opens the Upcoming view in Obolo.")
    @available(macOS, deprecated: 26.0, message: "Use supportedModes.")
    static let openAppWhenRun = true
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult & OpensIntent {
        await openIntentLink(.upcoming)
    }
}

enum IntentBillingCycle: String, AppEnum {
    case weekly
    case monthly
    case quarterly
    case yearly
    case everyTwoYears

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Billing Cycle"
    static let caseDisplayRepresentations: [IntentBillingCycle: DisplayRepresentation] = [
        .weekly: "Weekly",
        .monthly: "Monthly",
        .quarterly: "Quarterly",
        .yearly: "Yearly",
        .everyTwoYears: "Every 2 years"
    ]

    var billingCycle: BillingCycle {
        switch self {
        case .weekly: .weekly
        case .monthly: .monthly
        case .quarterly: .quarterly
        case .yearly: .yearly
        case .everyTwoYears: .everyTwoYears
        }
    }
}

enum AddSubscriptionIntentPrefill {
    static func make(
        name: String?,
        price: IntentCurrencyAmount?,
        cycle: IntentBillingCycle?,
        renewalDate: Date?,
        calendar: Calendar
    ) -> SubscriptionFormPrefill {
        SubscriptionFormPrefill(
            name: name,
            price: price?.amount,
            currency: price.map { Subscription.normalizedCurrency($0.currencyCode) },
            cycle: cycle?.billingCycle,
            anchorDate: renewalDate.map { BillingDay($0, calendar: calendar) }
        )
    }
}

struct AddSubscriptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Subscription"
    static let description = IntentDescription(
        "This action opens the subscription form and fills the supplied values."
    )
    @available(macOS, deprecated: 26.0, message: "Use supportedModes.")
    static let openAppWhenRun = true
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Name", description: "The subscription name.")
    var name: String?

    @Parameter(title: "Price", description: "The price for one billing cycle.")
    var price: IntentCurrencyAmount?

    @Parameter(title: "Billing Cycle")
    var billingCycle: IntentBillingCycle?

    @Parameter(title: "Renewal Date", kind: .date)
    var renewalDate: Date?

    static var parameterSummary: some ParameterSummary {
        Summary(
            "Add \(\.$name). Price: \(\.$price). Cycle: \(\.$billingCycle). Renewal: \(\.$renewalDate)"
        )
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        let prefill = AddSubscriptionIntentPrefill.make(
            name: name,
            price: price,
            cycle: billingCycle,
            renewalDate: renewalDate,
            calendar: .autoupdatingCurrent
        )
        return await openIntentLink(.addSubscription(prefill))
    }
}

@MainActor
private func openIntentLink(_ link: OboloIntentLink) -> some IntentResult & OpensIntent {
    if #available(macOS 26.0, *) {
        return .result(opensIntent: OpenURLIntent(link.url))
    }
    // On Sequoia the intent already runs in the foreground. Use the app's window
    // presenter to deliver the route, including when the main window is closed.
    MainWindowPresenter.open(link.route)
    return .result()
}

struct OboloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowNextRenewalIntent(),
            phrases: [
                "Show my next renewal in \(.applicationName)",
                "What renews next in \(.applicationName)"
            ],
            shortTitle: "Show Next Renewal",
            systemImageName: "calendar.badge.clock"
        )
        AppShortcut(
            intent: OpenUpcomingSubscriptionsIntent(),
            phrases: [
                "Open upcoming subscriptions in \(.applicationName)",
                "Show upcoming subscriptions in \(.applicationName)"
            ],
            shortTitle: "Open Upcoming",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: AddSubscriptionIntent(),
            phrases: [
                "Add a subscription to \(.applicationName)",
                "Create a subscription in \(.applicationName)"
            ],
            shortTitle: "Add Subscription",
            systemImageName: "plus.circle"
        )
    }
}
