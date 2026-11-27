import Foundation
import Testing
@testable import OboloCore

/// Everything the logo feature does that can be decided without a network: which domain
/// a subscription is *about*, how an icon that is a file survives a round trip through
/// the store, and which URLs are worth asking for.
@Suite("Logos")
struct LogoTests {

    // MARK: - Domains

    @Test("A website is reduced to a bare host however it was pasted")
    func websiteNormalisation() {
        #expect(Subscription.normalizedDomain("netflix.com") == "netflix.com")
        #expect(Subscription.normalizedDomain("  Netflix.COM  ") == "netflix.com")
        #expect(Subscription.normalizedDomain("https://www.netflix.com") == "netflix.com")
        #expect(Subscription.normalizedDomain("http://netflix.com/browse") == "netflix.com")
        #expect(Subscription.normalizedDomain("https://www.my-service.com/en/memberships?x=1#top") == "my-service.com")
        #expect(Subscription.normalizedDomain("open.spotify.com") == "open.spotify.com")
        #expect(Subscription.normalizedDomain("https://user:pass@example.com:8443/x") == "example.com")
        #expect(Subscription.normalizedDomain("netflix.com.") == "netflix.com")
        // Not a host: a half-typed name, a sentence someone put in the wrong column.
        #expect(Subscription.normalizedDomain("netflix") == nil)
        #expect(Subscription.normalizedDomain("ask them at the desk") == nil)
        #expect(Subscription.normalizedDomain("") == nil)
        #expect(Subscription.normalizedDomain(nil) == nil)
    }

    @Test("Assigning a website normalises it, in the initialiser and afterwards")
    func websiteIsNormalisedOnEveryWrite() {
        var subscription = Fixed.subscription("Netflix")
        subscription.website = "HTTPS://WWW.Netflix.com/browse"
        #expect(subscription.website == "netflix.com")

        let built = Subscription(
            name: "Dropbox Plus",
            categoryID: Category.unknown.id,
            price: 11.99,
            currency: "EUR",
            cycle: .monthly,
            website: "https://www.dropbox.com/plans"
        )
        #expect(built.website == "dropbox.com")
    }

    @Test("A subscription with only a manage link still knows its domain")
    func effectiveDomainFallsBackToTheManageLink() {
        var subscription = Fixed.subscription("NordVPN")
        #expect(subscription.effectiveDomain == nil)

        subscription.manageURL = URL(string: "https://my.nordvpn.com/account/subscriptions")
        #expect(subscription.effectiveDomain == "my.nordvpn.com")

        // An explicit website always wins over one derived from a link.
        subscription.website = "nordvpn.com"
        #expect(subscription.effectiveDomain == "nordvpn.com")
    }

    // MARK: - The icon case

    @Test("An image icon encodes to one string and comes back")
    func imageIconRoundTrips() throws {
        let icon = Icon.image("3F2A1B00-0000-4000-B000-000000000001.png")
        #expect(icon.encoded == "image:3F2A1B00-0000-4000-B000-000000000001.png")
        #expect(Icon(encoded: icon.encoded) == icon)
        #expect(icon.imageFilename == "3F2A1B00-0000-4000-B000-000000000001.png")
        #expect(Icon.initial.imageFilename == nil)

        let data = try JSONEncoder().encode(icon)
        #expect(try JSONDecoder().decode(Icon.self, from: data) == icon)
    }

    @Test("The older three cases are untouched, and an unknown one still renders")
    func iconDecodingIsBackwardCompatible() {
        #expect(Icon(encoded: "initial") == .initial)
        #expect(Icon(encoded: "emoji:🏋️") == .emoji("🏋️"))
        #expect(Icon(encoded: "symbol:figure.run") == .symbol("figure.run"))
        #expect(Icon(encoded: "image:") == .initial)
        #expect(Icon(encoded: "hologram:x") == .initial)
    }

