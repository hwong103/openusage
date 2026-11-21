import XCTest
@testable import OpenUsage

final class CommandCodeUsageClientTests: XCTestCase {
    func testEndpointsAuthorizationAndQueries() async throws {
        let http = RoutingHTTPClient { _ in .json("{}") }
        let client = CommandCodeUsageClient(http: http)
        _ = try await client.fetchWhoami(apiKey: "secret")
        _ = try await client.fetchCredits(apiKey: "secret", organizationID: "org-42")
        _ = try await client.fetchSubscription(apiKey: "secret", organizationID: "org-42")
        _ = try await client.fetchUsageSummary(apiKey: "secret", organizationID: "org-42", since: Fixtures.periodStart)

        XCTAssertEqual(http.requests.map(\.url.path), [
            "/alpha/whoami", "/alpha/billing/credits", "/alpha/billing/subscriptions", "/alpha/usage/summary"
        ])
        XCTAssertTrue(http.requests.allSatisfy {
            $0.method == "GET" &&
                $0.headers["Authorization"] == "Bearer secret" &&
                $0.headers["Accept"] == "application/json" &&
                $0.headers["User-Agent"] == "OpenUsage" &&
                $0.timeout == 15
        })
        XCTAssertEqual(query(http.requests[0].url), ["limits": "1"])
        XCTAssertEqual(query(http.requests[1].url), ["orgId": "org-42"])
        XCTAssertEqual(query(http.requests[2].url), ["orgId": "org-42"])
        XCTAssertEqual(query(http.requests[3].url), ["orgId": "org-42", "since": Fixtures.periodStart])
    }
}

final class CommandCodeUsageMapperTests: XCTestCase {
    func testMapsLiveShapeAndSubscription() throws {
        let subscription = try XCTUnwrap(CommandCodeUsageMapper.subscriptionContext(from: Fixtures.subscription))
        XCTAssertEqual(subscription.planName, "GOAT")
        let mapped = try CommandCodeUsageMapper.map(
            creditsBody: Fixtures.credits,
            summaryBody: Fixtures.summary(),
            subscription: subscription
        )
        XCTAssertEqual(mapped.plan, "GOAT")
        XCTAssertEqual(mapped.lines.map(\.label), ["Session", "Weekly", "Monthly", "Requests", "Balance"])
        assertProgress(mapped.lines[0], used: 0)
        assertProgress(mapped.lines[1], used: 0)
        assertProgress(mapped.lines[2], used: 100)
        assertValue(mapped.lines[3], number: 18_895, kind: .count)
        assertValue(mapped.lines[4], number: 0.093132698, kind: .dollars)
    }

