import Foundation

/// Locally persisted per-day Command Code spend, backing its shared Today/Yesterday/30-day history.
///
/// `/alpha/usage/summary` returns only a cumulative total from a floor (`since`) and ignores `until`, so
/// a single day's spend cannot be requested — it exists only as the difference of two adjacent floors.
/// The 30-day history therefore has to be assembled and remembered by the client. It is file-backed rather
/// than in-memory because the window outlives a launch: at a few refreshes an hour, an in-memory buffer
/// would show only the days seen since the last start.
///
/// Days are keyed by UTC calendar day, matching the API's day snapping (see `CommandCodeSpendWindow`).
/// A missing, unreadable, or older-schema file reads as empty rather than an error — the history is a
/// bonus on top of the live meters, so a corrupt cache must never fail a refresh.
struct CommandCodeSpendHistoryStore: Sendable {
    static let schema = 1
    /// Slightly wider than the 30-day history window so a day rollover can't trim the left edge early.
    static let retentionDays = 35

    /// One day's spend. `tokens` stays a `Double` because the API's totals are doubles.
    struct Day: Codable, Sendable, Equatable {
        var costUSD: Double
        var tokens: Double
    }

    private struct FilePayload: Codable {
        var schema: Int
        var lastBackfillDay: String?
        var days: [String: Day]
    }

    let directory: URL

    init(directory: URL = CommandCodeSpendHistoryStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenUsage", isDirectory: true)
    }

    // MARK: - Reads

    /// Stored days inside the shared history window (today plus the previous 30 UTC days). The source's
    /// calendar is UTC because Command Code snaps cumulative `since` floors to UTC days.
    func history(for accountID: String, through now: Date) -> UsageHistory {
        let calendar = CommandCodeSpendWindow.utcCalendar
        let window = Self.windowKeys(through: now)
        var days: [Date: UsageDay] = [:]
        for (key, value) in load(accountID: accountID).days where window.contains(key) {
            guard let date = calendar.date(from: Self.components(from: key)) else { continue }
            days[calendar.startOfDay(for: date)] = UsageDay(totals: UsageTotals(values: [
                .spend: max(0, value.costUSD),
                .tokens: Double(Self.tokenCount(value.tokens))
            ]))
        }
        return UsageHistory(calendar: calendar, asOf: now, days: days)
    }

    /// True until a backfill has completed for today's UTC day. A corrupt or missing file reads as `true`,
    /// so the provider rebuilds the window once and then leaves it alone until the next day boundary.
    func needsBackfill(for accountID: String, now: Date) -> Bool {
        load(accountID: accountID).lastBackfillDay != Self.utcDayKey(for: now)
    }

    // MARK: - Writes

    /// Fold the live cumulative readings in on every refresh. `todayTotal` is cumulative from 00:00 UTC
    /// today and is still accruing, so it is overwritten each time; `yesterdayTotal` is the exact past-day
    /// value and is final once the day has passed, though rewriting it with the same reading is harmless.
    /// A `nil` window (a failed call) leaves that day untouched so a transient error can't erase a stored
    /// value.
    func record(
        for accountID: String,
        todayTotal: CommandCodeSpendTotal?,
        yesterdayTotal: CommandCodeSpendTotal?,
        now: Date
    ) {
        var payload = load(accountID: accountID)
        if let todayTotal { payload.days[Self.utcDayKey(for: now)] = Self.day(from: todayTotal) }
        if let yesterdayTotal {
            let yesterday = CommandCodeSpendWindow.utcCalendar
                .date(byAdding: .day, value: -1, to: now) ?? now
            payload.days[Self.utcDayKey(for: yesterday)] = Self.day(from: yesterdayTotal)
        }
        payload.days = Self.pruned(payload.days, relativeTo: Self.utcDayKey(for: now))
        save(payload, accountID: accountID)
    }

    /// Merge a completed backfill's per-day values and stamp the day it ran. Days already recorded by
    /// `record` are overwritten with the backfill's reading; both derive from the same cumulative floors,
    /// so the two agree for any day the API answered.
    func merge(dayTotals: [String: CommandCodeSpendTotal], backfillDay: String, for accountID: String) {
        var payload = load(accountID: accountID)
        for (day, total) in dayTotals { payload.days[day] = Self.day(from: total) }
        payload.lastBackfillDay = backfillDay
        payload.days = Self.pruned(payload.days, relativeTo: backfillDay)
        save(payload, accountID: accountID)
    }

    // MARK: - Day math

