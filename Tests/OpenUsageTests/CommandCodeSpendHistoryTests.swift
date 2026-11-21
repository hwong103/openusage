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

    func testDayDifferencingClampsNegativesAndSkipsMissingFloors() {
        let totals = CommandCodeSpendHistoryStore.dayTotals(
            cumulativeByOffset: [
                0: .init(costUSD: 5, tokens: 500),
                1: .init(costUSD: 12, tokens: 1_200),
                2: .init(costUSD: 19, tokens: 1_900),
                3: .init(costUSD: 18, tokens: 1_700)
            ],
            now: Fixtures.now
        )

        XCTAssertEqual(totals["2026-10-04"]?.costUSD, 5)
        XCTAssertEqual(totals["2026-10-03"]?.costUSD, 7)
        XCTAssertEqual(totals["2026-10-02"]?.costUSD, 7)
        XCTAssertEqual(totals["2026-10-01"]?.costUSD, 0)
        XCTAssertEqual(totals["2026-10-01"]?.tokens, 0)
        XCTAssertNil(totals["2026-09-30"])
    }

    func testRecordOverwritesTodayFinalizesYesterdayAndIgnoresNil() {
        let store = makeStore()
        store.record(
            todayTotal: .init(costUSD: 1, tokens: 100),
            yesterdayTotal: .init(costUSD: 2, tokens: 200),
            now: Fixtures.now
        )
        store.record(
            todayTotal: .init(costUSD: 3.5, tokens: 350),
            yesterdayTotal: .init(costUSD: 2, tokens: 200),
            now: Fixtures.now
        )
        store.record(todayTotal: nil, yesterdayTotal: nil, now: Fixtures.now)

        let history = store.history(through: Fixtures.now)
        XCTAssertEqual(history.totals(over: .today)?[.spend], 3.5)
        XCTAssertEqual(history.totals(over: .today)?[.tokens], 350)
        XCTAssertEqual(history.totals(over: .yesterday)?[.spend], 2)
        XCTAssertEqual(history.totals(over: .lastDays(30))?[.spend], 5.5)
    }

    func testCorruptAndOlderSchemaFilesStartFresh() throws {
        let corrupt = makeStore()
        try seedFile(corrupt, "not json")
        XCTAssertTrue(corrupt.needsBackfill(now: Fixtures.now))
        XCTAssertTrue(corrupt.history(through: Fixtures.now).days.isEmpty)

        let old = makeStore()
        try seedFile(old, #"{"schema":0,"days":{"2026-10-04":{"costUSD":9,"tokens":9}}}"#)
        XCTAssertTrue(old.needsBackfill(now: Fixtures.now))
        XCTAssertTrue(old.history(through: Fixtures.now).days.isEmpty)
    }

    func testWritesPruneDaysOlderThanRetention() throws {
        let store = makeStore()
        store.merge(
            dayTotals: [
                "2026-08-20": .init(costUSD: 1, tokens: 1),
                "2026-09-20": .init(costUSD: 2, tokens: 2)
            ],
            backfillDay: "2026-10-04"
        )
        let file = try readFile(store)
        XCTAssertNil(file.days["2026-08-20"])
        XCTAssertNotNil(file.days["2026-09-20"])
    }

    func testNeedsBackfillTracksDayRollover() {
        let store = makeStore()
        XCTAssertTrue(store.needsBackfill(now: Fixtures.now))
        store.merge(dayTotals: [:], backfillDay: "2026-10-04")
        XCTAssertFalse(store.needsBackfill(now: Fixtures.now))
        XCTAssertFalse(store.needsBackfill(now: Fixtures.laterOnSameUTCDay))
        XCTAssertTrue(store.needsBackfill(now: Fixtures.nextUTCDay))
    }

    func testHistoryUsesTheUTCWindowAndReportsTheRightDay() {
        let store = makeStore()
        store.merge(
            dayTotals: [
                "2026-10-04": .init(costUSD: 3, tokens: 3_000),
                "2026-10-02": .init(costUSD: 1.25, tokens: 1_000.6),
                "2026-09-03": .init(costUSD: 5, tokens: 5_000),
                "2026-09-04": .init(costUSD: 4, tokens: 4_000)
            ],
            backfillDay: "2026-10-04"
        )

        let history = store.history(through: Fixtures.utcEvening)
        XCTAssertEqual(history.calendar.timeZone.secondsFromGMT(), 0)
        XCTAssertEqual(history.totals(over: .today)?[.spend], 3)
        XCTAssertEqual(history.totals(over: .today)?[.tokens], 3_000)
        XCTAssertEqual(history.totals(over: .lastDays(30))?[.spend], 4.25)
        XCTAssertEqual(history.totals(over: .lastDays(30))?[.tokens] ?? 0, 4_001, accuracy: 0.0001)
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
    static let now = Date(timeIntervalSince1970: 1_791_094_200)
    static let laterOnSameUTCDay = now.addingTimeInterval(6 * 3_600)
    static let nextUTCDay = now.addingTimeInterval(24 * 3_600)
    static let utcEvening = Date(timeIntervalSince1970: 1_791_144_000)
}