    func testWindowDollarsBecomePercentUsed() throws {
        let credits = Data(#"""
        {"credits":{"monthlyCredits":0},"windowLimits":{"limited":true,"fiveHour":{"used":7,"cap":14,"resetAt":0},"weekly":{"used":35,"cap":35,"resetAt":0}}}
        """#.utf8)
        let mapped = try CommandCodeUsageMapper.map(creditsBody: credits, summaryBody: nil, subscription: nil)
        XCTAssertEqual(mapped.lines.map(\.label), ["Session", "Weekly", "Balance"])
        assertProgress(mapped.lines[0], used: 50)
        assertProgress(mapped.lines[1], used: 100)
        assertValue(mapped.lines[2], number: 0, kind: .dollars)
        XCTAssertEqual(CommandCodeUsageMapper.planName(for: "future-plan"), "Future Plan")
    }

    func testRejectsInvalidCaps() throws {
        let subscription = try XCTUnwrap(CommandCodeUsageMapper.subscriptionContext(from: Fixtures.subscription))
        let credits = Data(#"""
        {"credits":{"monthlyCredits":0},"windowLimits":{"limited":true,"fiveHour":{"used":1,"cap":0,"resetAt":0},"weekly":{"used":0,"cap":35,"resetAt":0}}}
        """#.utf8)
        XCTAssertThrowsError(try CommandCodeUsageMapper.map(
            creditsBody: credits, summaryBody: Fixtures.summary(), subscription: subscription
        )) {
            XCTAssertEqual($0 as? ProviderError, .invalidResponse)
        }
    }
}

@MainActor
final class CommandCodeRuntimeTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        super.tearDown()
    }

    func testAccountOwnedProviderMapsUsageAndHistory() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/alpha/whoami": .json(String(decoding: Fixtures.whoami, as: UTF8.self))
            case "/alpha/billing/credits": .json(String(decoding: Fixtures.credits, as: UTF8.self))
            case "/alpha/billing/subscriptions": .json(String(decoding: Fixtures.subscription, as: UTF8.self))
            case "/alpha/usage/summary":
                switch query(request.url)["since"] {
                case Fixtures.periodStart:
                    .json(String(decoding: Fixtures.summary(), as: UTF8.self))
                case "2026-10-04T00:00:00.000Z":
                    .json(String(decoding: Fixtures.summary(totalCost: 1.25, totalTokens: 135_000_000), as: UTF8.self))
                case "2026-10-03T00:00:00.000Z":
                    .json(String(decoding: Fixtures.summary(totalCost: 3.5, totalTokens: 370_000_000), as: UTF8.self))
                case "2026-09-04T00:00:00.000Z":
                    .json(String(decoding: Fixtures.summary(totalCost: 43, totalTokens: 7_000_000_000), as: UTF8.self))
                default:
                    HTTPResponse(statusCode: 500, headers: [:], body: Data())
                }
            default: HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let account = Account(kind: .commandcode, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("secret"), for: account.id)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { Fixtures.now })
        XCTAssertEqual(runtime.provider.id, account.cardID)
        XCTAssertEqual(runtime.provider.displayName, "Command Code")
        XCTAssertEqual(runtime.widgetDescriptors.map(\.key), [
            "session", "weekly", "monthly", "balance", "requests", "today", "yesterday", "last30"
        ])

        let snapshot = try await runtime.refresh().get()
        XCTAssertEqual(snapshot.providerID, account.cardID)
        XCTAssertEqual(snapshot.plan, "GOAT")
        XCTAssertNil(snapshot.notice)
        XCTAssertEqual(snapshot.lines.map(\.label), [
            "Session", "Weekly", "Monthly", "Requests", "Balance", "Today", "Yesterday", "Last 30 Days"
        ])
        assertSpend(snapshot.lines[5], cost: 1.25, tokens: 135_000_000)
        assertSpend(snapshot.lines[6], cost: 2.25, tokens: 235_000_000)
        assertSpend(snapshot.lines[7], cost: 3.5, tokens: 370_000_000)
        XCTAssertEqual(snapshot.usageBreakdowns?["today"]?.totals[.spend], 1.25)
        XCTAssertEqual(snapshot.usageBreakdowns?["last30"]?.totals[.tokens], 370_000_000)
    }

    func testMissingSpendWindowKeepsMetersAndReportsWarning() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/alpha/whoami": .json(String(decoding: Fixtures.whoami, as: UTF8.self))
            case "/alpha/billing/credits": .json(String(decoding: Fixtures.credits, as: UTF8.self))
            case "/alpha/billing/subscriptions": .json(String(decoding: Fixtures.subscription, as: UTF8.self))
            case "/alpha/usage/summary" where query(request.url)["since"] == Fixtures.periodStart:
                .json(String(decoding: Fixtures.summary(), as: UTF8.self))
            default: HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let account = Account(kind: .commandcode, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("secret"), for: account.id)
        let snapshot = try await AccountProviderRuntime(
            account: account, vault: vault, http: http, now: { Fixtures.now }
        ).refresh().get()
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Monthly", "Requests", "Balance"])
        XCTAssertEqual(snapshot.notice, "Couldn't read Command Code spend history.")
    }

    func testUnauthorizedAndMissingCredentialsHaveDistinctFailures() async {
        let missing = Account(kind: .commandcode, label: "Missing")
        let missingResult = await AccountProviderRuntime(
            account: missing, vault: InMemoryCredentialVault()
        ).refresh()
        XCTAssertEqual(missingResult.failure?.message, ProviderError.keyRejected("Command Code rejected the API key.").localizedDescription)

        let account = Account(kind: .commandcode, label: "Rejected")
        let vault = InMemoryCredentialVault()
        try? vault.save(.apiKey("bad"), for: account.id)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let rejected = await AccountProviderRuntime(account: account, vault: vault, http: http).refresh()
        XCTAssertEqual(rejected.failure?.message, ProviderError.keyRejected("Command Code rejected the API key.").localizedDescription)
    }

    func testAPILoginAcceptsAProviderKey() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/alpha/whoami": .json(String(decoding: Fixtures.whoami, as: UTF8.self))
            case "/alpha/billing/credits": .json(String(decoding: Fixtures.credits, as: UTF8.self))
            case "/alpha/billing/subscriptions": .json(String(decoding: Fixtures.subscription, as: UTF8.self))
            case "/alpha/usage/summary": .json(String(decoding: Fixtures.summary(), as: UTF8.self))
            default: HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let login = APIKeyLogin(kind: .commandcode, http: http)
        let stream = AsyncStream<String> { continuation in
            continuation.yield("secret")
            continuation.finish()
        }
        let result = try await login.login(prompt: { _ in }, pastedCode: stream)
        XCTAssertEqual(result.label, "Command Code")
        XCTAssertEqual(result.credential, AccountCredential.apiKey("secret"))
    }
}

private enum Fixtures {
    static let periodStart = "2026-08-29T00:08:17.000Z"
    static let periodEnd = "2026-09-29T00:08:17.000Z"
    static let now = Date(timeIntervalSince1970: 1_791_094_200)

    static let whoami = Data(#"{"success":true,"user":{"id":"private"},"org":{"id":"org-42"}}"#.utf8)
    static let credits = Data(#"""
    {"credits":{"monthlyCredits":0,"purchasedCredits":0.093132698,"freeCredits":0},"windowLimits":{"limited":true,"fiveHour":{"used":0,"cap":14,"resetAt":0},"weekly":{"used":0,"cap":35,"resetAt":0}}}
    """#.utf8)
    static let subscription = Data(#"""
    {"success":true,"data":{"status":"active","currentPeriodStart":"2026-08-29T00:08:17.000Z","currentPeriodEnd":"2026-09-29T00:08:17.000Z","planId":"individual-goat"}}
    """#.utf8)

    static func summary(totalCount: Double = 18_895, totalCost: Double = 74.906867302,
                        totalTokens: Double = 425_374_525, totalMonthlyCredits: Double = 70) -> Data {
        Data(#"{"totalCount":\#(totalCount),"totalCost":\#(totalCost),"totalTokens":\#(totalTokens),"totalMonthlyCredits":\#(totalMonthlyCredits)}"#.utf8)
    }
}

private func query(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })
}

private func assertProgress(_ line: MetricLine, used: Double) {
    guard case .progress(_, let actual, let limit, let format, _, _) = line else {
        return XCTFail("Expected progress")
    }
    XCTAssertEqual(actual, used)
    XCTAssertEqual(limit, 100)
    XCTAssertEqual(format, .percent)
}

private func assertValue(_ line: MetricLine, number: Double, kind: MetricKind) {
    guard case .values(_, let values, _) = line else { return XCTFail("Expected values") }
    XCTAssertEqual(values.first?.number ?? -1, number, accuracy: 0.000001)
    XCTAssertEqual(values.first?.kind, kind)
}

private func assertSpend(_ line: MetricLine, cost: Double, tokens: Double) {
    guard case .values(_, let values, _) = line else { return XCTFail("Expected spend") }
    XCTAssertEqual(values.count, 2)
    XCTAssertEqual(values[0].number, cost, accuracy: 0.000001)
    XCTAssertEqual(values[1].number, tokens, accuracy: 0.5)
}
