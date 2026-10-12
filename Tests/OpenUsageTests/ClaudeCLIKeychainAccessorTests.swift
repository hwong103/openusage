import Foundation
import Security
import XCTest
@testable import OpenUsage

/// The Claude Code CLI stores its credential item with an `apple-tool:` ACL partition, which a
/// locally-signed build can never match in-process. These tests pin the replacement path: every read
/// and write for a `Claude Code*` service goes through the Apple-signed `/usr/bin/security` tool, so
/// macOS never raises a Keychain password prompt.
final class ClaudeCLIKeychainAccessorTests: XCTestCase {
    private static let service = "Claude Code-credentials"

    func testReadUsesAppleSecurityToolAndReturnsTrimmedValue() throws {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 0, stdout: "synthetic-blob\n", stderr: "")])
        let accessor = ClaudeCLIKeychainAccessor(processRunner: runner)

        XCTAssertEqual(try accessor.readGenericPassword(service: Self.service), "synthetic-blob")
        XCTAssertEqual(runner.invocations.map(\.executable), ["/usr/bin/security"])
        XCTAssertEqual(runner.invocations.first?.arguments, [
            "find-generic-password", "-s", Self.service, "-w",
        ])
    }

    func testCurrentUserReadScopesByAccount() throws {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 0, stdout: "synthetic-blob", stderr: "")])
        let accessor = ClaudeCLIKeychainAccessor(processRunner: runner)

        _ = try accessor.readGenericPasswordForCurrentUser(service: Self.service)

        let arguments = try XCTUnwrap(runner.invocations.first?.arguments)
        XCTAssertEqual(Array(arguments.prefix(4)), ["find-generic-password", "-a", NSUserName(), "-s"])
        XCTAssertEqual(arguments.last, "-w")
    }

    func testMissingItemExitCodeReturnsNilWithoutThrow() throws {
        // `security` exits 44 for `errSecItemNotFound`; that is "no credential stored", not a failure.
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 44, stdout: "", stderr: "")])
        let accessor = ClaudeCLIKeychainAccessor(processRunner: runner)

        XCTAssertNil(try accessor.readGenericPassword(service: Self.service))
    }

    func testLockedOrDeniedReadThrowsReadFailed() {
        let runner = ScriptedProcessRunner(results: [.init(
            exitCode: 51,
            stdout: "",
            stderr: "security: SecKeychainSearchCopyNext: The user name or passphrase you entered is not correct."
        )])
        let accessor = ClaudeCLIKeychainAccessor(processRunner: runner)

        XCTAssertThrowsError(try accessor.readGenericPassword(service: Self.service)) { error in
            guard case KeychainError.readFailed = error else {
                return XCTFail("expected KeychainError.readFailed, got \(error)")
            }
        }
    }

    func testRotationWriteUsesAddGenericPasswordUpdateForCurrentUser() throws {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 0, stdout: "", stderr: "")])
        let accessor = ClaudeCLIKeychainAccessor(processRunner: runner)

        try accessor.writeGenericPasswordForCurrentUser(service: Self.service, value: "rotated-blob")

        XCTAssertEqual(runner.invocations.first?.executable, "/usr/bin/security")
        XCTAssertEqual(runner.invocations.first?.arguments, [
            "add-generic-password", "-U", "-a", NSUserName(), "-s", Self.service, "-w", "rotated-blob",
        ])
    }

    func testLegacyWriteUsesServiceOnlyAdd() throws {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 0, stdout: "", stderr: "")])
        let accessor = ClaudeCLIKeychainAccessor(processRunner: runner)

        try accessor.writeGenericPassword(service: Self.service, value: "rotated-blob")

        XCTAssertEqual(runner.invocations.first?.arguments, [
            "add-generic-password", "-U", "-s", Self.service, "-w", "rotated-blob",
        ])
    }

    func testFailedWriteThrowsWriteFailed() {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 1, stdout: "", stderr: "denied")])
        let accessor = ClaudeCLIKeychainAccessor(processRunner: runner)

        XCTAssertThrowsError(try accessor.writeGenericPassword(service: Self.service, value: "rotated-blob")) {
            guard case KeychainError.writeFailed = $0 else {
                return XCTFail("expected KeychainError.writeFailed, got \($0)")
            }
        }
    }
}

/// In-process secret reads on the background refresh path must forbid authentication UI, so a locked
/// or unauthorized item fails fast and is reported in the UI instead of opening a modal.
final class SystemSecurityItemAccessorInteractionTests: XCTestCase {
    func testSecretReadQueryForbidsInteraction() {
        let query = SystemSecurityItemAccessor.secretReadQuery(service: "Claude Code-credentials", account: nil)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail)
        XCTAssertNil(query[kSecAttrAccount as String])
    }

    func testSecretReadQueryCarriesExplicitAccount() {
        let query = SystemSecurityItemAccessor.secretReadQuery(service: "Codex Auth", account: "cli|abc")
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "cli|abc")
    }
}

private struct ScriptedInvocation: Sendable, Equatable {
    var executable: String
    var arguments: [String]
}

private final class ScriptedProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessResult]
    private var recorded: [ScriptedInvocation] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    var invocations: [ScriptedInvocation] {
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
        recorded.append(ScriptedInvocation(executable: executable, arguments: arguments))
        guard !results.isEmpty else {
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let result = results.removeFirst()
        if results.isEmpty { results = [result] }
        return result
    }
}
