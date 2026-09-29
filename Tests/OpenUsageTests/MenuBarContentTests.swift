import XCTest
@testable import OpenUsage

/// Covers `MenuBarContentBuilder`: it resolves pinned provider groups into Text groups (order, labels,
/// and values preserved) and Bars entries (bounded metrics only, first four in order), and reports empty
/// when nothing is pinned.
@MainActor
final class MenuBarContentTests: XCTestCase {
    func testEmptyWhenNoGroups() {
        let content = MenuBarContentBuilder.build(groups: [], data: { $0.sample })
        XCTAssertTrue(content.isEmpty)
        XCTAssertTrue(content.bars.isEmpty)
    }

    func testTextGroupsPreserveOrderLabelsAndValues() {
        let m1 = percent("a.m1", "Session", 97)
        let m2 = percent("a.m2", "Weekly", 12)
        let b1 = percent("b.m1", "Total", 50)
        let content = MenuBarContentBuilder.build(groups: [group("a", m1, m2), group("b", b1)], data: { $0.sample })

        XCTAssertEqual(content.groups.map(\.providerID), ["a", "b"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.m1", "a.m2"])
        XCTAssertEqual(content.groups[0].metrics[0].label, "Session")
        XCTAssertEqual(content.groups[0].metrics[0].value, m1.sample.valueText)
        XCTAssertEqual(content.groups[1].metrics.map(\.id), ["b.m1"])
    }

    func testBarsIncludeBoundedMetricsAndDropUnbounded() {
        // A bounded dollar metric has a fill, so it belongs in Bars. An unbounded value (raw spend,
        // no limit) has no fill and is dropped.
        let content = MenuBarContentBuilder.build(
            groups: [group("a",
                percent("a.pct", "Pct", 40),
                boundedDollars("a.credits", "Credits", used: 12000, limit: 18000),
                unbounded("a.spend", "Spend"))],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.pct", "a.credits", "a.spend"])  // Text: all
        XCTAssertEqual(content.bars.map(\.id), ["a.pct", "a.credits"])                          // Bars: bounded only
    }

    func testBarsCappedToFourInOrder() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.m1", "M1", 10), percent("a.m2", "M2", 20)),
                group("b", percent("b.m1", "M1", 30), percent("b.m2", "M2", 40)),
                group("c", percent("c.m1", "M1", 50), percent("c.m2", "M2", 60))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.bars.count, 4)
        XCTAssertEqual(content.bars.map(\.id), ["a.m1", "a.m2", "b.m1", "b.m2"])
    }

    func testNoDataMetricsDropFromStrip() {
        // The strip is dynamic: a pinned metric without data vanishes instead of rendering "—", and
        // the surviving pin renders alone (full size). A provider whose pins all lack data
        // contributes no icon at all.
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.live", "Session", 41), noDataPercent("a.dark", "Weekly")),
                group("b", noDataPercent("b.nd", "ND"))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["a"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.live"])
        XCTAssertEqual(content.bars.map(\.id), ["a.live"])
    }

    func testAllPinsWithoutDataFallBackToAppIcon() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", noDataPercent("a.nd", "ND"))],
            data: { $0.sample }
        )
        XCTAssertTrue(content.isEmpty)
    }

