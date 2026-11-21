import Foundation

extension AccountProviderRuntime {
    func refreshCommandCode(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let apiKey) = credential else { throw ProviderError.invalidResponse }
        let client = CommandCodeUsageClient(http: http)

        let whoami = try commandCodeBody(
            await client.fetchWhoami(apiKey: apiKey)
        )
        let organizationID = try CommandCodeUsageMapper.organizationID(from: whoami)

        async let creditsRequest = client.fetchCredits(apiKey: apiKey, organizationID: organizationID)
        async let subscriptionRequest = client.fetchSubscription(apiKey: apiKey, organizationID: organizationID)
        let credits = try commandCodeBody(await creditsRequest)

        var notes: [String] = []
        let subscription: CommandCodeSubscriptionContext?
        do {
            let response = try await subscriptionRequest
            try ProviderError.requireSuccess(response, kind: .commandcode)
            subscription = try CommandCodeUsageMapper.subscriptionContext(from: response.body)
        } catch let error as ProviderError where error == .signInExpired(.commandcode) {
            throw error
        } catch {
            subscription = nil
            notes.append("Couldn't read your Command Code plan.")
            AppLog.warn(.refresh, "Command Code plan lookup failed (\(error.localizedDescription))")
        }

        let summary: Data?
        if let subscription {
            do {
                summary = try commandCodeBody(await client.fetchUsageSummary(
                    apiKey: apiKey,
                    organizationID: organizationID,
                    since: subscription.currentPeriodStart
                ))
            } catch let error as ProviderError where error == .signInExpired(.commandcode) {
                throw error
            } catch {
                summary = nil
                notes.append("Couldn't read Command Code requests and monthly usage.")
                AppLog.warn(.refresh, "Command Code summary failed (\(error.localizedDescription))")
            }
        } else {
            summary = nil
        }

        let asOf = now()
        let accountID = account.cardID
        let windows = try await commandCodeSpendWindows(
            client: client,
            apiKey: apiKey,
            organizationID: organizationID,
            asOf: asOf
        )
        if windows.failed {
            notes.append("Couldn't read Command Code spend history.")
        }

        let store = historyStore
        let needsBackfill = try await loadOffMainActor { store.needsBackfill(for: accountID, now: asOf) }
        if needsBackfill {
            await backfillCommandCodeHistory(
                client: client,
                apiKey: apiKey,
                organizationID: organizationID,
                store: store,
                accountID: accountID,
                asOf: asOf
            )
        }
        recordCommandCodeWindows(windows, store: store, accountID: accountID, asOf: asOf)

