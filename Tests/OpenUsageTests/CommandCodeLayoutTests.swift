import XCTest
@testable import OpenUsage

@MainActor
final class CommandCodeLayoutTests: XCTestCase {
    private let orderedMetricIDs = [
        "commandcode.session",
        "commandcode.weekly",
        "commandcode.monthly",
        "commandcode.balance",
        "commandcode.requests"
    ]

    func testCommandCodeDefaultsAndPlacement() {
        for id in orderedMetricIDs {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) should be enabled")
        }
        for id in ["commandcode.session", "commandcode.balance"] {
            XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should be always visible")
        }
        for id in ["commandcode.weekly", "commandcode.monthly", "commandcode.requests"] {
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should be on demand")
        }
        XCTAssertTrue(DefaultLayout.pinnedMetricIDs.filter { $0.hasPrefix("commandcode.") }.isEmpty)
    }

    func testProviderOrderAndMetricOrder() {
        let suiteName = "CommandCodeLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = ProviderCatalog.make(defaults: defaults)
        let names = providers.map(\.provider.displayName)
        guard let commandCode = names.firstIndex(of: "Command Code"),
              let copilot = names.firstIndex(of: "Copilot")
        else {
            return XCTFail("Expected Command Code before Copilot")
        }
        XCTAssertLessThan(commandCode, copilot)
        XCTAssertEqual(CommandCodeProvider().widgetDescriptors.map(\.id), orderedMetricIDs)
    }
}
