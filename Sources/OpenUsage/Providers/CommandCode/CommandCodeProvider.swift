import Foundation

@MainActor
final class CommandCodeProvider: ProviderRuntime {
    /// Registry identifiers this provider's tray substitution keys on. The Monthly meter is the pool
    /// state (included allowance vs. purchased top-up credit) that decides whether a pinned Balance is
    /// redundant or the only meaningful reading, so the strip needs it whether or not it is pinned.
    static let providerID = "commandcode"
    static let sessionMetricID = "commandcode.session"
    static let weeklyMetricID = "commandcode.weekly"
    static let monthlyMetricID = "commandcode.monthly"
    static let balanceMetricID = "commandcode.balance"

    let provider = Provider(
        id: CommandCodeProvider.providerID,
        displayName: "Command Code",
        icon: .providerMark("commandcode"),
        links: [
            ProviderLink(label: "Usage", url: "https://commandcode.ai/usage"),
            ProviderLink(label: "Dashboard", url: "https://commandcode.ai/studio")
        ]
    )

    let authStore: CommandCodeAuthStore
    let usageClient: CommandCodeUsageClient
    let spendHistoryStore: CommandCodeSpendHistoryStore
    let now: @Sendable () -> Date

    init(
        authStore: CommandCodeAuthStore = CommandCodeAuthStore(),
        usageClient: CommandCodeUsageClient = CommandCodeUsageClient(),
        spendHistoryStore: CommandCodeSpendHistoryStore = CommandCodeSpendHistoryStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.spendHistoryStore = spendHistoryStore
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(
                id: CommandCodeProvider.sessionMetricID,
                provider: provider,
                title: "Session",
                sessionStartSignal: .zeroUsage
            )
            .exportingLimit("session", unit: "usd"),
            .percent(id: CommandCodeProvider.weeklyMetricID, provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "usd"),
            .percent(id: Self.monthlyMetricID, provider: provider, title: "Monthly")
                .exportingLimit("monthly", unit: "usd"),
            .dollarBalance(
                id: Self.balanceMetricID,
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
            .exportingLimit("requests", unit: "requests", source: .value(kind: .count)),
            .usageTrend(provider: provider)
        ] + WidgetDescriptor.spendTiles(provider: provider)
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

            let spend = await spendWindows(apiKey: auth.apiKey, organizationID: organizationID)
            if let warning = spend.warning { warnings.append(warning) }

            // One clock reading for the history write and the chart window, so a refresh that crosses UTC
            // midnight can't record today's total under tomorrow's key and then read it back as missing.
            let trendNow = now()
            await backfillSpendHistoryIfNeeded(
                apiKey: auth.apiKey,
                organizationID: organizationID,
                now: trendNow
            )
            await recordSpendHistory(from: spend.windows, now: trendNow)

            let mapped = try CommandCodeUsageMapper.map(
                creditsBody: credits,
                summaryBody: summary,
                subscription: subscription,
                spendWindows: spend.windows
            )
            var lines = mapped.lines
            // The day series is read from disk (I/O, off-actor) while the append stays on the actor so the
            // local `lines` buffer is never mutated from a detached closure.
            let history = await loadOffMainActor { [spendHistoryStore] in
                spendHistoryStore.series(through: trendNow)
            }
            SpendTileMapper.appendUsageTrend(
                history,
                to: &lines,
                now: trendNow,
                note: "From Command Code's usage API",
                calendar: CommandCodeSpendWindow.utcCalendar
            )
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: lines,
                refreshedAt: now(),
                warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// Persist today's cumulative spend and yesterday's exact day value from the windows already fetched
    /// this refresh — no extra API calls. Best-effort: a nil window or a failed write just leaves the
    /// chart short a day, never a failed refresh.
    private func recordSpendHistory(from windows: CommandCodeSpendWindows, now: Date) async {
        let today = windows.today.flatMap { try? CommandCodeUsageMapper.spendTotal(from: $0) }
        // Yesterday is the overlap between the two cumulative windows, available only when both decoded.
        let yesterday = windows.sinceYesterday.flatMap { body -> CommandCodeSpendTotal? in
            guard let today else { return nil }
            return (try? CommandCodeUsageMapper.spendTotal(from: body))?.subtracting(today)
        }
        await loadOffMainActor { [spendHistoryStore] in
            spendHistoryStore.record(todayTotal: today, yesterdayTotal: yesterday, now: now)
        }
    }

    /// Rebuild the full 31-day window once per UTC day. `/alpha/usage/summary` answers only cumulative
    /// totals, so the per-day series is `V(i) - V(i-1)`; the floors backing it are fetched here in batches
    /// of four. Best-effort: any missing floor discards the whole backfill and leaves `lastBackfillDay`
    /// unset, so the next refresh retries rather than leaving a half-built chart.
    private func backfillSpendHistoryIfNeeded(
        apiKey: String,
        organizationID: String?,
        now: Date
    ) async {
        guard await loadOffMainActor({ [spendHistoryStore] in
            spendHistoryStore.needsBackfill(now: now)
        }) else { return }

        let offsets = Array(0...UsageHistoryWindow.previousDays)
        var cumulative: [Int: CommandCodeSpendTotal] = [:]
        let client = usageClient
        var start = 0
        while start < offsets.count {
            let batch = Array(offsets[start..<min(start + 4, offsets.count)])
            start += 4
            await withTaskGroup(of: (Int, CommandCodeSpendTotal?).self) { group in
                for offset in batch {
                    group.addTask {
                        (offset, await Self.spendTotal(
                            client: client,
                            apiKey: apiKey,
                            organizationID: organizationID,
                            offsetDays: offset,
                            now: now
                        ))
                    }
                }
                for await (offset, total) in group {
                    if let total { cumulative[offset] = total }
                }
            }
        }

        guard cumulative.count == offsets.count else {
            AppLog.warn(.refresh, "Command Code spend backfill incomplete (\(cumulative.count)/\(offsets.count))")
            return
        }
        let dayTotals = CommandCodeSpendHistoryStore.dayTotals(cumulativeByOffset: cumulative, now: now)
        await loadOffMainActor { [spendHistoryStore] in
            spendHistoryStore.merge(
                dayTotals: dayTotals,
                backfillDay: CommandCodeSpendHistoryStore.utcDayKey(for: now)
            )
        }
    }

    /// One cumulative window as a decoded total, with no per-call warning: a backfill that misses any
    /// window is reported once as a whole rather than 31 times. `nonisolated static` so the backfill's
    /// task group can run four fetches at once without touching MainActor state; the client is a
    /// `Sendable` value, so nothing provider-owned crosses the boundary.
    private nonisolated static func spendTotal(
        client: CommandCodeUsageClient,
        apiKey: String,
        organizationID: String?,
        offsetDays: Int,
        now: Date
    ) async -> CommandCodeSpendTotal? {
        do {
            let response = try await client.fetchUsageSummary(
                apiKey: apiKey,
                organizationID: organizationID,
                since: CommandCodeSpendWindow.since(offsetDays: offsetDays, from: now)
            )
            guard response.statusCode != 401, response.statusCode != 403,
                  (200..<300).contains(response.statusCode),
                  !response.body.isEmpty
            else {
                return nil
            }
            return try CommandCodeUsageMapper.spendTotal(from: response.body)
        } catch {
            return nil
        }
    }

    /// The three cumulative summary windows backing the shared spend tiles. Each is one extra
    /// `/alpha/usage/summary` call, so they run together; a failure drops that window's row (and adds a
    /// warning) instead of failing the provider — the quota meters are still the important reading.
    private func spendWindows(
        apiKey: String,
        organizationID: String?
    ) async -> (windows: CommandCodeSpendWindows, warning: String?) {
        // One clock reading for all three floors, so the windows can't straddle a UTC midnight.
        let asOf = now()
        async let today = summaryWindow(apiKey: apiKey, organizationID: organizationID, offsetDays: 0, now: asOf)
        async let sinceYesterday = summaryWindow(apiKey: apiKey, organizationID: organizationID, offsetDays: 1, now: asOf)
        async let sinceLast30Days = summaryWindow(apiKey: apiKey, organizationID: organizationID, offsetDays: 30, now: asOf)
        let (todayBody, yesterdayBody, last30Body) = await (today, sinceYesterday, sinceLast30Days)

        let failed = todayBody == nil || yesterdayBody == nil || last30Body == nil
        return (
            CommandCodeSpendWindows(
                today: todayBody,
                sinceYesterday: yesterdayBody,
                sinceLast30Days: last30Body
            ),
            failed ? "Couldn't read Command Code spend history." : nil
        )
    }

    private func summaryWindow(
        apiKey: String,
        organizationID: String?,
        offsetDays: Int,
        now: Date
    ) async -> Data? {
        do {
            return try await load {
                try await usageClient.fetchUsageSummary(
                    apiKey: apiKey,
                    organizationID: organizationID,
                    since: CommandCodeSpendWindow.since(offsetDays: offsetDays, from: now)
                )
            }
        } catch {
            AppLog.warn(.refresh, "Command Code spend window failed (\(error.localizedDescription))")
            return nil
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