    func testAccessibilityTextSummarizesGroups() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41), percent("a.m2", "Weekly", 12))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.accessibilityText, "A Session 41%, Weekly 12%")
    }

    func testTrayLabelsShortenLongTimeWindows() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.today", "Today", 5), percent("a.month", "Last 30 Days", 80))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["T", "M"])
    }

    func testBoundedTrayValuesStayUnitAware() {
        // Percent meters still read as percentages, while bounded dollars/counts keep their natural
        // unit in the strip instead of collapsing to "used / limit" percentages.
        let usage = percent("a.usage", "Usage", 67)
        let credits = boundedDollars("a.credits", "Credits", used: 12000, limit: 18000)
        let requests = boundedCount("a.requests", "Requests", used: 412, limit: 500)
        let spend = unbounded("a.spend", "Spend")   // unbounded $42
        let content = MenuBarContentBuilder.build(groups: [group("a", usage, credits, requests, spend)], data: { $0.sample })

        XCTAssertEqual(content.groups[0].metrics.map(\.value), ["67%", "$12K", "412", "$42"])
    }

    // Compact-notation rules for tray values (abbreviation, decimal rounding) are pinned exactly in
    // MetricFormatterTests — the strip only relays MetricFormatter output.

    // MARK: - Fixtures

    // MARK: - Command Code pool substitution

    /// Command Code's percentage windows and its dollar Balance are the same money seen from two
    /// sides, so the tray shows the percentage while the included monthly allowance remains, and the
    /// dollar credit only once that allowance is spent.
    func testCommandCodePinnedBalanceShowsMonthlyPercentageWhileAllowanceRemains() {
        let content = MenuBarContentBuilder.build(
            groups: [commandCodeGroup(commandCodeBalance(value: 70.09))],
            data: commandCodeData(monthlyUsed: 0),
            registry: commandCodeRegistry()
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["commandcode.monthly"])
        XCTAssertEqual(content.groups[0].metrics.map(\.value), ["0%"])
    }

    func testCommandCodePinnedBalanceKeepsDollarsOnceAllowanceIsSpent() {
        // A fully spent monthly allowance leaves the balance as purchased top-up credit: finite,
        // additional, and the only reading worth showing.
        for used in [100.0, 99.5] {
            let content = MenuBarContentBuilder.build(
                groups: [commandCodeGroup(commandCodeBalance(value: 9.5))],
                data: commandCodeData(monthlyUsed: used),
                registry: commandCodeRegistry()
            )
            XCTAssertEqual(content.groups[0].metrics.map(\.id), ["commandcode.balance"], "used \(used)")
            // Tray style abbreviates to whole dollars above $1; the sub-$1 case keeps its cents.
            XCTAssertEqual(content.groups[0].metrics.map(\.value), ["$10"], "used \(used)")
        }
    }

    func testCommandCodeNearlySpentAllowanceStillCountsAsSpent() {
        // Half a percent remaining reads as "100% used" on the meter, so calling that unspent would
        // hide the credit exactly as the pool flips over.
        let content = MenuBarContentBuilder.build(
            groups: [commandCodeGroup(commandCodeBalance(value: 0.5))],
            data: commandCodeData(monthlyUsed: 99.5),
            registry: commandCodeRegistry()
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["commandcode.balance"])
    }

    func testCommandCodeSubstitutionLeavesOtherProvidersAlone() {
        // A dollar Balance on another provider is a real unbounded figure, not a pool restatement.
        let content = MenuBarContentBuilder.build(
            groups: [group("z", unbounded("z.credits", "Credits", 5000))],
            data: { $0.sample },
            registry: commandCodeRegistry()
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["z.credits"])
        XCTAssertEqual(content.groups[0].metrics.map(\.value), ["$5K"])
    }

    func testCommandCodeRespectsExplicitBalanceAndMonthlyPins() {
        // Both readings pinned is a deliberate choice; the substitution must not override it.
        let content = MenuBarContentBuilder.build(
            groups: [commandCodeGroup(commandCodeBalance(value: 70.09), commandCodeMonthly(used: 0))],
            data: commandCodeData(monthlyUsed: 0),
            registry: commandCodeRegistry()
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["commandcode.balance", "commandcode.monthly"])
    }

    func testCommandCodeSubstitutionPrefersPercentageWhenMonthlyHasNoData() {
        // Nothing is known about the pool, so the percentage wins over a possibly stale dollar figure.
        let content = MenuBarContentBuilder.build(
            groups: [commandCodeGroup(commandCodeBalance(value: 70.09))],
            data: { descriptor in
                guard descriptor.id == "commandcode.monthly" else { return descriptor.sample }
                var sample = descriptor.sample
                sample.hasData = false
                return sample
            },
            registry: commandCodeRegistry()
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["commandcode.monthly"])
    }

    func testCommandCodeSubstitutionIsSkippedWithoutRegistry() {
        // Call sites that pass no registry render pins literally rather than substituting.
        let content = MenuBarContentBuilder.build(
            groups: [commandCodeGroup(commandCodeBalance(value: 70.09))],
            data: commandCodeData(monthlyUsed: 0)
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["commandcode.balance"])
    }

    private func commandCodeGroup(_ metrics: WidgetDescriptor...) -> ProviderMetrics {
        ProviderMetrics(
            provider: Provider(
                id: "commandcode",
                displayName: "Command Code",
                icon: .providerMark("commandcode")
            ),
            metrics: metrics
        )
    }

    private func commandCodeRegistry() -> WidgetRegistry {
        WidgetRegistry(
            providers: [],
            descriptors: [commandCodeMonthly(used: 0), commandCodeBalance(value: 70.09)]
        )
    }

    /// Resolve Command Code descriptors, pinning the Monthly value the test is exercising while the
    /// Balance descriptor still carries its own dollars.
    private func commandCodeData(monthlyUsed: Double) -> (WidgetDescriptor) -> WidgetData {
        { descriptor in
            guard descriptor.id == "commandcode.monthly" else { return descriptor.sample }
            return WidgetData(
                title: "Monthly",
                icon: .providerMark("commandcode"),
                kind: .percent,
                used: monthlyUsed,
                limit: 100
            )
        }
    }

    private func commandCodeMonthly(used: Double) -> WidgetDescriptor {
        descriptor(
            "commandcode.monthly",
            "Monthly",
            WidgetData(title: "Monthly", icon: .providerMark("commandcode"), kind: .percent, used: used, limit: 100)
        )
    }

    private func commandCodeBalance(value: Double) -> WidgetDescriptor {
        descriptor(
            "commandcode.balance",
            "Balance",
            WidgetData(title: "Balance", icon: .providerMark("commandcode"), kind: .dollars, used: value, limit: nil)
        )
    }

    private func group(_ providerID: String, _ metrics: WidgetDescriptor...) -> ProviderMetrics {
        let provider = Provider(
            id: providerID,
            displayName: providerID.uppercased(),
            icon: .providerMark("cursor")
        )
        return ProviderMetrics(provider: provider, metrics: metrics)
    }

    private func percent(_ id: String, _ label: String, _ used: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: used, limit: 100))
    }

    private func boundedDollars(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: limit))
    }

    private func boundedCount(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .count, used: used, limit: limit))
    }

    private func unbounded(_ id: String, _ label: String, _ used: Double = 42) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: nil))
    }

    private func noDataPercent(_ id: String, _ label: String) -> WidgetDescriptor {
        var sample = WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: 0, limit: 100)
        sample.hasData = false
        return descriptor(id, label, sample)
    }

    private func descriptor(_ id: String, _ label: String, _ sample: WidgetData) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: String(id.prefix { $0 != "." }),
            metricLabel: label,
            sample: sample
        )
    }
}
