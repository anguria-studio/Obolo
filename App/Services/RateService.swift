import Foundation
import OboloCore

/// The second — and last — thing in Obolo that opens a network connection.
///
/// It asks frankfurter.dev for the European Central Bank's daily reference rates: one
/// GET, no key, no account, and a query string that contains nothing but three-letter
/// currency codes. It does not say what the subscriptions are, how much they cost, or
/// who is asking. The ECB publishes once per working day around 16:00 CET, so the app
/// asks at most once a day and a Saturday's answer is Friday's number — which is why
/// the response's own `date` is what gets stored and shown, not the moment of the call.
///
/// Modelled on `LogoFetcher`: an actor with its own ephemeral session, an eight-second
/// timeout, and no cookies or cache left behind in the container.
actor RateService {

    /// What can go wrong, in the three shapes the Settings status line cares about.
    enum Failure: LocalizedError, Equatable {
        /// No route to the host: offline, asleep, a captive portal.
        case offline
        /// Answered, but not with rates — a 5xx, a proxy's login page.
        case badResponse(status: Int?)
        /// The base currency is not one of the ~30 the ECB publishes. A 404, and the
        /// one failure that will not fix itself tomorrow.
        case unsupportedBase(String)
        /// Nothing to ask about, or a base that is not a currency code.
        case nothingToFetch

        var errorDescription: String? {
            switch self {
            case .offline:
                "Obolo has no connection."
            case .badResponse(let status):
                status.map { "The rate service answered \($0)." } ?? "Obolo cannot read the answer from the rate service."
            case .unsupportedBase(let code):
                "The ECB does not publish a rate for \(code)."
            case .nothingToFetch:
                "There are no currencies to convert."
            }
        }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        // Yesterday's cached body would be indistinguishable from today's refresh
        // having worked.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: configuration)
    }

    /// The published day and the rates to multiply by, for the codes that came back.
    ///
    /// A `symbol` the service does not cover is missing from the answer rather than an
    /// error: the currency keeps no rate, and the subscription priced in it keeps the
    /// footnote saying so.
    func fetch(base: String, symbols: [String]) async throws -> (asOf: Date, ratesToBase: [String: Decimal]) {
        guard let url = RateRefresh.url(base: base, symbols: symbols) else {
            throw Failure.nothingToFetch
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff:
                throw Failure.offline
            default:
                throw Failure.badResponse(status: nil)
            }
        }

        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 { throw Failure.unsupportedBase(Subscription.normalizedCurrency(base)) }
        guard let status, (200..<300).contains(status) else {
            throw Failure.badResponse(status: status)
        }

        do {
            return try RateRefresh.parse(data: data, base: base)
        } catch {
            throw Failure.badResponse(status: status)
        }
    }
}
