import os
import Foundation
import Security

protocol CredentialVault: Sendable {
    func load(_ id: UUID) throws -> AccountCredential?
    func save(_ credential: AccountCredential, for id: UUID) throws
    func update(_ credential: AccountCredential, for id: UUID) throws
    func delete(_ id: UUID) throws
}

/// Holds one sign-in in memory, so a new one proves itself without seeing the sign-in it would replace.
struct ProvisionalCredentialVault: CredentialVault {
    private let stored: OSAllocatedUnfairLock<AccountCredential?>

    init(_ credential: AccountCredential) {
        stored = OSAllocatedUnfairLock(initialState: credential)
    }

    func load(_ id: UUID) throws -> AccountCredential? { stored.withLock { $0 } }
    func save(_ credential: AccountCredential, for id: UUID) throws { stored.withLock { $0 = credential } }
    func update(_ credential: AccountCredential, for id: UUID) throws { stored.withLock { $0 = credential } }
    func delete(_ id: UUID) throws { stored.withLock { $0 = nil } }
}

enum CredentialVaultError: LocalizedError {
    case missingCredential

    var errorDescription: String? {
        "This account's sign-in is missing from the Keychain. Sign in again from the account's page."
    }
}

struct KeychainCredentialVault: CredentialVault {
    static let service = "com.robinebers.openusage.accounts"
    private let items: KeychainItems

    init(processRunner: any ProcessRunning = SystemProcessRunner()) {
        items = KeychainItems(service: Self.service, processRunner: processRunner)
    }

    func load(_ id: UUID) throws -> AccountCredential? {
        guard let data = try items.load(id) else { return nil }
        do {
            return try JSONDecoder().decode(AccountCredential.self, from: data)
        } catch {
            AppLog.error(.auth, "could not decode the Keychain credential for \(id.uuidString): \(error)")
            throw error
        }
    }

    func save(_ credential: AccountCredential, for id: UUID) throws {
        try items.save(JSONEncoder().encode(credential), for: id)
    }

    func update(_ credential: AccountCredential, for id: UUID) throws {
        try items.update(JSONEncoder().encode(credential), for: id)
    }

    func delete(_ id: UUID) throws {
        try items.delete(id)
    }
}

/// The generic-password items of one Keychain service, one per id.
///
/// Local development builds are ad-hoc signed, so their code identity changes on every rebuild and
/// `SecItemCopyMatching` can wait on an ACL prompt left by an older build. Apple's signed
/// `/usr/bin/security` helper carries the stable `apple-tool:` identity, reads and rewrites these
/// items without prompting, and keeps each credential scoped to its account UUID.
struct KeychainItems: Sendable {
    private static let securityTool = "/usr/bin/security"
    private static let itemNotFoundExitCode: Int32 = 44
    private static let timeout: TimeInterval = 5

    let service: String
    let processRunner: any ProcessRunning

    init(service: String, processRunner: any ProcessRunning = SystemProcessRunner()) {
        self.service = service
        self.processRunner = processRunner
    }

    func load(_ id: UUID) throws -> Data? {
        let result = try run(["find-generic-password", "-a", account(for: id), "-s", service, "-w"])
        if result.exitCode == Self.itemNotFoundExitCode { return nil }
        guard result.succeeded else { throw KeychainVaultError.commandFailed(result.exitCode) }
        guard let data = result.stdout.data(using: .utf8) else {
            throw KeychainVaultError.invalidData
        }
        return data
    }

    func save(_ data: Data, for id: UUID) throws {
        if try probe(id) == .present {
            try delete(id)
        }
        try write(data, for: id)
    }

    func update(_ data: Data, for id: UUID) throws {
        guard try probe(id) == .present else { throw CredentialVaultError.missingCredential }
        try delete(id)
        try write(data, for: id)
    }

    func delete(_ id: UUID) throws {
        let result = try run(["delete-generic-password", "-a", account(for: id), "-s", service])
        guard result.succeeded || result.exitCode == Self.itemNotFoundExitCode else {
            throw KeychainVaultError.commandFailed(result.exitCode)
        }
    }

    private enum ItemState {
        case absent
        case present
    }

    /// An ACL-protected legacy item can be found but never read or updated. Writes replace the item
    /// through Apple's security tool once the caller has the complete replacement credential.
    private func probe(_ id: UUID) throws -> ItemState {
        let result = try run(["find-generic-password", "-a", account(for: id), "-s", service])
        switch result.exitCode {
        case 0:
            return .present
        case Self.itemNotFoundExitCode:
            return .absent
        default:
            throw KeychainVaultError.commandFailed(result.exitCode)
        }
    }

    private func write(_ data: Data, for id: UUID) throws {
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainVaultError.invalidData
        }
        let result = try run([
            "add-generic-password", "-U", "-a", account(for: id), "-s", service, "-w", value,
        ])
        guard result.succeeded else { throw KeychainVaultError.commandFailed(result.exitCode) }
    }

    private func run(_ arguments: [String]) throws -> ProcessResult {
        try processRunner.run(
            executable: Self.securityTool,
            arguments: arguments,
            environment: [:],
            timeout: Self.timeout
        )
    }

    private func account(for id: UUID) -> String { id.uuidString }
}

enum KeychainVaultError: LocalizedError {
    case status(OSStatus)
    case commandFailed(Int32)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "OpenUsage couldn't use its Keychain item for this account (\(reason))."
        case .commandFailed(let status):
            return "OpenUsage couldn't use its Keychain item for this account (security exit \(status))."
        case .invalidData:
            return "OpenUsage couldn't encode or read this account's Keychain item."
        }
    }
}
