import Foundation
import Security
import XCTest
@testable import OpenUsage

/// The Claude Code CLI stores its credential item with an `apple-tool:` ACL partition, which a
/// locally-signed build can never match in-process. These tests pin the replacement path: every read
/// and write for a `Claude Code*` service goes through the Apple-signed `/usr/bin/security` tool, so
/// macOS never raises a Keychain password prompt.
final class AppleToolKeychainAccessorTests: XCTestCase {
    private static let service = "Claude Code-credentials"

    func testReadUsesAppleSecurityToolAndReturnsTrimmedValue() throws {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 0, stdout: "synthetic-blob\n", stderr: "")])
        let accessor = AppleToolKeychainAccessor(processRunner: runner)

        XCTAssertEqual(try accessor.readGenericPassword(service: Self.service), "synthetic-blob" as String?)
        XCTAssertEqual(runner.invocations.map(\.executable), ["/usr/bin/security"])
        let arguments = try XCTUnwrap(runner.invocations.first?.arguments)
        XCTAssertEqual(arguments, ["find-generic-password", "-s", Self.service, "-w"])
    }

    func testCurrentUserReadScopesByAccount() throws {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 0, stdout: "synthetic-blob", stderr: "")])
        let accessor = AppleToolKeychainAccessor(processRunner: runner)

        _ = try accessor.readGenericPasswordForCurrentUser(service: Self.service)

        let arguments = try XCTUnwrap(runner.invocations.first?.arguments)
        XCTAssertEqual(Array(arguments.prefix(4)), ["find-generic-password", "-a", NSUserName(), "-s"])
        XCTAssertEqual(arguments.last, "-w" as String?)
    }

    func testMissingItemExitCodeReturnsNilWithoutThrow() throws {
        // `security` exits 44 for `errSecItemNotFound`; that is "no credential stored", not a failure.
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 44, stdout: "", stderr: "")])
        let accessor = AppleToolKeychainAccessor(processRunner: runner)

        XCTAssertNil(try accessor.readGenericPassword(service: Self.service))
    }

    func testLockedOrDeniedReadThrowsReadFailed() {
        let runner = ScriptedProcessRunner(results: [.init(
            exitCode: 51,
            stdout: "",
            stderr: "security: SecKeychainSearchCopyNext: The user name or passphrase you entered is not correct."
        )])
        let accessor = AppleToolKeychainAccessor(processRunner: runner)

        XCTAssertThrowsError(try accessor.readGenericPassword(service: Self.service)) { error in
            guard case KeychainError.readFailed = error else {
                return XCTFail("expected KeychainError.readFailed, got \(error)")
            }
        }
    }

    func testRotationWriteUsesAddGenericPasswordUpdateForCurrentUser() throws {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 0, stdout: "", stderr: "")])
        let accessor = AppleToolKeychainAccessor(processRunner: runner)

        try accessor.writeGenericPasswordForCurrentUser(service: Self.service, value: "rotated-blob")

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executable, "/usr/bin/security")
        XCTAssertEqual(invocation.arguments, [
            "add-generic-password", "-U", "-a", NSUserName(), "-s", Self.service, "-w", "rotated-blob",
        ])
    }

    func testLegacyWriteUsesServiceOnlyAdd() throws {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 0, stdout: "", stderr: "")])
        let accessor = AppleToolKeychainAccessor(processRunner: runner)

        try accessor.writeGenericPassword(service: Self.service, value: "rotated-blob")

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.arguments, [
            "add-generic-password", "-U", "-s", Self.service, "-w", "rotated-blob",
        ])
    }

    func testFailedWriteThrowsWriteFailed() {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 1, stdout: "", stderr: "denied")])
        let accessor = AppleToolKeychainAccessor(processRunner: runner)

        XCTAssertThrowsError(try accessor.writeGenericPassword(service: Self.service, value: "rotated-blob")) {
            guard case KeychainError.writeFailed = $0 else {
                return XCTFail("expected KeychainError.writeFailed, got \($0)")
            }
        }
    }

    // MARK: - Existence probe

    func testExistenceProbeUsesSecurityToolWithoutRequestingTheSecret() throws {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 0, stdout: "synthetic-blob", stderr: "")])
        let accessor = AppleToolKeychainAccessor(processRunner: runner)

        XCTAssertEqual(accessor.genericPasswordExists(service: Self.service), true as Bool?)

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executable, "/usr/bin/security")
        XCTAssertEqual(invocation.arguments, ["find-generic-password", "-s", Self.service])
        XCTAssertFalse(invocation.arguments.contains("-w"))
    }

    func testExistenceProbeMapsMissingItemToFalse() {
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 44, stdout: "", stderr: "")])
        let accessor = AppleToolKeychainAccessor(processRunner: runner)

        XCTAssertEqual(accessor.genericPasswordExists(service: Self.service), false as Bool?)
    }

    func testExistenceProbeMapsAnyOtherFailureToUnknown() {
        // Locked or denied: "unknown", never a definite answer, so callers pick their safe side.
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 51, stdout: "", stderr: "denied")])
        let accessor = AppleToolKeychainAccessor(processRunner: runner)

        XCTAssertNil(accessor.genericPasswordExists(service: Self.service))
    }

    func testExistenceProbeMapsLaunchFailureToUnknown() {
        let accessor = AppleToolKeychainAccessor(processRunner: ThrowingProcessRunner())

        XCTAssertNil(accessor.genericPasswordExists(service: Self.service))
    }
}

