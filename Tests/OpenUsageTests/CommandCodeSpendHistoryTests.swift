import XCTest
@testable import OpenUsage

final class CommandCodeSpendHistoryTests: XCTestCase {
    private var createdDirectories: [URL] = []

    override func tearDown() {
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdDirectories = []
        super.tearDown()
    }

    private func makeStore() -> CommandCodeSpendHistoryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-cc-spend-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(directory)
        return CommandCodeSpendHistoryStore(directory: directory)
    }

    private func historyFileURL(_ store: CommandCodeSpendHistoryStore) -> URL {
        store.directory.appendingPathComponent("commandcode-spend-history.json")
    }

    private func seedFile(_ store: CommandCodeSpendHistoryStore, _ raw: String) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: historyFileURL(store))
    }

    private func readFile(_ store: CommandCodeSpendHistoryStore) throws -> HistoryFileMirror {
        let data = try Data(contentsOf: historyFileURL(store))
        return try JSONDecoder().decode(HistoryFileMirror.self, from: data)
    }

    // MARK: - Day differencing

    /// `/alpha/usage/summary` only answers cumulative totals, so a day's own spend is `V(i) - V(i-1)`.
    /// A bucket that reads lower than its newer neighbor is clamped at zero rather than drawn negative.
    func testDayDifferencingClampsNegativesAndSkipsMissingFloors() {
        let totals = CommandCodeSpendHistoryStore.dayTotals(
            cumulativeByOffset: [
                0: CommandCodeSpendTotal(costUSD: 5.0, tokens: 500),
                1: CommandCodeSpendTotal(costUSD: 12.0, tokens: 1_200),
                2: CommandCodeSpendTotal(costUSD: 19.0, tokens: 1_900),
                3: CommandCodeSpendTotal(costUSD: 18.0, tokens: 1_700)
            ],
            now: Fixtures.now
        )

        XCTAssertEqual(totals["2026-10-04"]?.costUSD, 5.0)
        XCTAssertEqual(totals["2026-10-03"]?.costUSD, 7.0)
        XCTAssertEqual(totals["2026-10-02"]?.costUSD, 7.0)
        XCTAssertEqual(totals["2026-10-01"]?.costUSD, 0)
        XCTAssertEqual(totals["2026-10-01"]?.tokens, 0)
        // Offset 4 has no floor at all, so its day is skipped instead of being fabricated from V(3).
        XCTAssertNil(totals["2026-09-30"])
    }

    // MARK: - Record

    /// Today is still accruing, so each refresh overwrites it; yesterday has passed and is final. A failed
    /// window (`nil`) leaves the stored day alone rather than erasing it.
    func testRecordOverwritesTodayFinalizesYesterdayAndIgnoresNil() {
        let store = makeStore()
        let now = Fixtures.now

        store.record(
            todayTotal: CommandCodeSpendTotal(costUSD: 1.0, tokens: 100),
            yesterdayTotal: CommandCodeSpendTotal(costUSD: 2.0, tokens: 200),
            now: now
        )
        store.record(
            todayTotal: CommandCodeSpendTotal(costUSD: 3.5, tokens: 350),
            yesterdayTotal: CommandCodeSpendTotal(costUSD: 2.0, tokens: 200),
            now: now
        )
        store.record(todayTotal: nil, yesterdayTotal: nil, now: now)

        let series = store.series(through: now)
        XCTAssertEqual(series.daily.map(\.date), ["2026-10-03", "2026-10-04"])
        XCTAssertEqual(series.daily.map(\.costUSD), [2.0, 3.5])
        XCTAssertEqual(series.daily.map(\.totalTokens), [200, 350])
    }

    func testRecordClampsNegativeTotalsToZero() {
        let store = makeStore()
        let now = Fixtures.now
        store.record(
            todayTotal: CommandCodeSpendTotal(costUSD: -4.0, tokens: -10),
            yesterdayTotal: CommandCodeSpendTotal(costUSD: -1.0, tokens: -5),
            now: now
        )

        let series = store.series(through: now)
        XCTAssertEqual(series.daily.map(\.costUSD), [0, 0])
        XCTAssertEqual(series.daily.map(\.totalTokens), [0, 0])
    }

    // MARK: - Corrupt / stale files

    func testCorruptFileStartsFreshAndRecoversOnWrite() throws {
        let store = makeStore()
        try seedFile(store, "this is not json")

        XCTAssertTrue(store.needsBackfill(now: Fixtures.now))
        XCTAssertTrue(store.series(through: Fixtures.now).daily.isEmpty)

        store.record(
            todayTotal: CommandCodeSpendTotal(costUSD: 1.5, tokens: 150),
            yesterdayTotal: nil,
            now: Fixtures.now
        )
        XCTAssertEqual(store.series(through: Fixtures.now).daily.map(\.date), ["2026-10-04"])
    }

    func testOlderSchemaIsDiscardedRatherThanDecoded() throws {
        let store = makeStore()
        try seedFile(store, #"{"schema":0,"days":{"2026-10-04":{"costUSD":9,"tokens":9}}}"#)

        XCTAssertTrue(store.needsBackfill(now: Fixtures.now))
        XCTAssertTrue(store.series(through: Fixtures.now).daily.isEmpty)
    }

    // MARK: - Retention

    func testWritesPruneDaysOlderThanRetention() throws {
        let store = makeStore()
        // 2026-10-04 minus 35 days is 2026-08-30, so the August day falls outside retention and the
        // September one survives.
        store.merge(
            dayTotals: [
                "2026-08-20": CommandCodeSpendTotal(costUSD: 1, tokens: 1),
                "2026-09-20": CommandCodeSpendTotal(costUSD: 2, tokens: 2)
            ],
            backfillDay: "2026-10-04"
        )

        let file = try readFile(store)
        XCTAssertNil(file.days["2026-08-20"])
        XCTAssertNotNil(file.days["2026-09-20"])
    }

    // MARK: - Backfill gating

    func testNeedsBackfillTracksDayRollover() {
        let store = makeStore()
        XCTAssertTrue(store.needsBackfill(now: Fixtures.now), "a fresh store owes a backfill")

        store.merge(dayTotals: [:], backfillDay: "2026-10-04")
        XCTAssertFalse(store.needsBackfill(now: Fixtures.now))
        XCTAssertFalse(store.needsBackfill(now: Fixtures.laterOnSameUTCDay))
        XCTAssertTrue(store.needsBackfill(now: Fixtures.nextUTCDay))
    }

    // MARK: - Series shape

    func testSeriesIsOrderedRoundedAndWindowed() {
        let store = makeStore()
        store.merge(
            dayTotals: [
                "2026-10-04": CommandCodeSpendTotal(costUSD: 3.0, tokens: 3_000),
                "2026-10-02": CommandCodeSpendTotal(costUSD: 1.25, tokens: 1_000.6),
                // Inside retention but older than the 30-day chart window, so the series drops it.
                "2026-09-03": CommandCodeSpendTotal(costUSD: 5.0, tokens: 5_000),
                // The 30-day boundary itself is included.
                "2026-09-04": CommandCodeSpendTotal(costUSD: 4.0, tokens: 4_000)
            ],
            backfillDay: "2026-10-04"
        )

        let series = store.series(through: Fixtures.now)
        XCTAssertEqual(series.daily.map(\.date), ["2026-09-04", "2026-10-02", "2026-10-04"])
        XCTAssertEqual(series.daily[1].totalTokens, 1_001)
        XCTAssertEqual(series.daily[1].costUSD, 1.25)
    }

    /// The chart's own append is a no-op over an empty series, so a fresh install shows no trend row at
    /// all until the first backfill lands.
    func testEmptySeriesAppendsNoTrendLine() {
        let store = makeStore()
        var lines: [MetricLine] = [.values(label: "Today", values: [])]
        SpendTileMapper.appendUsageTrend(
            store.series(through: Fixtures.now),
            to: &lines,
            now: Fixtures.now,
            note: "From Command Code's usage API"
        )
        XCTAssertEqual(lines.map(\.label), ["Today"])
    }

    // MARK: - Trend day axis

    /// Command Code keys its days in UTC, so the chart must be drawn on the same axis. At 2026-10-04T20:00Z
    /// the UTC day is still 10-04 while UTC+11 has rolled to 10-05; the injected calendar decides which bar
    /// is "today", and the series' value lands on the matching one.
    func testTrendAxisUsesTheInjectedCalendar() throws {
        let now = Fixtures.utcEvening
        let utcKey = CommandCodeSpendHistoryStore.utcDayKey(for: now)
        var sydney = Calendar(identifier: .gregorian)
        sydney.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 11 * 3_600))
        let sydneyKey = DailyUsageAccumulator.dayKey(from: now, calendar: sydney)

        XCTAssertEqual(utcKey, "2026-10-04")
        XCTAssertEqual(sydneyKey, "2026-10-05")

        let series = DailyUsageSeries(daily: [
            DailyUsageEntry(date: utcKey, totalTokens: 100, costUSD: 1),
            DailyUsageEntry(date: sydneyKey, totalTokens: 500, costUSD: 5)
        ])

        var utcLines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(
            series, to: &utcLines, now: now, note: "n", calendar: CommandCodeSpendWindow.utcCalendar
        )
        let utcPoints = try XCTUnwrap(chartPoints(utcLines))
        XCTAssertEqual(utcPoints.count, UsageHistoryWindow.previousDays + 1)
        // The newest bar is the current UTC day and carries its spend; the UTC+11 day is not on this axis.
        XCTAssertEqual(utcPoints.last?.value, 100)
        XCTAssertEqual(utcPoints.dropLast().last?.value, 0)

        var sydneyLines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(series, to: &sydneyLines, now: now, note: "n", calendar: sydney)
        let sydneyPoints = try XCTUnwrap(chartPoints(sydneyLines))
        // Same instant, UTC+11 axis: the newest bar moves and now carries the 10-05 value.
        XCTAssertEqual(sydneyPoints.last?.value, 500)
    }

    /// Without an injected calendar the axis stays on the local calendar every other provider counts in,
    /// so their charts are unchanged.
    func testTrendAxisDefaultsToTheLocalCalendar() throws {
        let now = Fixtures.now
        let localKey = DailyUsageAccumulator.dayKey(from: now)
        let series = DailyUsageSeries(daily: [DailyUsageEntry(date: localKey, totalTokens: 42, costUSD: 1)])

        var lines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(series, to: &lines, now: now, note: "n")

        let points = try XCTUnwrap(chartPoints(lines))
        XCTAssertEqual(points.count, UsageHistoryWindow.previousDays + 1)
        XCTAssertEqual(points.last?.value, 42)
    }

    private func chartPoints(_ lines: [MetricLine]) -> [MetricChartPoint]? {
        for line in lines {
            if case .chart(_, let points, _) = line { return points }
        }
        return nil
    }
}

private struct HistoryFileMirror: Decodable {
    struct DayMirror: Decodable {
        var costUSD: Double
        var tokens: Double
    }

    var schema: Int
    var lastBackfillDay: String?
    var days: [String: DayMirror]
}

private enum Fixtures {
    /// 2026-10-04T06:10:00Z, so "today" is 2026-10-04 and the 30-day window reaches 2026-09-04.
    static let now = Date(timeIntervalSince1970: 1_791_094_200)
    /// Still 2026-10-04 in UTC, so the backfill stamp should hold.
    static let laterOnSameUTCDay = now.addingTimeInterval(6 * 3_600)
    /// 2026-10-05 in UTC.
    static let nextUTCDay = now.addingTimeInterval(24 * 3_600)
    /// 2026-10-04T20:00:00Z — still 10-04 in UTC, already 10-05 in UTC+11.
    static let utcEvening = Date(timeIntervalSince1970: 1_791_144_000)
}
