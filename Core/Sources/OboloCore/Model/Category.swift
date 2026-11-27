import Foundation

/// A user-editable bucket. Deleting one moves its subscriptions to "Other", which is
/// why `StoreDocument` guarantees an Other category exists.
public struct Category: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Its colour, from the twelve-hue category palette.
    public var tint: CategoryHue
    /// Position in Settings → Categories. Not an array index — reordering rewrites these.
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, tint: CategoryHue, sortOrder: Int) {
        self.id = id
        self.name = name
        self.tint = tint
        self.sortOrder = sortOrder
    }

    /// The name the "delete a category" rule falls back to.
    ///
    /// A label, not an identity: the user may rename this bucket to anything, and
    /// nothing decides which category it is by reading this. `fallbackID` does that.
    public static let fallbackName = "Other"

    /// The identity of the bucket that orphans land in.
    ///
    /// Seeded with a fixed ID and matched by that ID everywhere, so renaming "Other" to
    /// "Misc" — or to a word in another language — keeps it protected from deletion and
    /// keeps it the destination a deleted category's subscriptions move to. Matching on
    /// the name instead would silently hand both jobs to whichever category happened to
    /// be called "Other" next.
    public static let fallbackID = UUID(uuidString: "C000000C-0000-4000-A000-00000000000C")!

    /// Default categories in display order.
    ///
    /// IDs are fixed rather than freshly generated so a document written by one build
    /// and a fixture written by another still refer to the same "AI tools".
    public static let seeded: [Category] = [
        Category(id: UUID(uuidString: "C0000001-0000-4000-A000-000000000001")!, name: "Streaming", tint: .rose, sortOrder: 0),
        Category(id: UUID(uuidString: "C0000002-0000-4000-A000-000000000002")!, name: "Music", tint: .magenta, sortOrder: 1),
        Category(id: UUID(uuidString: "C0000003-0000-4000-A000-000000000003")!, name: "Software", tint: .teal, sortOrder: 2),
        Category(id: UUID(uuidString: "C0000004-0000-4000-A000-000000000004")!, name: "Cloud storage", tint: .sky, sortOrder: 3),
        Category(id: UUID(uuidString: "C0000005-0000-4000-A000-000000000005")!, name: "AI tools", tint: .blue, sortOrder: 4),
        Category(id: UUID(uuidString: "C0000006-0000-4000-A000-000000000006")!, name: "Security & VPN", tint: .violet, sortOrder: 5),
        Category(id: UUID(uuidString: "C0000007-0000-4000-A000-000000000007")!, name: "News & media", tint: .olive, sortOrder: 6),
        Category(id: UUID(uuidString: "C0000008-0000-4000-A000-000000000008")!, name: "Gaming", tint: .lime, sortOrder: 7),
        Category(id: UUID(uuidString: "C0000009-0000-4000-A000-000000000009")!, name: "Fitness & health", tint: .green, sortOrder: 8),
        Category(id: UUID(uuidString: "C000000A-0000-4000-A000-00000000000A")!, name: "Utilities & telecom", tint: .mint, sortOrder: 9),
        Category(id: UUID(uuidString: "C000000B-0000-4000-A000-00000000000B")!, name: "Insurance", tint: .slate, sortOrder: 10),
        Category(id: Category.fallbackID, name: Category.fallbackName, tint: .gray, sortOrder: 11)
    ]

    /// Placeholder used when a summary's category has been deleted out from under it.
    /// `Ledger` never emits this in practice — it repairs dangling references — but a
    /// non-optional `category` on `SubscriptionSummary` is worth an unreachable branch.
    public static let unknown = Category(
        id: UUID(uuidString: "C0000000-0000-4000-A000-000000000000")!,
        name: Category.fallbackName,
        tint: .gray,
        sortOrder: .max
    )
}

// MARK: - Coding

extension Category {
    private enum CodingKeys: String, CodingKey {
        case id, name, hue, sortOrder
    }

    /// Lenient, so one odd field never costs the whole document: a category without a
    /// hue this build knows takes its seeded hue when it is one of the seeded
    /// categories, grey otherwise.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        let decodedID = id
        let stored = (try? container.decodeIfPresent(String.self, forKey: .hue)).flatMap { $0 }
        tint = stored.flatMap(CategoryHue.init(rawValue:))
            ?? Category.seeded.first { $0.id == decodedID }?.tint
            ?? .gray
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(tint, forKey: .hue)
        try container.encode(sortOrder, forKey: .sortOrder)
    }
}

extension Array where Element == Category {
    /// Case- and whitespace-insensitive lookup, which is how CSV rows find their home.
    public func first(named name: String) -> Category? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return first { $0.name.compare(target, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    public func first(id: Category.ID) -> Category? {
        first { $0.id == id }
    }
}