    /// Turn offsets-to-cumulative totals into day-keyed per-day values.
    ///
    /// `cumulativeByOffset[i]` is the total from 00:00 UTC of the day `i` days back, so that day's own
    /// spend is `V(i) - V(i-1)` and today (offset 0) is `V(0)` outright. A day whose neighbor is missing
    /// is skipped rather than guessed; a request that lands in the wrong bucket is clamped to zero by
    /// `subtracting`, so clock skew can't produce a negative day.
    static func dayTotals(
        cumulativeByOffset: [Int: CommandCodeSpendTotal],
        now: Date
    ) -> [String: CommandCodeSpendTotal] {
        var totals: [String: CommandCodeSpendTotal] = [:]
        for offset in 0...30 {
            guard let cumulative = cumulativeByOffset[offset] else { continue }
            let day = cumulativeByOffset[offset - 1].map(cumulative.subtracting) ?? cumulative
            let date = CommandCodeSpendWindow.utcCalendar
                .date(byAdding: .day, value: -offset, to: now) ?? now
            totals[utcDayKey(for: date)] = CommandCodeSpendTotal(
                costUSD: max(0, day.costUSD),
                tokens: max(0, day.tokens)
            )
        }
        return totals
    }

    /// `yyyy-MM-dd` in UTC — the same day alignment the spend windows snap to.
    static func utcDayKey(for date: Date) -> String {
        let components = CommandCodeSpendWindow.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// The fork's pre-account build stored one file for whichever Command Code account refreshed last.
    /// Only a sole existing account can safely inherit it; with several accounts, a shared history would
    /// necessarily mix their spend.
    static func migrateLegacyIfUnaffected(
        directory: URL = defaultDirectory,
        existingAccountIDs: [String]
    ) {
        guard existingAccountIDs.count == 1 else { return }
        let legacy = directory.appendingPathComponent("commandcode-spend-history.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let destination = directory.appendingPathComponent(
            "commandcode-spend-history-\(existingAccountIDs[0].replacingOccurrences(of: "@", with: "-")).json"
        )
        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.moveItem(at: legacy, to: destination)
                AppLog.notice(.config, "moved the Command Code spend history to its existing account")
            } catch {
                AppLog.warn(.config, "could not move the Command Code spend history: \(error.localizedDescription)")
            }
        }
    }

    private static func windowKeys(through now: Date) -> Set<String> {
        let starts = UsageHistory.dayStarts(0...30, now: now, calendar: CommandCodeSpendWindow.utcCalendar)
        return Set(starts.map(utcDayKey))
    }

    private static func day(from total: CommandCodeSpendTotal) -> Day {
        Day(costUSD: max(0, total.costUSD), tokens: max(0, total.tokens))
    }

    private static func tokenCount(_ tokens: Double) -> Int {
        guard tokens.isFinite, tokens > 0 else { return 0 }
        return Int(min(tokens.rounded(), Double(Int.max)))
    }

    /// Drop days before the retention cutoff. Keys sort lexicographically, so a plain `>=` on the
    /// `yyyy-MM-dd` string is the date comparison.
    private static func pruned(_ days: [String: Day], relativeTo dayKey: String) -> [String: Day] {
        guard let cutoff = cutoffKey(before: dayKey) else { return days }
        return days.filter { $0.key >= cutoff }
    }

    private static func cutoffKey(before dayKey: String) -> String? {
        let components = components(from: dayKey)
        guard let date = CommandCodeSpendWindow.utcCalendar.date(from: components),
              let cutoff = CommandCodeSpendWindow.utcCalendar
                  .date(byAdding: .day, value: -retentionDays, to: date)
        else { return nil }
        return utcDayKey(for: cutoff)
    }

    private static func components(from dayKey: String) -> DateComponents {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return DateComponents() }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    // MARK: - Persistence

    private func fileURL(accountID: String) -> URL {
        directory
            .appendingPathComponent("commandcode-spend-history-\(accountID.replacingOccurrences(of: "@", with: "-")).json")
    }

    private func load(accountID: String) -> FilePayload {
        guard let data = try? Data(contentsOf: fileURL(accountID: accountID)),
              let payload = try? JSONDecoder().decode(FilePayload.self, from: data),
              payload.schema == Self.schema
        else {
            return FilePayload(schema: Self.schema, lastBackfillDay: nil, days: [:])
        }
        return payload
    }

    private func save(_ payload: FilePayload, accountID: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(payload).write(to: fileURL(accountID: accountID), options: .atomic)
        } catch {
            // Best-effort: a failed write just means the history misses a day, never a failed refresh.
        }
    }
}