/// The in-process accessor must not probe the Keychain itself any more: its existence probe has to
/// reach the Apple tool, or a locally-signed build re-prompts on `apple-tool:` items.
final class SecurityKeychainAccessorProbeRoutingTests: XCTestCase {
    func testExistenceProbeRoutesThroughTheAppleToolAndNotTheItemAccessor() {
        let itemAccessor = RecordingItemAccessor()
        let runner = ScriptedProcessRunner(results: [.init(exitCode: 0, stdout: "", stderr: "")])
        let accessor = SecurityKeychainAccessor(itemAccessor: itemAccessor, processRunner: runner)

        XCTAssertEqual(accessor.genericPasswordExists(service: "Codex Auth"), true as Bool?)

        XCTAssertEqual(runner.invocations.first?.executable, "/usr/bin/security")
        XCTAssertEqual(runner.invocations.first?.arguments, ["find-generic-password", "-s", "Codex Auth"])
        XCTAssertEqual(itemAccessor.readCount, 0)
    }
}

private final class RecordingItemAccessor: SecurityItemAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        lock.lock()
        reads += 1
        lock.unlock()
        return (errSecItemNotFound, nil)
    }

    func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) {
        lock.lock()
        reads += 1
        lock.unlock()
        return (errSecItemNotFound, nil)
    }

    func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        errSecItemNotFound
    }

    func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        errSecSuccess
    }
}

private struct ThrowingProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        throw ProcessRunnerError.timedOut(executable: executable, timeout: timeout)
    }
}

/// In-process secret reads on the background refresh path must forbid authentication UI, so a locked
/// or unauthorized item fails fast and is reported in the UI instead of opening a modal.
final class SystemSecurityItemAccessorInteractionTests: XCTestCase {
    func testSecretReadQueryForbidsInteraction() {
        let query = SystemSecurityItemAccessor.secretReadQuery(service: "Claude Code-credentials", account: nil)
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUIFail as String
        )
        XCTAssertNil(query[kSecAttrAccount as String])
    }

    func testSecretReadQueryCarriesExplicitAccount() {
        let query = SystemSecurityItemAccessor.secretReadQuery(service: "Codex Auth", account: "cli|abc")
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUIFail as String
        )
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "cli|abc" as String?)
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