        let mapped = try CommandCodeUsageMapper.map(
            creditsBody: credits,
            summaryBody: summary,
            subscription: subscription
        )
        let history = try await loadOffMainActor {
            store.history(for: accountID, through: asOf)
        }
        return ProviderUsage(
            plan: mapped.plan,
            lines: mapped.lines,
            notice: notes.isEmpty ? nil : notes.joined(separator: " "),
            history: history
        )
    }

    private func commandCodeBody(_ response: HTTPResponse) throws -> Data {
        try ProviderError.requireSuccess(response, kind: .commandcode)
        guard !response.body.isEmpty else { throw ProviderError.invalidResponse }
        return response.body
    }

    private func commandCodeSpendWindows(
        client: CommandCodeUsageClient,
        apiKey: String,
        organizationID: String?,
        asOf: Date
    ) async throws -> CommandCodeFetchedWindows {
        async let today = commandCodeSummaryWindow(
            client: client, apiKey: apiKey, organizationID: organizationID, offsetDays: 0, asOf: asOf
        )
        async let yesterday = commandCodeSummaryWindow(
            client: client, apiKey: apiKey, organizationID: organizationID, offsetDays: 1, asOf: asOf
        )
        async let last30 = commandCodeSummaryWindow(
            client: client, apiKey: apiKey, organizationID: organizationID, offsetDays: 30, asOf: asOf
        )
        let values: (Data?, Data?, Data?)
        do {
            values = try await (today, yesterday, last30)
        } catch ProviderError.signInExpired(.commandcode) {
            throw ProviderError.signInExpired(.commandcode)
        }
        return CommandCodeFetchedWindows(
            today: values.0,
            sinceYesterday: values.1,
            sinceLast30Days: values.2,
            failed: values.0 == nil || values.1 == nil || values.2 == nil
        )
    }

    /// A failed spend window leaves its row absent and is reported by the caller once.
    private func commandCodeSummaryWindow(
        client: CommandCodeUsageClient,
        apiKey: String,
        organizationID: String?,
        offsetDays: Int,
        asOf: Date
    ) async throws -> Data? {
        do {
            let response = try await client.fetchUsageSummary(
                apiKey: apiKey,
                organizationID: organizationID,
                since: CommandCodeSpendWindow.since(offsetDays: offsetDays, from: asOf)
            )
            if ProviderError.isAuthFailure(response) {
                throw ProviderError.signInExpired(.commandcode)
            }
            guard (200..<300).contains(response.statusCode), !response.body.isEmpty else { return nil }
            return response.body
        } catch ProviderError.signInExpired(.commandcode) {
            throw ProviderError.signInExpired(.commandcode)
        } catch {
            AppLog.warn(.refresh, "Command Code spend window failed (\(error.localizedDescription))")
            return nil
        }
    }

    private func recordCommandCodeWindows(
        _ windows: CommandCodeFetchedWindows,
        store: CommandCodeSpendHistoryStore,
        accountID: String,
        asOf: Date
    ) {
        let today = windows.today.flatMap { try? CommandCodeUsageMapper.spendTotal(from: $0) }
        let yesterday = windows.sinceYesterday.flatMap { body -> CommandCodeSpendTotal? in
            guard let today else { return nil }
            return (try? CommandCodeUsageMapper.spendTotal(from: body))?.subtracting(today)
        }
        store.record(for: accountID, todayTotal: today, yesterdayTotal: yesterday, now: asOf)
    }

    private func backfillCommandCodeHistory(
        client: CommandCodeUsageClient,
        apiKey: String,
        organizationID: String?,
        store: CommandCodeSpendHistoryStore,
        accountID: String,
        asOf: Date
    ) async {
        let offsets = Array(0...30)
        var cumulative: [Int: CommandCodeSpendTotal] = [:]
        for start in stride(from: 0, to: offsets.count, by: 4) {
            let batch = offsets[start..<min(start + 4, offsets.count)]
            await withTaskGroup(of: (Int, CommandCodeSpendTotal?).self) { group in
                for offset in batch {
                    group.addTask {
                        (
                            offset,
                            await Self.commandCodeSpendTotal(
                                client: client,
                                apiKey: apiKey,
                                organizationID: organizationID,
                                offsetDays: offset,
                                asOf: asOf
                            )
                        )
                    }
                }
                for await (offset, total) in group {
                    if let total {
                        cumulative[offset] = total
                    }
                }
            }
        }

        guard cumulative.count == offsets.count else {
            AppLog.warn(.refresh, "Command Code spend backfill incomplete (\(cumulative.count)/\(offsets.count))")
            return
        }
        let days = CommandCodeSpendHistoryStore.dayTotals(cumulativeByOffset: cumulative, now: asOf)
        store.merge(
            dayTotals: days,
            backfillDay: CommandCodeSpendHistoryStore.utcDayKey(for: asOf),
            for: accountID
        )
    }

    private nonisolated static func commandCodeSpendTotal(
        client: CommandCodeUsageClient,
        apiKey: String,
        organizationID: String?,
        offsetDays: Int,
        asOf: Date
    ) async -> CommandCodeSpendTotal? {
        do {
            let response = try await client.fetchUsageSummary(
                apiKey: apiKey,
                organizationID: organizationID,
                since: CommandCodeSpendWindow.since(offsetDays: offsetDays, from: asOf)
            )
            guard !ProviderError.isAuthFailure(response),
                  (200..<300).contains(response.statusCode),
                  !response.body.isEmpty
            else { return nil }
            return try CommandCodeUsageMapper.spendTotal(from: response.body)
        } catch {
            return nil
        }
    }
}

private struct CommandCodeFetchedWindows: Sendable {
    var today: Data?
    var sinceYesterday: Data?
    var sinceLast30Days: Data?
    var failed: Bool
}