    @Test("A letter icon keeps its colour, and an unknown colour falls back to the initial")
    func letterIconRoundTrips() throws {
        for color in LetterColor.allCases {
            let icon = Icon.letter(color)
            #expect(icon.encoded == "letter:\(color.rawValue)")
            #expect(Icon(encoded: icon.encoded) == icon)
            #expect(try JSONDecoder().decode(Icon.self, from: JSONEncoder().encode(icon)) == icon)
        }
        #expect(Icon(encoded: "letter:chartreuse") == .initial)
        #expect(Icon(encoded: "letter:") == .initial)
        #expect(Icon.letter(.rose).imageFilename == nil)
    }

    @Test("Only a name the icon store could have written is accepted")
    func imageFilenamesAreValidated() {
        #expect(Icon.isValidImageFilename("3F2A1B00-0000-4000-B000-000000000001.png"))
        #expect(Icon.isValidImageFilename("3f2a1b00-0000-4000-b000-000000000001.png"))
        #expect(Icon.isValidImageFilename(UUID().uuidString + ".png"))

        // A path, a parent segment, an extension the app does not write, a bare word.
        #expect(!Icon.isValidImageFilename("../obolo.json"))
        #expect(!Icon.isValidImageFilename("/etc/x.png"))
        #expect(!Icon.isValidImageFilename("a/b.png"))
        #expect(!Icon.isValidImageFilename("3F2A1B00-0000-4000-B000-000000000001.PNG"))
        #expect(!Icon.isValidImageFilename("../3F2A1B00-0000-4000-B000-000000000001.png"))
        #expect(!Icon.isValidImageFilename("logo.png"))
        #expect(!Icon.isValidImageFilename(".png"))
        #expect(!Icon.isValidImageFilename(""))
    }

    @Test("An image name that could point outside the icons folder decodes as an initial")
    func traversalNamesDecodeAsInitial() throws {
        #expect(Icon(encoded: "image:../obolo.json") == .initial)
        #expect(Icon(encoded: "image:/etc/x.png") == .initial)
        #expect(Icon(encoded: "image:a/b.png") == .initial)
        #expect(Icon(encoded: "image:../3F2A1B00-0000-4000-B000-000000000001.png") == .initial)
        #expect(Icon(encoded: "image:3F2A1B00-0000-4000-B000-000000000001.PNG") == .initial)
        // The one shape that survives, whichever case it is written in.
        #expect(Icon(encoded: "image:3F2A1B00-0000-4000-B000-000000000001.png")
                == .image("3F2A1B00-0000-4000-B000-000000000001.png"))

        // JSON and CSV read the same string through the same door, so both are covered.
        let hostile = Data(#""image:../../obolo.json""#.utf8)
        #expect(try JSONDecoder().decode(Icon.self, from: hostile) == .initial)

        let imported = try CSVImporter.preview(
            data: Data("Name,Price,Billing cycle,Icon\nThing,10.00,Monthly,image:../obolo.json\n".utf8),
            document: Fixed.document(),
            calendar: Fixed.calendar,
            locale: Fixed.locale,
            now: Fixed.today
        )
        #expect(imported.rows.first?.subscription?.icon == .initial)
    }

    @Test("A subscription written with a website reads back with it, and one without decodes fine")
    func websiteSurvivesTheStore() throws {
        var subscription = Fixed.subscription("Netflix")
        subscription.website = "netflix.com"
        subscription.icon = .image("\(subscription.id.uuidString).png")

        let data = try DocumentStore.makeEncoder().encode(subscription)
        let decoded = try DocumentStore.makeDecoder().decode(Subscription.self, from: data)
        #expect(decoded.website == "netflix.com")
        #expect(decoded.icon == subscription.icon)

        // A 1.0 file, written before either field existed.
        let older = Data("""
        {"id":"\(subscription.id.uuidString)","name":"Netflix","price":13.99,"currency":"EUR"}
        """.utf8)
        let old = try DocumentStore.makeDecoder().decode(Subscription.self, from: older)
        #expect(old.website == nil)
        #expect(old.icon == .initial)
    }

