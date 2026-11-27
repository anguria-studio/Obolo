import Foundation

/// What is drawn inside a subscription's tinted circle.
///
/// `.initial` is the fallback the design leans on everywhere — the first character of
/// the name on a tinted circle — and the one every other case falls back *to*, because
/// it needs nothing but the name.
public enum Icon: Hashable, Sendable {
    /// First letter of the subscription's name.
    case initial
    /// A literal emoji, e.g. "🏋️".
    case emoji(String)
    /// An SF Symbol name, e.g. "figure.run".
    case symbol(String)
    /// A file in the app's icon store, e.g. `"3F2A….png"` — a fetched or dropped logo.
    ///
    /// A bare file *name*, never a path: the store directory moves with the sandbox
    /// container, and a document that named `/Users/someone/…` would break the first
    /// time it was restored on another Mac. A missing file renders as `.initial`, so a
    /// document that arrives without its icons folder still draws.
    ///
    /// Only the shape `isValidImageFilename` accepts ever survives decoding. See there
    /// for why.
    case image(String)
    /// The first letter on a colour the person picked: the form's "Letter" mode, chosen
    /// deliberately instead of a logo. (`.initial` is what a subscription without a logo
    /// shows on its own: the quiet grey initial.)
    case letter(LetterColor)

    /// A flat string form, used by both JSON and CSV so the two agree.
    ///
    /// `"initial"` · `"emoji:🏋️"` · `"symbol:figure.run"` · `"image:3F2A….png"`.
    /// Synthesised `Codable` for an enum with associated values produces
    /// `{"emoji":{"_0":"🏋️"}}`, which is neither readable in the store file nor
    /// expressible in a CSV cell.
    public var encoded: String {
        switch self {
        case .initial: "initial"
        case .emoji(let value): "emoji:\(value)"
        case .symbol(let name): "symbol:\(name)"
        case .image(let filename): "image:\(filename)"
        case .letter(let color): "letter:\(color.rawValue)"
        }
    }

    /// Parses `encoded`. Anything unrecognised — including an empty cell, and including
    /// `"image:…"` written by a build that has logos when read by one that does not —
    /// falls back to `.initial`, which always renders.
    ///
    /// An `image:` name that is not the exact shape the icon store writes is dropped
    /// here rather than repaired, so a hand-edited document or an imported CSV cannot
    /// name a file outside that folder.
    public init(encoded: String) {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = trimmed.dropPrefixIfPresent("emoji:"), !value.isEmpty {
            self = .emoji(String(value))
        } else if let value = trimmed.dropPrefixIfPresent("symbol:"), !value.isEmpty {
            self = .symbol(String(value))
        } else if let value = trimmed.dropPrefixIfPresent("image:"), Icon.isValidImageFilename(String(value)) {
            self = .image(String(value))
        } else if let value = trimmed.dropPrefixIfPresent("letter:"), let color = LetterColor(rawValue: String(value)) {
            self = .letter(color)
        } else {
            self = .initial
        }
    }

    /// Whether a name is one the icon store could have written: `<UUID>.png`, in either
    /// case, and nothing else.
    ///
    /// The store names every file after the subscription's own ID, so the whole set of
    /// legal names is 36 hex-and-hyphen characters plus `.png`. That shape cannot hold a
    /// separator, a `..`, a leading `/` or an extension the app does not write, which is
    /// what makes appending it to the icons folder safe. A name that fails this is not
    /// corrected — there is no correct answer — it decodes as `.initial`.
    public static func isValidImageFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".png") else { return false }
        let stem = name.dropLast(4)
        guard stem.count == 36 else { return false }
        return stem.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "-") }
    }

    /// The stored file this icon names, if it names one — what the delete path and the
    /// "fetch the ones that have none" pass both ask.
    public var imageFilename: String? {
        if case .image(let filename) = self { return filename }
        return nil
    }
}

/// The eight colours the "Letter" icon can sit on. Stored by name; the app owns the
/// hex values. A name an older or newer build does not know decodes as `.initial`.
public enum LetterColor: String, CaseIterable, Hashable, Sendable {
    case blue, green, teal, rose, violet, amber, gray, white
}

extension Icon: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(encoded: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoded)
    }
}

extension StringProtocol {
    /// `nil` when the prefix is absent, so `if let` reads as "did it match".
    func dropPrefixIfPresent(_ prefix: String) -> SubSequence? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
