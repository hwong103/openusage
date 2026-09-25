import Foundation

@MainActor
final class CommandCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "commandcode",
        displayName: "Command Code",
        icon: .providerMark("commandcode"),
        links: [
            ProviderLink(label: "Usage", url: "https://commandcode.ai/usage"),
            ProviderLink(label: "Dashboard", url: "https://commandcode.ai/studio")
        ]
    )

    let authStore: CommandCodeAuthStore
    let usageClient: CommandCodeUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: CommandCodeAuthStore = CommandCodeAuthStore(),
        usageClient: CommandCodeUsageClient = CommandCodeUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(
                id: "commandcode.session",
                provider: provider,
                title: "Session",
                sessionStartSignal: .zeroUsage
            )
            .exportingLimit("session", unit: "usd"),
            .percent(id: "commandcode.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "usd"),
            .percent(id: "commandcode.monthly", provider: provider, title: "Monthly")
                .exportingLimit("monthly", unit: "usd"),
            .dollarBalance(
                id: "commandcode.balance",
                provider: provider,
                title: "Balance",
                valueWord: "left"
            )
            .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .values(
                id: "commandcode.requests",
                provider: provider,
                title: "Requests",
                selection: .kind(.count),
                isUsagePeriod: true,
                traySuffix: "requests"
            )
            .exportingLimit("requests", unit: "requests", source: .value(kind: .count))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in
            do {
                return try authStore.loadAuth() != nil
            } catch {
                return authStore.hasCredentialMaterial()
            }
        }
    }

    func refresh() async -> ProviderSnapshot {
        let auth: CommandCodeAuth
        do {
            guard let loaded = try await loadOffMainActor({ [authStore] in try authStore.loadAuth() }) else {
                return ProviderSnapshot.error(provider: provider, error: CommandCodeAuthError.notLoggedIn)
            }
            auth = loaded
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        do {
            let whoami = try await load { try await usageClient.fetchWhoami(apiKey: auth.apiKey) }
            let organizationID = try CommandCodeUsageMapper.organizationID(from: whoami)
            let credits = try await load {
                try await usageClient.fetchCredits(apiKey: auth.apiKey, organizationID: organizationID)
            }

            var warnings: [String] = []
            let subscription: CommandCodeSubscriptionContext?
            do {
                let body = try await load {
                    try await usageClient.fetchSubscription(apiKey: auth.apiKey, organizationID: organizationID)
                }
                subscription = try CommandCodeUsageMapper.subscriptionContext(from: body)
            } catch let error as CommandCodeAuthError {
                return ProviderSnapshot.error(provider: provider, error: error)
            } catch {
                subscription = nil
                warnings.append("Couldn't read your Command Code plan.")
                AppLog.warn(.refresh, "Command Code plan lookup failed (\(error.localizedDescription))")
            }

            let summary: Data?
            if let subscription {
                do {
                    summary = try await load {
                        try await usageClient.fetchUsageSummary(
                            apiKey: auth.apiKey,
                            organizationID: organizationID,
                            since: subscription.currentPeriodStart
                        )
                    }
                } catch let error as CommandCodeAuthError {
                    return ProviderSnapshot.error(provider: provider, error: error)
                } catch {
                    summary = nil
                    warnings.append("Couldn't read Command Code requests and monthly usage.")
                    AppLog.warn(.refresh, "Command Code usage summary failed (\(error.localizedDescription))")
                }
            } else {
                summary = nil
            }

            let mapped = try CommandCodeUsageMapper.map(
                creditsBody: credits,
                summaryBody: summary,
                subscription: subscription
            )
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now(),
                warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func load(_ request: () async throws -> HTTPResponse) async throws -> Data {
        do {
            let response = try await request()
            if response.statusCode == 401 || response.statusCode == 403 {
                throw CommandCodeAuthError.sessionExpired
            }
            guard (200..<300).contains(response.statusCode) else {
                throw CommandCodeUsageError.requestFailed(response.statusCode)
            }
            guard !response.body.isEmpty else { throw CommandCodeUsageError.invalidResponse }
            return response.body
        } catch let error as CommandCodeAuthError {
            throw error
        } catch let error as CommandCodeUsageError {
            throw error
        } catch {
            throw CommandCodeUsageError.connectionFailed
        }
    }
}
