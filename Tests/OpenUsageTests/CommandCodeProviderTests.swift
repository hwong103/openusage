import XCTest
@testable import OpenUsage

final class CommandCodeAuthStoreTests: XCTestCase {
    func testEnvironmentWinsThenReadsCommandCodeLoginAndRouterFallback() throws {
        let env = CommandCodeAuthStore(
            files: FakeFiles([CommandCodeAuthStore.credentialPaths[0]: #"{"apiKey":"file-key"}"#]),
            environment: FakeEnvironment(["COMMAND_CODE_API_KEY": "  env-key\n"])
        )
        XCTAssertEqual(try env.loadAuth()?.apiKey, "env-key")

        let file = CommandCodeAuthStore(
            files: FakeFiles([CommandCodeAuthStore.credentialPaths[0]: #"{"apiKey":" file-key "}"#]),
            environment: FakeEnvironment()
        )
        XCTAssertEqual(try file.loadAuth()?.apiKey, "file-key")

        let router = CommandCodeAuthStore(
            files: FakeFiles([CommandCodeAuthStore.credentialPaths[1]: "router-key\n"]),
            environment: FakeEnvironment()
        )
        XCTAssertEqual(try router.loadAuth()?.apiKey, "router-key")
    }

    func testMissingMaterialIsLogoutAndMalformedMaterialIsInvalid() throws {
        let missing = CommandCodeAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(try missing.loadAuth())

        let malformed = CommandCodeAuthStore(
            files: FakeFiles([CommandCodeAuthStore.credentialPaths[0]: #"{"apiKey":" "}"#]),
            environment: FakeEnvironment()
        )
        XCTAssertThrowsError(try malformed.loadAuth()) {
            XCTAssertEqual($0 as? CommandCodeAuthError, .invalidCredentials)
        }
    }

    func testUnreadableMaterialIsReportedButStillDetectedForEnablement() {
        let store = CommandCodeAuthStore(
            files: UnreadableFiles(present: [CommandCodeAuthStore.credentialPaths[0]]),
            environment: FakeEnvironment()
        )
        XCTAssertThrowsError(try store.loadAuth()) {
            XCTAssertEqual($0 as? CommandCodeAuthError, .credentialsUnreadable)
        }
        XCTAssertTrue(store.hasCredentialMaterial())
    }
}

final class CommandCodeUsageClientTests: XCTestCase {
    func testEndpointsAuthorizationAndQueries() async throws {
        let http = RoutingHTTPClient { _ in .commandCodeOK(Data("{}".utf8)) }
        let client = CommandCodeUsageClient(http: http)
        _ = try await client.fetchWhoami(apiKey: "secret")
        _ = try await client.fetchCredits(apiKey: "secret", organizationID: "org-42")
        _ = try await client.fetchSubscription(apiKey: "secret", organizationID: "org-42")
        _ = try await client.fetchUsageSummary(
            apiKey: "secret",
            organizationID: "org-42",
            since: "2026-08-29T00:08:17.000Z"
        )

        XCTAssertEqual(http.requests.map(\.url.path), [
            "/alpha/whoami", "/alpha/billing/credits",
            "/alpha/billing/subscriptions", "/alpha/usage/summary"
        ])
        XCTAssertTrue(http.requests.allSatisfy {
            $0.method == "GET" &&
                $0.headers["Authorization"] == "Bearer secret" &&
                $0.headers["Accept"] == "application/json" &&
                $0.headers["User-Agent"] == "OpenUsage" &&
                $0.timeout == 15
        })
        XCTAssertEqual(commandCodeQuery(http.requests[0].url), ["limits": "1"])
        XCTAssertEqual(commandCodeQuery(http.requests[1].url), ["orgId": "org-42"])
        XCTAssertEqual(commandCodeQuery(http.requests[2].url), ["orgId": "org-42"])
        XCTAssertEqual(commandCodeQuery(http.requests[3].url), [
            "orgId": "org-42",
            "since": "2026-08-29T00:08:17.000Z"
        ])
    }
}

final class CommandCodeUsageMapperTests: XCTestCase {
    func testMapsLiveShapeAndSubscription() throws {
        let subscription = try XCTUnwrap(
            CommandCodeUsageMapper.subscriptionContext(from: CommandCodeFixtures.subscription())
        )
        XCTAssertEqual(subscription.planName, "GOAT")
        XCTAssertEqual(subscription.currentPeriodStart, CommandCodeFixtures.periodStart)

        let mapped = try CommandCodeUsageMapper.map(
            creditsBody: CommandCodeFixtures.credits(),
            summaryBody: CommandCodeFixtures.summary(),
            subscription: subscription
        )
        XCTAssertEqual(mapped.plan, "GOAT")
        XCTAssertEqual(mapped.lines.map(\.label), ["Session", "Weekly", "Monthly", "Requests", "Balance"])
        // Windows report dollar caps ($14 / $35) but render as percentage-used meters: 0 of $14 and
        // 0 of $35 are 0%, and a fully spent $70 month is 100%.
        assertProgress(mapped.lines[0], used: 0, limit: 100, format: .percent)
        assertProgress(mapped.lines[1], used: 0, limit: 100, format: .percent)
        assertProgress(mapped.lines[2], used: 100, limit: 100, format: .percent)
        assertValue(mapped.lines[3], number: 18_895, kind: .count)
        assertValue(mapped.lines[4], number: 0.093132698, kind: .dollars)
    }

    func testSupportsWrappedPayloadsAndUnknownPlanNames() throws {
        let wrapped = Data(#"""
        {"data":{"credits":{"monthlyCredits":2,"purchasedCredits":1},"windowLimits":{"five_hour":{"used":1,"cap":4,"resetAt":1800000000000},"weekly":{"used":2,"cap":8,"resetAt":1860000000000}}}}
        """#.utf8)
        let mapped = try CommandCodeUsageMapper.map(creditsBody: wrapped, summaryBody: nil, subscription: nil)
        XCTAssertNil(mapped.plan)
        XCTAssertEqual(mapped.lines.map(\.label), ["Session", "Weekly", "Balance"])
        XCTAssertEqual(CommandCodeUsageMapper.planName(for: "individual-pro-v1"), "Pro")
        XCTAssertEqual(CommandCodeUsageMapper.planName(for: "future-plan"), "Future Plan")
    }

    func testWindowDollarsBecomePercentUsed() throws {
        // $7 of a $14 session cap is 50% used — the dollar figure never reaches the meter.
        let credits = Data(#"""
        {"credits":{"monthlyCredits":0},"windowLimits":{"limited":true,"fiveHour":{"used":7,"cap":14,"resetAt":0},"weekly":{"used":35,"cap":35,"resetAt":0}}}
        """#.utf8)
        let mapped = try CommandCodeUsageMapper.map(creditsBody: credits, summaryBody: nil, subscription: nil)
        XCTAssertEqual(mapped.lines.map(\.label), ["Session", "Weekly", "Balance"])
        assertProgress(mapped.lines[0], used: 50, limit: 100, format: .percent)
        assertProgress(mapped.lines[1], used: 100, limit: 100, format: .percent)
        // Extra credit is money, so it stays a dollar value.
        assertValue(mapped.lines[2], number: 0, kind: .dollars)
    }

    func testRejectsInvalidCapsAndUnauthorizedResponse() throws {
        let subscription = try XCTUnwrap(
            CommandCodeUsageMapper.subscriptionContext(from: CommandCodeFixtures.subscription())
        )
        let credits = Data(#"""
        {"credits":{"monthlyCredits":0},"windowLimits":{"limited":true,"fiveHour":{"used":1,"cap":0,"resetAt":0},"weekly":{"used":0,"cap":35,"resetAt":0}}}
        """#.utf8)
        XCTAssertThrowsError(try CommandCodeUsageMapper.map(
            creditsBody: credits,
            summaryBody: CommandCodeFixtures.summary(),
            subscription: subscription
        )) {
            XCTAssertEqual($0 as? CommandCodeUsageError, .invalidResponse)
        }
    }
}

@MainActor
final class CommandCodeProviderTests: XCTestCase {
    private var createdDirectories: [URL] = []

    override func tearDown() {
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdDirectories = []
        super.tearDown()
    }

    func testSuccessfulRefreshUsesOrganizationAndPeriodSummary() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/alpha/whoami": .commandCodeOK(CommandCodeFixtures.whoami(orgID: "org-42"))
            case "/alpha/billing/credits": .commandCodeOK(CommandCodeFixtures.credits())
            case "/alpha/billing/subscriptions": .commandCodeOK(CommandCodeFixtures.subscription())
            case "/alpha/usage/summary": .commandCodeOK(CommandCodeFixtures.summary())
            default: HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(http: http)
        let snapshot = await provider.refresh()

        XCTAssertEqual(provider.provider.id, "commandcode")
        XCTAssertEqual(provider.provider.displayName, "Command Code")
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), [
            "commandcode.session", "commandcode.weekly", "commandcode.monthly",
            "commandcode.balance", "commandcode.requests", "commandcode.trend",
            "commandcode.today", "commandcode.yesterday", "commandcode.last30"
        ])
        XCTAssertEqual(snapshot.plan, "GOAT")
        XCTAssertNil(snapshot.errorCategory)
        // This stub answers every summary window with the same period body, so Today and Last 30 Days
        // both carry it and Yesterday's overlap is empty. `testSpendWindowsDriveTheSharedSpendTiles`
        // covers the real per-window shaping.
        XCTAssertEqual(snapshot.lines.map(\.label), [
            "Session", "Weekly", "Monthly", "Requests", "Balance", "Today", "Last 30 Days", "Usage Trend"
        ])
        for request in http.requests.dropFirst() {
            XCTAssertEqual(commandCodeQuery(request.url)["orgId"], "org-42")
        }
    }

    /// The billing API exposes only a cumulative-from-`since` total, snapped to a UTC day, so the three
    /// spend rows are built from three windows and yesterday comes out of the overlap.
    func testSpendWindowsDriveTheSharedSpendTiles() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/alpha/whoami": .commandCodeOK(CommandCodeFixtures.whoami())
            case "/alpha/billing/credits": .commandCodeOK(CommandCodeFixtures.credits())
            case "/alpha/billing/subscriptions": .commandCodeOK(CommandCodeFixtures.subscription())
            case "/alpha/usage/summary":
                switch commandCodeQuery(request.url)["since"] ?? "" {
                case CommandCodeFixtures.periodStart:
                    .commandCodeOK(CommandCodeFixtures.summary())
                case "2026-10-04T00:00:00.000Z":
                    .commandCodeOK(CommandCodeFixtures.summary(totalCost: 1.25, totalTokens: 135_000_000))
                case "2026-10-03T00:00:00.000Z":
                    .commandCodeOK(CommandCodeFixtures.summary(totalCost: 3.50, totalTokens: 370_000_000))
                case "2026-09-04T00:00:00.000Z":
                    .commandCodeOK(CommandCodeFixtures.summary(totalCost: 43.00, totalTokens: 7_000_000_000))
                default:
                    HTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            default: HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.lines[5...7].map(\.label), ["Today", "Yesterday", "Last 30 Days"])
        assertSpend(snapshot.lines[5], costUSD: 1.25, tokens: 135_000_000)
        assertSpend(snapshot.lines[6], costUSD: 2.25, tokens: 235_000_000)
        assertSpend(snapshot.lines[7], costUSD: 43.00, tokens: 7_000_000_000)
        for line in snapshot.lines[5...7] {
            guard case .values(_, let values, _, _, _, _) = line else { return XCTFail("Expected values line") }
            XCTAssertEqual(values.map(\.kind), [.dollars, .count])
            // Billed credits, not a local estimate — the ring must not flag Command Code with the ⓘ.
            XCTAssertEqual(values.map(\.estimated), [false, false])
            XCTAssertEqual(values.map(\.label), [nil, "tokens"] as [String?])
        }
        // The persisted day series appends the Usage Trend row last, after the spend tiles.
        guard case .chart(let label, let points, let note) = snapshot.lines.last else {
            return XCTFail("Expected the Usage Trend chart last")
        }
        XCTAssertEqual(label, "Usage Trend")
        XCTAssertEqual(note, "From Command Code's usage API")
        XCTAssertTrue(points.contains { $0.value > 0 })
    }

    /// A failed spend window costs only its own row: the meters above it still render, and the user gets
    /// a warning instead of a silently short ring.
    func testMissingSpendWindowDropsRowsAndWarns() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/alpha/whoami": .commandCodeOK(CommandCodeFixtures.whoami())
            case "/alpha/billing/credits": .commandCodeOK(CommandCodeFixtures.credits())
            case "/alpha/billing/subscriptions": .commandCodeOK(CommandCodeFixtures.subscription())
            case "/alpha/usage/summary" where commandCodeQuery(request.url)["since"] == CommandCodeFixtures.periodStart:
                .commandCodeOK(CommandCodeFixtures.summary())
            default: HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Monthly", "Requests", "Balance"])
        XCTAssertEqual(snapshot.warning, "Couldn't read Command Code spend history.")
    }

    func testNoCredentialsAndUnauthorizedHaveDistinctErrors() async {
        let noAuthHTTP = RoutingHTTPClient { _ in
            XCTFail("API must not be called without credentials")
            return .commandCodeOK(Data())
        }
        let noAuth = CommandCodeProvider(
            authStore: CommandCodeAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: CommandCodeUsageClient(http: noAuthHTTP)
        )
        let unauthorized = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let noAuthSnapshot = await noAuth.refresh()
        let unauthorizedSnapshot = await makeProvider(http: unauthorized).refresh()

        XCTAssertEqual(noAuthSnapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(unauthorizedSnapshot.errorCategory, .authExpired)
        XCTAssertTrue(noAuthHTTP.requests.isEmpty)
    }

    func testLocalCredentialProbeUsesRouterFallbackWithoutNetwork() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("credential probe must not call the API")
            return .commandCodeOK(Data())
        }
        let provider = CommandCodeProvider(
            authStore: CommandCodeAuthStore(
                files: FakeFiles([CommandCodeAuthStore.credentialPaths[1]: "router-key"]),
                environment: FakeEnvironment()
            ),
            usageClient: CommandCodeUsageClient(http: http)
        )
        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
        XCTAssertTrue(http.requests.isEmpty)
    }

    private func makeProvider(http: RoutingHTTPClient) -> CommandCodeProvider {
        CommandCodeProvider(
            authStore: CommandCodeAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["COMMAND_CODE_API_KEY": "env-key"])
            ),
            usageClient: CommandCodeUsageClient(http: http),
            spendHistoryStore: makeSpendHistoryStore(),
            // Pinned so the spend windows land on fixed UTC-day floors rather than today's.
            now: { CommandCodeFixtures.spendNow }
        )
    }

    /// A store stamped for the pinned `spendNow`, so the provider skips its once-a-day 31-call backfill
    /// and the test stays about the spend rows. The directory is a fresh temp dir, so no real history is
    /// read or written.
    private func makeSpendHistoryStore() -> CommandCodeSpendHistoryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-cc-provider-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(directory)
        let store = CommandCodeSpendHistoryStore(directory: directory)
        store.merge(
            dayTotals: [:],
            backfillDay: CommandCodeSpendHistoryStore.utcDayKey(for: CommandCodeFixtures.spendNow)
        )
        return store
    }
}

private enum CommandCodeFixtures {
    static let periodStart = "2026-08-29T00:08:17.000Z"
    static let periodEnd = "2026-09-29T00:08:17.000Z"
    /// 2026-10-04T06:10:00Z, so the spend windows are 10-04, 10-03, and 09-04.
    static let spendNow = Date(timeIntervalSince1970: 1_791_094_200)

    static func whoami(orgID: String? = nil) -> Data {
        let org = orgID.map { #","org":{"id":"\#($0)"}"# } ?? ""
        return Data(#"{"success":true,"user":{"id":"private"}\#(org)}"#.utf8)
    }

    static func credits() -> Data {
        Data(#"""
        {"credits":{"monthlyCredits":0,"purchasedCredits":0.093132698,"freeCredits":0},"windowLimits":{"limited":true,"fiveHour":{"used":0,"cap":14,"resetAt":0},"weekly":{"used":0,"cap":35,"resetAt":0}}}
        """#.utf8)
    }

    static func subscription() -> Data {
        Data(#"""
        {"success":true,"data":{"status":"active","currentPeriodStart":"\#(periodStart)","currentPeriodEnd":"\#(periodEnd)","planId":"individual-goat"}}
        """#.utf8)
    }

    static func summary(
        totalCount: Double = 18_895,
        totalCost: Double = 74.906867302,
        totalTokens: Double = 425_374_525,
        totalMonthlyCredits: Double = 70,
        totalPurchasedCredits: Double = 4.906867302
    ) -> Data {
        Data(#"""
        {"totalCount":\#(totalCount),"totalCost":\#(totalCost),"totalTokens":\#(totalTokens),"totalMonthlyCredits":\#(totalMonthlyCredits),"totalPurchasedCredits":\#(totalPurchasedCredits),"totalFreeCredits":0}
        """#.utf8)
    }
}

private func commandCodeQuery(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap {
        item in item.value.map { (item.name, $0) }
    })
}

private func assertProgress(
    _ line: MetricLine,
    used: Double,
    limit: Double,
    format: ProgressFormat? = nil
) {
    guard case .progress(_, let actualUsed, let actualLimit, let actualFormat, _, _, _) = line else {
        return XCTFail("Expected progress line")
    }
    XCTAssertEqual(actualUsed, used, accuracy: 0.000001)
    XCTAssertEqual(actualLimit, limit, accuracy: 0.000001)
    if let format {
        XCTAssertEqual(actualFormat, format)
    }
}

private func assertValue(_ line: MetricLine, number: Double, kind: MetricKind) {
    guard case .values(_, let values, _, _, _, _) = line else {
        return XCTFail("Expected values line")
    }
    let value = values.first
    XCTAssertNotNil(value)
    XCTAssertEqual(value?.number ?? -1, number, accuracy: 0.000001)
    XCTAssertEqual(value?.kind, kind)
}

private func assertSpend(_ line: MetricLine, costUSD: Double, tokens: Double) {
    guard case .values(_, let values, _, _, _, _) = line else {
        return XCTFail("Expected values line")
    }
    XCTAssertEqual(values.count, 2)
    XCTAssertEqual(values.first?.number ?? -1, costUSD, accuracy: 0.000001)
    XCTAssertEqual(values.last?.number ?? -1, tokens, accuracy: 0.5)
}

private extension HTTPResponse {
    static func commandCodeOK(_ body: Data) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: body)
    }
}
