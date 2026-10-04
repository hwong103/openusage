import Foundation

struct CommandCodeUsageClient: Sendable {
    static let apiBaseURL = URL(string: "https://api.commandcode.ai")!
    static let whoamiURL = apiBaseURL.appending(path: "alpha/whoami")
    static let creditsURL = apiBaseURL.appending(path: "alpha/billing/credits")
    static let subscriptionsURL = apiBaseURL.appending(path: "alpha/billing/subscriptions")
    static let usageSummaryURL = apiBaseURL.appending(path: "alpha/usage/summary")

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchWhoami(apiKey: String) async throws -> HTTPResponse {
        try await get(
            Self.whoamiURL,
            apiKey: apiKey,
            query: [URLQueryItem(name: "limits", value: "1")]
        )
    }

    func fetchCredits(apiKey: String, organizationID: String?) async throws -> HTTPResponse {
        try await get(Self.creditsURL, apiKey: apiKey, query: organizationQuery(organizationID))
    }

    func fetchSubscription(apiKey: String, organizationID: String?) async throws -> HTTPResponse {
        try await get(Self.subscriptionsURL, apiKey: apiKey, query: organizationQuery(organizationID))
    }

    func fetchUsageSummary(apiKey: String, organizationID: String?, since: String) async throws -> HTTPResponse {
        var query = organizationQuery(organizationID)
        query.append(URLQueryItem(name: "since", value: since))
        return try await get(Self.usageSummaryURL, apiKey: apiKey, query: query)
    }

    private func organizationQuery(_ organizationID: String?) -> [URLQueryItem] {
        let organizationID = organizationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let organizationID, !organizationID.isEmpty else { return [] }
        return [URLQueryItem(name: "orgId", value: organizationID)]
    }

    private func get(
        _ baseURL: URL,
        apiKey: String,
        query: [URLQueryItem] = []
    ) async throws -> HTTPResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CommandCodeUsageError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CommandCodeUsageError.invalidResponse }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json",
                "User-Agent": "OpenUsage"
            ],
            timeout: 15
        ))
    }
}

/// UTC day floors for the Command Code spend windows.
///
/// `/alpha/usage/summary` accepts only a lower bound: `until` is ignored, and the `since` instant is
/// snapped to a UTC calendar day (`2026-10-03T13:00Z` and `2026-10-03T00:00Z` return the same totals),
/// so a single day can't be requested directly and the day boundary can't be moved. The log-scanned
/// providers key their spend tiles to the local calendar day; Command Code's tiles are therefore
/// UTC-day aligned, which shifts their boundary for users far from UTC. That is an API limitation, not
/// a rounding choice — see `docs/providers/command-code.md`.
enum CommandCodeSpendWindow {
    /// The API rejects offsets such as `+11:00`, so windows are only expressible in UTC.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// Midnight UTC `offsetDays` before the UTC day containing `now`, as the ISO-8601 string the API
    /// requires. `offsetDays: 0` is the start of today (UTC), `1` the start of yesterday.
    static func since(offsetDays: Int, from now: Date, calendar: Calendar = utcCalendar) -> String {
        let startOfDay = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -offsetDays, to: startOfDay) ?? startOfDay
        return OpenUsageISO8601.string(from: day)
    }
}

enum CommandCodeUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed: ProviderUsageErrorText.connectionFailed
        case .invalidResponse: ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status): ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}
