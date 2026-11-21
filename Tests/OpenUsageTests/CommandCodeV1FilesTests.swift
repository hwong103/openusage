import XCTest
@testable import OpenUsage

@MainActor
final class CommandCodeV1FilesTests: XCTestCase {
    func testKeySourcesUseNormalPrecedenceAndRejectBlankValues() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: ".commandcode"), withIntermediateDirectories: true)
        try Data(#"{"apiKey":" file-key "}"#.utf8).write(to: home.appending(path: ".commandcode/auth.json"))

        XCTAssertEqual(CommandCodeV1Files.firstKey(home: home, environment: ["COMMAND_CODE_API_KEY": " env-key "]), "env-key")
        XCTAssertEqual(CommandCodeV1Files.firstKey(home: home, environment: [:]), "file-key")
        XCTAssertEqual(CommandCodeV1Files.firstKey(home: home, environment: ["COMMAND_CODE_API_KEY": "  "]), "file-key")
    }

    func testRouterFallbackReadsPlainKey() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let router = home.appending(path: ".codex/codex-router")
        try FileManager.default.createDirectory(at: router, withIntermediateDirectories: true)
        try Data("router-key\n".utf8).write(to: router.appending(path: "commandcode-api-key.secret"))
        XCTAssertEqual(CommandCodeV1Files.firstKey(home: home, environment: [:]), "router-key")
    }

    func testOfficialBuildDoesNotImport() async {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let http = RoutingHTTPClient { _ in
            XCTFail("the development build must not migrate background credentials")
            return .json("{}")
        }
        await CommandCodeV1Files.importOnce(
            into: accounts,
            defaults: defaults,
            environment: ["COMMAND_CODE_API_KEY": "secret"],
            http: http,
            bundleIdentifier: "com.robinebers.openusage"
        )
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
    }
}
