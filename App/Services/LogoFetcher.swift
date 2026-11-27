import AppKit
import Foundation
import OboloCore

/// What `AppModel` asks of `LogoFetcher`, so a test can answer without a network.
protocol LogoFetching: Sendable {
    func fetchWithDarkVariant(domain: String, allowGoogleFallback: Bool) async -> (logo: Data?, dark: Data?)
    func fetchDarkVersion(domain: String) async -> Data?
}

/// Fetches a subscription website's home page, its declared icon URLs (which may
/// point to another host), and conventional icon paths. The direct-download edition
/// can also ask Google for a missing or small icon.
///
/// Saving a form, importing subscriptions or manually fetching logos can start a
/// lookup. Existing and newly synced logos can also trigger a dark-icon lookup.
actor LogoFetcher: LogoFetching {

    /// Big enough for the largest place a logo is drawn: the Detail header's 52-point
    /// `SubscriptionIcon` (`SubscriptionDetail`), which on a 2× display — the highest
    /// backing scale a Mac has — is 104 pixels. 120 clears that with a little to spare.
    /// Reaching it with a clear mark stops the search. An opaque touch icon can meet
    /// the size target while a later site link provides a cleaner mark.
    private static let goodEnough = 120
    private static let fullSize = 104

    /// A page can be any size; only the `<head>` is of interest and it is always near
    /// the front.
    private static let htmlByteCap = 512 * 1024
    private static let imageByteCap = 2 * 1024 * 1024

    /// The number of `<link>` candidates worth trying before falling through. A page
    /// listing thirty icons is a page that will not produce a better one at number
    /// thirty-one.
    private static let maximumLinkCandidates = 6

    private static let htmlAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    private static let imageAccept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"

    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        // Nothing is stored between requests: no cookies going out, none kept, no cache
        // on disk. A logo fetch should leave no trace in the container but the PNG.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A default `URLSession` user agent gets a 403 from a good half of the sites in
        // a real subscription list. This is not a disguise — the request is exactly what
        // it appears to be, a fetch of one public icon — it is the string those sites
        // are willing to answer.
        configuration.httpAdditionalHeaders = [
            "User-Agent": """
            Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 \
            (KHTML, like Gecko) Version/17.0 Safari/605.1.15
            """,
            "Accept-Language": "en;q=0.9"
        ]
        session = URLSession(configuration: configuration)
    }

    // MARK: - Fetching

    /// The best logo found for `domain`, as PNG-or-whatever bytes for `LogoStore` to
    /// re-encode, or `nil` when the domain has nothing usable to offer; and the site's
    /// own dark-mode version of it when its home page declares one
    /// (`<link rel="icon" media="(prefers-color-scheme: dark)">`). The dark one costs no
    /// extra page request: it comes from the same home page, and only its own file is
    /// downloaded. Nothing else guesses at a dark version.
    ///
    /// Never throws: a fetch that fails is a subscription that keeps its letter, which
    /// is a perfectly good outcome and not worth an error path at every call site.
    func fetchWithDarkVariant(domain: String, allowGoogleFallback: Bool) async -> (logo: Data?, dark: Data?) {
        guard let host = Subscription.normalizedDomain(domain) else { return (nil, nil) }

        let page = await iconLinkCandidates(forHost: host)
        let logo = await bestLogo(host: host, pageLinks: page.regular, allowGoogleFallback: allowGoogleFallback)
        guard logo != nil else { return (nil, nil) }
        return (logo, await bestDarkImage(page.dark))
    }

    /// Only the site's own dark-mode icon, for a logo already on disk: one home-page
    /// request, then that icon's file. `nil` when the site declares none, which is most.
    func fetchDarkVersion(domain: String) async -> Data? {
        guard let host = Subscription.normalizedDomain(domain) else { return nil }
        return await bestDarkImage(await iconLinkCandidates(forHost: host).dark)
    }

    private func bestDarkImage(_ links: [URL]) async -> Data? {
        var fallback: Data?
        for url in links.prefix(Self.maximumLinkCandidates) {
            guard !Task.isCancelled else { return nil }
            guard let data = await iconData(from: url), let image = NSImage(data: data) else { continue }
            let side = LogoImage.largestSide(of: image)
            guard side >= LogoStore.minimumDimension else { continue }

            if side >= Self.fullSize, CalendarLogo.isClearMark(image, on: CalendarLogo.darkReference) { return data }
            if fallback == nil { fallback = data }
        }
        return fallback
    }

    private func bestLogo(host: String, pageLinks: [URL], allowGoogleFallback: Bool) async -> Data? {
        var best: (data: Data, side: Int, isClearMark: Bool)?
        var tried = Set<URL>()

        func consider(_ candidate: Data) -> Bool {
            guard let image = NSImage(data: candidate) else { return false }
            let side = LogoImage.largestSide(of: image)
            guard side >= LogoStore.minimumDimension else { return false }

            let isClearMark = side >= Self.fullSize && CalendarLogo.isClearMark(image)
            let outranksCurrent = best.map { current in
                isClearMark == current.isClearMark ? side > current.side : isClearMark
            } ?? true
            if outranksCurrent {
                best = (candidate, side, isClearMark)
            }
            return isClearMark && side >= Self.goodEnough
        }

        for url in pageLinks.prefix(Self.maximumLinkCandidates) {
            guard !Task.isCancelled else { return best?.data }
            guard tried.insert(url).inserted, let data = await iconData(from: url) else { continue }
            if consider(data) { return best?.data }
        }

        // Once we have a large site icon, only the conventional browser favicon is
        // still worth trying. Probing more touch icons would add requests for tiles.
        let knownURLs = LogoCandidates.urls(forDomain: host)
        let remaining = (best?.side ?? 0) >= Self.goodEnough
            ? knownURLs.filter { $0.lastPathComponent == "favicon.ico" }
            : knownURLs
        for url in remaining {
            guard !Task.isCancelled else { return best?.data }
            guard tried.insert(url).inserted, let data = await iconData(from: url) else { continue }
            if consider(data) { return best?.data }
        }

        #if OBOLO_DIRECT
        // Google's 128-pixel copy can improve on a missing or small site icon.
        if allowGoogleFallback,
           (best?.side ?? 0) < 64,
           let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128"),
           let data = await iconData(from: url) {
            _ = consider(data)
        }
        #endif

        return best?.data
    }

    /// The icon URLs the site's own home page declares, largest first: the regular ones,
    /// and those declared for dark mode only.
    private func iconLinkCandidates(forHost host: String) async -> (regular: [URL], dark: [URL]) {
        guard let root = URL(string: "https://\(host)/"),
              let (data, response) = await get(root, byteCap: Self.htmlByteCap, accept: Self.htmlAccept)
        else { return ([], []) }

        // Resolved against wherever the redirects landed, not against what was asked
        // for: a bare domain often ends up on `www.example.com/nl`, and a relative href
        // means something different from each.
        let base = response.url ?? root
        let html = String(decoding: data, as: UTF8.self)
        return (
            LogoCandidates.iconLinks(inHTML: html, baseURL: base).map(\.url),
            LogoCandidates.darkIconLinks(inHTML: html, baseURL: base).map(\.url)
        )
    }

    /// Bytes from a candidate URL. The ranking pass decodes them before considering them.
    private func iconData(from url: URL) async -> Data? {
        guard let (data, response) = await get(url, byteCap: Self.imageByteCap, accept: Self.imageAccept) else { return nil }
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/html") { return nil }
        return data
    }

    /// A GET that stops reading at `byteCap` and treats anything but a 2xx as nothing.
    ///
    /// Streamed rather than fetched whole so the cap is real: `data(for:)` would have
    /// downloaded the whole of a 30 MB page before this could decline it.
    private func get(_ url: URL, byteCap: Int, accept: String) async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            var data = Data()
            data.reserveCapacity(min(byteCap, 64 * 1024))
            for try await byte in bytes {
                data.append(byte)
                if data.count >= byteCap { break }
            }
            guard !data.isEmpty else { return nil }
            return (data, http)
        } catch {
            // Refused, timed out, no such host, cancelled: all the same answer here.
            return nil
        }
    }
}