    // MARK: - Well-known candidates

    @Test("The three well-known paths come back in order, largest first")
    func wellKnownCandidates() {
        #expect(LogoCandidates.urls(forDomain: "netflix.com").map(\.absoluteString) == [
            "https://netflix.com/apple-touch-icon.png",
            "https://netflix.com/apple-touch-icon-precomposed.png",
            "https://netflix.com/favicon.ico"
        ])
        // The argument is normalised on the way in, so a pasted URL still works.
        #expect(LogoCandidates.urls(forDomain: "https://www.Netflix.com/browse").first?.absoluteString
            == "https://netflix.com/apple-touch-icon.png")
        #expect(LogoCandidates.urls(forDomain: "not a domain").isEmpty)
    }

    @Test("The Google fallback sends the domain and a size and nothing else")
    func googleFallbackURL() {
        #expect(LogoCandidates.googleFaviconURL(domain: "spotify.com")?.absoluteString
            == "https://www.google.com/s2/favicons?domain=spotify.com&sz=128")
        #expect(LogoCandidates.googleFaviconURL(domain: "https://www.notion.so/", size: 64)?.absoluteString
            == "https://www.google.com/s2/favicons?domain=notion.so&sz=64")
        #expect(LogoCandidates.googleFaviconURL(domain: "nonsense") == nil)
    }

    // MARK: - Reading a page

    @Test("An absolute CDN href is taken as it stands")
    func absoluteHref() {
        let html = """
        <html><head>
        <link rel="apple-touch-icon" sizes="180x180" href="https://cdn.netflix.com/assets/apple-touch-icon.png">
        <link rel="icon" type="image/png" sizes="32x32" href="https://cdn.netflix.com/assets/favicon-32x32.png">
        </head></html>
        """
        let links = LogoCandidates.iconLinks(inHTML: html, baseURL: URL(string: "https://www.netflix.com/nl")!)
        #expect(links.count == 2)
        #expect(links[0].url.absoluteString == "https://cdn.netflix.com/assets/apple-touch-icon.png")
        #expect(links[0].pixelSize == 180)
        #expect(links[0].rel == .appleTouchIcon)
        #expect(links[1].pixelSize == 32)
    }

    @Test("An icon declared for dark mode is kept apart from the logo candidates")
    func darkModeIcons() {
        let html = """
        <link rel="apple-touch-icon" sizes="180x180" href="/touch.png">
        <link rel="icon" href="/favicon-light.svg" media="(prefers-color-scheme: light)">
        <link rel="icon" href="/favicon-dark.svg" media="(prefers-color-scheme: dark)">
        <LINK REL="icon" SIZES="64x64" HREF="/dark-64.png" MEDIA="(prefers-color-scheme:dark)">
        """
        let base = URL(string: "https://example.com/")!
        let regular = LogoCandidates.iconLinks(inHTML: html, baseURL: base)
        let dark = LogoCandidates.darkIconLinks(inHTML: html, baseURL: base)

        let regularNames = regular.map { $0.url.lastPathComponent }
        let darkNames = dark.map { $0.url.lastPathComponent }
        #expect(regularNames == ["touch.png", "favicon-light.svg"])
        #expect(darkNames == ["dark-64.png", "favicon-dark.svg"])
        #expect(dark.allSatisfy { $0.isDark })
        let none = LogoCandidates.darkIconLinks(inHTML: "<link rel=icon href=/f.png>", baseURL: base)
        #expect(none.isEmpty)
    }

    @Test("A ../ href resolves against the page it was found on")
    func relativeHrefWithParentSegments() {
        let html = """
        <link href="../favicons/favicon-180x180.png" rel="apple-touch-icon" sizes="180x180"/>
        <link href='../favicons/favicon-32x32.png' rel='shortcut icon'/>
        """
        let links = LogoCandidates.iconLinks(inHTML: html, baseURL: URL(string: "https://www.dropbox.com/apps/index.html")!)
        #expect(links.map(\.url.absoluteString) == [
            "https://www.dropbox.com/favicons/favicon-180x180.png",
            "https://www.dropbox.com/favicons/favicon-32x32.png"
        ])
        // The second one declared no `sizes`; its filename did.
        #expect(links[1].pixelSize == 32)
        #expect(links[1].rel == .icon)
    }

    @Test("Attribute order, quoting and case do not matter")
    func tolerantParsing() {
        let html = """
        <LINK SIZES=16x16 HREF=/favicon.ico REL=icon>
        <link
             rel = "apple-touch-icon-precomposed"
             href = "/touch.png" >
        <link rel="stylesheet" href="/site.css">
        <link rel="mask-icon" href="/mask.svg" color="#000">
        """
        let links = LogoCandidates.iconLinks(inHTML: html, baseURL: URL(string: "https://example.com/a/b")!)
        // The stylesheet and the pinned-tab silhouette are not icons for this purpose.
        #expect(links.count == 2)
        #expect(links[0].url.absoluteString == "https://example.com/touch.png")
        #expect(links[0].rel == .appleTouchIconPrecomposed)
        #expect(links[0].pixelSize == nil)
        #expect(links[1].url.absoluteString == "https://example.com/favicon.ico")
        #expect(links[1].pixelSize == 16)
    }

    @Test("The largest declared size leads, whatever order the page listed them in")
    func largestFirst() {
        let html = """
        <link rel="icon" sizes="16x16" href="/i16.png">
        <link rel="icon" sizes="192x192" href="/i192.png">
        <link rel="apple-touch-icon" href="/touch.png">
        <link rel="icon" sizes="48x48" href="/i48.png">
        """
        let links = LogoCandidates.iconLinks(inHTML: html, baseURL: URL(string: "https://example.com/")!)
        #expect(links.map(\.url.lastPathComponent) == ["i192.png", "touch.png", "i48.png", "i16.png"])
    }

    @Test("Protocol-relative and entity-escaped hrefs resolve; data: URIs are dropped")
    func awkwardHrefs() {
        let html = """
        <link rel="icon" href="//cdn.example.net/icon.png?v=2&amp;cb=9" sizes="64x64">
        <link rel="icon" href="data:image/png;base64,iVBORw0KGgo=">
        """
        let links = LogoCandidates.iconLinks(inHTML: html, baseURL: URL(string: "https://example.com/")!)
        #expect(links.count == 1)
        #expect(links[0].url.absoluteString == "https://cdn.example.net/icon.png?v=2&cb=9")
    }

    @Test("The same file listed twice is one candidate, described by the better tag")
    func duplicatesCollapse() {
        let html = """
        <link rel="icon" href="/favicon.png">
        <link rel="icon" href="/favicon.png" sizes="128x128">
        """
        let links = LogoCandidates.iconLinks(inHTML: html, baseURL: URL(string: "https://example.com/")!)
        #expect(links.count == 1)
        #expect(links[0].pixelSize == 128)
    }

    @Test("A page with no icons at all yields none rather than a guess")
    func noLinks() {
        #expect(LogoCandidates.iconLinks(inHTML: "<html><body>hi</body></html>",
                                         baseURL: URL(string: "https://example.com/")!).isEmpty)
    }

    // MARK: - The setting

    @Test("The Google fallback is on by default and survives an older document")
    func fallbackSettingDefaultsOn() throws {
        #expect(Settings().useGoogleFaviconFallback)

        let older = Data(#"{"baseCurrency":"EUR"}"#.utf8)
        let decoded = try DocumentStore.makeDecoder().decode(Settings.self, from: older)
        #expect(decoded.useGoogleFaviconFallback)

        var off = Settings()
        off.useGoogleFaviconFallback = false
        let data = try DocumentStore.makeEncoder().encode(off)
        #expect(try DocumentStore.makeDecoder().decode(Settings.self, from: data).useGoogleFaviconFallback == false)
    }
}
