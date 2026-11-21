import Foundation
import XCTest
@testable import OpenUsage

final class AccountCredentialVaultTests: XCTestCase {
    private let accountID = UUID(uuidString: "7BF642ED-5BD8-47B3-92FF-B25652A22A4A")!
    private let service = "com.robinebers.openusage.accounts"

    func testLoadUsesAppleSecurityToolAndKeepsTheAccountUUID() throws {
        let runner = ScriptedSecurityRunner([
            .init(exitCode: 0, stdout: #"{"type":"apiKey","apiKey":"synthetic"}"#, stderr: ""),
        ])
        let items = KeychainItems(service: service, processRunner: runner)

        XCTAssertEqual(
            try items.load(accountID),
            Data(#"{"type":"apiKey","apiKey":"synthetic"}"#.utf8)
        )
        XCTAssertEqual(runner.invocations, [
            .init(
                executable: "/usr/bin/security",
                arguments: [
                    "find-generic-password", "-a", accountID.uuidString, "-s", service, "-w",
                ]
            ),
        ])
    }

    func testMissingItemUsesSecurityItemNotFoundExitCode() throws {
        let runner = ScriptedSecurityRunner([.init(exitCode: 44, stdout: "", stderr: "")])
        let items = KeychainItems(service: service, processRunner: runner)

        XCTAssertNil(try items.load(accountID))
    }

    func testSaveRewritesOnlyTheSameAccount() throws {
        let runner = ScriptedSecurityRunner([.init(exitCode: 0, stdout: "", stderr: "")])
        let items = KeychainItems(service: service, processRunner: runner)
        let encoded = Data("synthetic-credential".utf8)

        try items.save(encoded, for: accountID)

        XCTAssertEqual(runner.invocations, [
            .init(
                executable: "/usr/bin/security",
                arguments: [
                    "add-generic-password", "-U", "-a", accountID.uuidString, "-s", service, "-w",
                    "synthetic-credential",
                ]
            ),
        ])
    }

    func testUpdateRefusesToRecreateAMissingItem() {
        let runner = ScriptedSecurityRunner([.init(exitCode: 44, stdout: "", stderr: "")])
        let items = KeychainItems(service: service, processRunner: runner)

        XCTAssertThrowsError(try items.update(Data("replacement".utf8), for: accountID)) {
            guard case CredentialVaultError.missingCredential = $0 else {
                return XCTFail("expected missingCredential, got \($0)")
            }
        }
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testDeleteTreatsAnAlreadyMissingItemAsSuccess() throws {
        let runner = ScriptedSecurityRunner([.init(exitCode: 44, stdout: "", stderr: "")])
        let items = KeychainItems(service: service, processRunner: runner)

        try items.delete(accountID)

        XCTAssertEqual(runner.invocations, [
            .init(
                executable: "/usr/bin/security",
                arguments: ["delete-generic-password", "-a", accountID.uuidString, "-s", service]
            ),
        ])
    }

    func testOtherSecurityFailuresSurfaceAsAfailedVault() {
        let runner = ScriptedSecurityRunner([.init(exitCode: 51, stdout: "", stderr: "denied")])
        let items = KeychainItems(service: service, processRunner: runner)

        XCTAssertThrowsError(try items.load(accountID)) {
            guard case KeychainVaultError.commandFailed(51) = $0 else {
                return XCTFail("expected commandFailed(51), got \($0)")
            }
        }
    }
}

private struct SecurityInvocation: Sendable, Equatable {
    var executable: String
    var arguments: [String]
}

private final class ScriptedSecurityRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessResult]
    private var recorded: [SecurityInvocation] = []

    init(_ results: [ProcessResult]) {
        self.results = results
    }

    var invocations: [SecurityInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(.init(executable: executable, arguments: arguments))
        guard !results.isEmpty else {
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        return results.removeFirst()
    }
}
