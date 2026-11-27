import Foundation

/// Optional values to seed a new subscription draft.
public struct SubscriptionFormPrefill: Equatable, Sendable {
    public var name: String?
    public var price: Decimal?
    public var currency: String?
    public var cycle: BillingCycle?
    public var anchorDate: BillingDay?

    public init(
        name: String? = nil,
        price: Decimal? = nil,
        currency: String? = nil,
        cycle: BillingCycle? = nil,
        anchorDate: BillingDay? = nil
    ) {
        self.name = name
        self.price = price
        self.currency = currency
        self.cycle = cycle
        self.anchorDate = anchorDate
    }
}
