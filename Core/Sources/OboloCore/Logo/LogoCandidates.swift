import Foundation

/// Where a service's logo might be, in the order worth trying.
///
/// Pure and offline: this file knows how to *name* candidate URLs and how to read the
/// `<link rel="icon">` tags out of a page, and nothing about how to go and get them.
/// That split is what lets the interesting half — "is `../favicons/favicon-180x180.png`
/// on dropbox.com the same file as `https://www.dropbox.com/favicons/favicon-180x180.png`"
/// — be tested with `swift test` and no network at all.
///
/// The order everywhere is *largest first*. A 16-pixel favicon rendered into a 38-point
/// circle on a Retina display is a smear, and every site that has an apple-touch-icon
/// has one at 180.
public enum LogoCandidates {

    // MARK: - Well-known paths

    /// The three files a site is conventionally expected to serve, in descending order
    /// of how good the result looks. Empty when `domain` is not a domain.
    ///
    /// These are guesses, tried when the page's own `<link>` tags gave nothing — a site
    /// that blocks the HTML with a 403 will often still serve `/favicon.ico` from a CDN.
    public static func urls(forDomain domain: String) -> [URL] {
        guard let host = Subscription.normalizedDomain(domain) else { return [] }
        return [
            "https://\(host)/apple-touch-icon.png",
            "https://\(host)/apple-touch-icon-precomposed.png",
            "https://\(host)/favicon.ico"
        ].compactMap(URL.init(string:))
    }

