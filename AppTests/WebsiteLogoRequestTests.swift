import Foundation
import os
import Testing

@Suite("Website logo requests")
struct WebsiteLogoRequestTests {
    @Test("A logo lookup follows the site's icon link and respects the distribution's fallback")
    func requestDestinations() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogoSiteFixture.self]
        let fetcher = LogoFetcher(configuration: configuration)
        let source = "https://service.example/account?email=alice@elsewhere.example"
        let websiteURLs = [
            "https://service.example/",
            "https://assets.example/icon.png?revision=2",
            "https://service.example/apple-touch-icon.png",
            "https://service.example/apple-touch-icon-precomposed.png",
            "https://service.example/favicon.ico"
        ]

        // An imported backup may enable the direct edition's preference on a Store Mac.
        for enabled in [true, false] {
            _ = await fetcher.fetchWithDarkVariant(domain: source, allowGoogleFallback: enabled)
            var expected = websiteURLs
            #if OBOLO_DIRECT
            if enabled {
                expected.append("https://www.google.com/s2/favicons?domain=service.example&sz=128")
            }
            #endif
            let requests = LogoSiteFixture.takeRequests()
            #expect(requests.compactMap { $0.url?.absoluteString } == expected)
            #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
            #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        }

        _ = await fetcher.fetchDarkVersion(domain: source)
        #expect(LogoSiteFixture.takeRequests().compactMap { $0.url?.absoluteString } == [
            "https://service.example/",
            "https://assets.example/dark.png"
        ])
    }
}

/// Serve only the home page. The missing icons exercise every fallback without opening a connection.
private final class LogoSiteFixture: URLProtocol, @unchecked Sendable {
    private static let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())

    static func takeRequests() -> [URLRequest] {
        requests.withLock { requests in
            defer { requests.removeAll() }
            return requests
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let url = request.url!
        let isHomePage = url.absoluteString == "https://service.example/"
        let response = HTTPURLResponse(
            url: url, statusCode: isHomePage ? 200 : 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html", "Set-Cookie": "fixture=1; Path=/"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isHomePage {
            let html = """
                <link rel="icon" href="https://assets.example/icon.png?revision=2">
                <link rel="icon" media="(prefers-color-scheme: dark)" href="//assets.example/dark.png">
                """
            client?.urlProtocol(self, didLoad: Data(html.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
