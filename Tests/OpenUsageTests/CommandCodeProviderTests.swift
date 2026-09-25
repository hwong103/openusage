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
        assertProgress(mapped.lines[0], used: 0, limit: 14)
        assertProgress(mapped.lines[1], used: 0, limit: 35)
        assertProgress(mapped.lines[2], used: 70, limit: 70)
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
            "commandcode.balance", "commandcode.requests"
        ])
        XCTAssertEqual(snapshot.plan, "GOAT")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Monthly", "Requests", "Balance"])
        for request in http.requests.dropFirst() {
            XCTAssertEqual(commandCodeQuery(request.url)["orgId"], "org-42")
        }
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
            usageClient: CommandCodeUsageClient(http: http)
        )
    }
}

private enum CommandCodeFixtures {
    static let periodStart = "2026-08-29T00:08:17.000Z"
    static let periodEnd = "2026-09-29T00:08:17.000Z"

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

    static func summary() -> Data {
        Data(#"""
        {"totalCount":18895,"totalCost":74.906867302,"totalMonthlyCredits":70,"totalPurchasedCredits":4.906867302,"totalFreeCredits":0}
        """#.utf8)
    }
}

private func commandCodeQuery(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap {
        item in item.value.map { (item.name, $0) }
    })
}

private func assertProgress(_ line: MetricLine, used: Double, limit: Double) {
    guard case .progress(_, let actualUsed, let actualLimit, _, _, _, _) = line else {
        return XCTFail("Expected progress line")
    }
    XCTAssertEqual(actualUsed, used, accuracy: 0.000001)
    XCTAssertEqual(actualLimit, limit, accuracy: 0.000001)
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

private extension HTTPResponse {
    static func commandCodeOK(_ body: Data) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: body)
    }
}