    /// Google's icon service — the last resort, and the only candidate that tells
    /// somebody else what the user is subscribed to. Nothing but the domain is sent, and
    /// `Settings.useGoogleFaviconFallback` can turn it off.
    public static func googleFaviconURL(domain: String, size: Int = 128) -> URL? {
        guard let host = Subscription.normalizedDomain(domain) else { return nil }
        var components = URLComponents(string: "https://www.google.com/s2/favicons")
        components?.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: String(max(16, size)))
        ]
        return components?.url
    }

    // MARK: - The page's own tags

    /// One `<link rel="…icon…">` from a page.
    public struct IconLink: Hashable, Sendable {

        /// Which flavour of icon the tag declared. Kept because it is the tie-breaker
        /// when neither tag says what size it is: an Apple touch icon is 180 pixels
        /// square by convention, a `rel="icon"` is usually a 32-pixel favicon.
        public enum Rel: String, Hashable, Sendable {
            case appleTouchIcon
            case appleTouchIconPrecomposed
            case icon
        }

        public let url: URL
        /// The larger side declared by `sizes="180x180"`, or found in a filename like
        /// `favicon-180x180.png`. `nil` when the tag did not say.
        public let pixelSize: Int?
        public let rel: Rel
        /// Declared for dark mode only: `media="(prefers-color-scheme: dark)"`.
        public let isDark: Bool

        public init(url: URL, pixelSize: Int?, rel: Rel, isDark: Bool = false) {
            self.url = url
            self.pixelSize = pixelSize
            self.rel = rel
            self.isDark = isDark
        }

        /// What the ordering sorts on: the declared size, or what this `rel` is worth
        /// when it declared none.
        public var sortRank: Int {
            if let pixelSize { return pixelSize }
            switch rel {
            case .appleTouchIcon, .appleTouchIconPrecomposed: return 180
            case .icon: return 32
            }
        }
    }

    /// Every icon link in `html`, resolved against `baseURL`, largest first.
    ///
    /// Deliberately a tolerant regex rather than a parser. The input is whatever a
    /// marketing site's build tool emitted: attributes in any order, single or double
    /// quotes or none, upper-case tag names, `<link>` tags injected by script and left
    /// unclosed. An `XMLParser` refuses all of that, and the cost of being wrong here is
    /// one icon that does not load — not a corrupt document.
    ///
    /// Recognised: `apple-touch-icon`, `apple-touch-icon-precomposed`, `icon` and
    /// `shortcut icon`. `mask-icon` is not — it is a flat monochrome silhouette meant
    /// for a Safari pinned tab, and it would render as a black blob in a tinted circle.
    ///
    /// An icon declared for dark mode only (`media="(prefers-color-scheme: dark)"`) is
    /// left out: it is drawn for a dark background, and the logo sits on white. Those are
    /// what `darkIconLinks(inHTML:baseURL:)` returns.
    public static func iconLinks(inHTML html: String, baseURL: URL) -> [IconLink] {
        allIconLinks(inHTML: html, baseURL: baseURL).filter { !$0.isDark }
    }

    /// The icons a page declares for dark mode only, largest first: the site's own dark
    /// version of its logo, when it has one.
    public static func darkIconLinks(inHTML html: String, baseURL: URL) -> [IconLink] {
        allIconLinks(inHTML: html, baseURL: baseURL).filter(\.isDark)
    }

    private static func allIconLinks(inHTML html: String, baseURL: URL) -> [IconLink] {
        var found: [(link: IconLink, order: Int)] = []
        var seen: [URL: Int] = [:]

        for tag in matches(of: Self.linkTagPattern, in: html) {
            let attributes = self.attributes(inTag: tag)
            guard let rawRel = attributes["rel"] else { continue }
            let tokens = rawRel.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)

            let rel: IconLink.Rel
            if tokens.contains("apple-touch-icon-precomposed") {
                rel = .appleTouchIconPrecomposed
            } else if tokens.contains("apple-touch-icon") {
                rel = .appleTouchIcon
            } else if tokens.contains("icon") {
                rel = .icon
            } else {
                continue
            }

            guard let href = attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !href.isEmpty,
                  let resolved = resolve(href: href, against: baseURL)
            else { continue }

            let size = pixelSize(declaredBy: attributes["sizes"])
                ?? pixelSize(inFilename: resolved.lastPathComponent)
            let media = attributes["media"]?.lowercased().replacingOccurrences(of: " ", with: "") ?? ""
            let isDark = media.contains("prefers-color-scheme:dark")
            let link = IconLink(url: resolved, pixelSize: size, rel: rel, isDark: isDark)

            // The same file listed twice — once with `sizes`, once without — is one
            // candidate, described by whichever tag said the most.
            if let index = seen[resolved] {
                if link.sortRank > found[index].link.sortRank { found[index].link = link }
            } else {
                seen[resolved] = found.count
                found.append((link, found.count))
            }
        }

        // Sorted on `(rank, order)` rather than on `rank` alone: `sorted(by:)` is not a
        // stable sort, and two 180-pixel icons should come back in document order every
        // time rather than in whichever order the sort happened to leave them.
        return found
            .sorted { ($0.link.sortRank, -$0.order) > ($1.link.sortRank, -$1.order) }
            .map(\.link)
    }

    // MARK: - Parsing

    /// `<link …>`, however it was spelled. `[^>]*` stops at the first `>`, which is
    /// wrong for an attribute value containing one and right for everything else.
    private static let linkTagPattern = "<link\\b[^>]*>"

    /// `name = "value"`, `name='value'` or `name=value`.
    private static let attributePattern =
        "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"

    /// `180x180`, in a `sizes` attribute or a filename.
    private static let dimensionsPattern = "([0-9]{1,4})[xX]([0-9]{1,4})"

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    /// Lower-cased attribute names to their raw values.
    private static func attributes(inTag tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: attributePattern, options: [.caseInsensitive]) else {
            return [:]
        }
        var result: [String: String] = [:]
        let range = NSRange(tag.startIndex..., in: tag)
        for match in regex.matches(in: tag, options: [], range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = tag[nameRange].lowercased()
            // Groups 2, 3 and 4 are double-quoted, single-quoted and bare; exactly one
            // of them participated.
            let value = (2...4)
                .compactMap { Range(match.range(at: $0), in: tag) }
                .first
                .map { String(tag[$0]) }
            guard let value, result[name] == nil else { continue }
            result[name] = decodingEntities(value)
        }
        return result
    }

    /// The five entities that turn up in a `href` in the wild. A full entity table would
    /// be a second library for no gain — icon paths are ASCII.
    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    /// `sizes="16x16 32x32"` → 32. `sizes="any"` → `nil`, which ranks it as an unsized
    /// icon rather than as an infinitely large one.
    private static func pixelSize(declaredBy sizes: String?) -> Int? {
        guard let sizes else { return nil }
        return largestDimension(in: sizes)
    }

    /// `favicon-180x180.png` → 180. Sites that predate `sizes=` say it in the name.
    private static func pixelSize(inFilename filename: String) -> Int? {
        largestDimension(in: filename)
    }

    private static func largestDimension(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: dimensionsPattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        var best: Int?
        for match in regex.matches(in: text, options: [], range: range) {
            let numbers = (1...2)
                .compactMap { Range(match.range(at: $0), in: text) }
                .compactMap { Int(text[$0]) }
            guard let side = numbers.max(), side > 0 else { continue }
            best = max(best ?? 0, side)
        }
        return best
    }

    /// Absolute hrefs pass through; protocol-relative `//cdn…` takes the base's scheme;
    /// everything else resolves against the base, `../` included. Only `http` and
    /// `https` come back — a `data:` icon cannot be fetched with a request.
    private static func resolve(href: String, against baseURL: URL) -> URL? {
        let url: URL?
        if href.hasPrefix("//") {
            url = URL(string: (baseURL.scheme ?? "https") + ":" + href)
        } else {
            url = URL(string: href, relativeTo: baseURL)?.absoluteURL
        }
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
