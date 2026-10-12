import Darwin
import Foundation
import Security
import Synchronization

protocol EnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

struct ProcessEnvironmentReader: EnvironmentReading {
    var processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    var shellEnvironment: LoginShellEnvironment = .shared
    var launchSnapshot: @Sendable () -> ShellEnvironmentSnapshot? = { ShellEnvironmentSnapshotStore.launchSnapshot }

    private static let identityKeys = Set(ShellEnvironmentSnapshot.capturedKeys)

    func value(for name: String) -> String? {
        // The process environment first (set by launchd, `launchctl setenv`, or a terminal launch),
        // then the captured login-shell environment — so keys a user exports in their shell profile
        // still resolve in a packaged app launched from Finder/Dock. See `LoginShellEnvironment`.
        if let value = processEnvironment[name]?.nilIfEmpty {
            return value
        }
        // Identity-relevant keys (provider home overrides, OAuth endpoint switches) resolve from the
        // persisted shell-environment snapshot when one exists: those facts — including "verifiably
        // NOT exported" — are frozen for the whole session, so every reader (the launch account pass
        // at init, the provider auth stores and log scanners whenever they run) sees the same home
        // overrides no matter when the async login-shell capture lands. Without the pin, an export
        // changed since the last launch would split them: identity read from the snapshot's home,
        // usage fetched from the freshly captured one, mis-stamping the shared snapshot cache. A
        // changed export applies from the next launch (the snapshot refresh task persists and logs
        // it). Every other key reads the live capture as before.
        if Self.identityKeys.contains(name), let snapshot = launchSnapshot() {
            return snapshot.values[name]?.nilIfEmpty
        }
        return shellEnvironment.value(for: name)
    }
}

protocol TextFileAccessing: Sendable {
    func exists(_ path: String) -> Bool
    /// Read a UTF-8 file when it exists. `nil` means the path is absent; permission, encoding, and
    /// other failures still throw so credential callers do not confuse broken storage with logout.
    func readTextIfPresent(_ path: String) throws -> String?
    func readText(_ path: String) throws -> String
    func writeText(_ path: String, _ text: String) throws
    /// Remove the file at `path`. A missing file is not an error — the caller wants the key gone, and
    /// it already is. Used by the in-app API-key editor's Remove / Clear-override actions.
    func remove(_ path: String) throws
}

extension TextFileAccessing {
    /// Compatibility path for test doubles. The production accessor classifies the read error directly
    /// so it does not have an exists-then-read race.
    func readTextIfPresent(_ path: String) throws -> String? {
        guard exists(path) else { return nil }
        return try readText(path)
    }
}

struct LocalTextFileAccessor: TextFileAccessing {
    /// Credential and token files must never be readable by another local account. Write through a
    /// private temporary file in the destination directory, flush it, then rename it over the target:
    /// the final replacement is atomic and has mode 0600 from the moment it becomes addressable.
    private static let privateFileMode = mode_t(S_IRUSR | S_IWUSR)

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expandHome(path))
    }

    func readText(_ path: String) throws -> String {
        try String(contentsOfFile: expandHome(path), encoding: .utf8)
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        do {
            return try readText(path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeText(_ path: String, _ text: String) throws {
        let expanded = expandHome(path)
        let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let destination = URL(fileURLWithPath: expanded)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, Self.privateFileMode)
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }

        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryExists {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }

        // A process umask may only remove permissions at creation. Reassert the exact private mode on
        // the still-unpublished inode before writing or renaming it into place.
        guard Darwin.fchmod(descriptor, Self.privateFileMode) == 0 else {
            throw Self.currentPOSIXError()
        }
        try Self.writeAll(Data(text.utf8), to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw Self.currentPOSIXError() }

        let renameResult = temporary.path.withCString { source in
            expanded.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else { throw Self.currentPOSIXError() }
        temporaryExists = false
    }

    func remove(_ path: String) throws {
        let expanded = expandHome(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        try FileManager.default.removeItem(atPath: expanded)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

protocol SQLiteAccessing: Sendable {
    func queryValue(path: String, sql: String) throws -> String?
    func execute(path: String, sql: String) throws
}

struct SQLiteCLIAccessor: SQLiteAccessing {
    var processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func queryValue(path: String, sql: String) throws -> String? {
        // A normal sqlite3 open can create a missing database. Credential probes must be read-only and
        // side-effect free, so absence returns nil before a process is launched.
        guard try databaseExists(path) else { return nil }
        var result = try run(path: path, sql: sql, mode: .readOnly)
        // A WAL-mode database whose -shm file cannot be opened read-only fails to open under
        // -readonly. Retry with a connection that may set up the WAL sidecars but is still refused any
        // write by `PRAGMA query_only`; a genuine error fails the same way again.
        if !result.succeeded {
            result = try run(path: path, sql: sql, mode: .queryOnly)
        }
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func execute(path: String, sql: String) throws {
        let result = try run(path: path, sql: sql)
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
    }

    private enum OpenMode {
        case readWrite, readOnly, queryOnly
    }

    private func run(path: String, sql: String, mode: OpenMode = .readWrite) throws -> ProcessResult {
        var arguments = ["-batch", "-noheader"]
        switch mode {
        case .readWrite: break
        case .readOnly: arguments.append("-readonly")
        case .queryOnly: arguments += ["-cmd", "PRAGMA query_only = ON"]
        }
        arguments += [
            "-cmd", ".timeout 1000",
            expandHome(path),
            sql
        ]
        return try processRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
    }

    private func databaseExists(_ path: String) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: expandHome(path))
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }
}

enum SQLiteError: Error, LocalizedError, Equatable {
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .queryFailed(let message):
            return message.isEmpty ? "SQLite query failed." : message
        }
    }
}

protocol KeychainAccessing: Sendable {
    func readGenericPassword(service: String) throws -> String?
    func writeGenericPassword(service: String, value: String) throws
    func readGenericPasswordForCurrentUser(service: String) throws -> String?
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws
    /// Read a generic password scoped to an explicit account (`-a`). Used when another app stored the
    /// item under a known account name (e.g. Antigravity's `agy` token under service `gemini`,
    /// account `antigravity`) rather than the current user.
    func readGenericPassword(service: String, account: String) throws -> String?
    /// Update the item belonging to this exact account, without changing another account's login.
    func writeGenericPassword(service: String, account: String, value: String) throws
}

extension KeychainAccessing {
    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writeGenericPassword(service: service, value: value)
    }

    /// Default for mocks that don't model accounts: fall back to the service-only lookup. The real
    /// `SecurityKeychainAccessor` overrides this to pass `-a <account>`.
    func readGenericPassword(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    /// An accessor without scoped-write support must fail rather than drop the account and risk
    /// overwriting a different login. The production accessor implements the explicit `-a` write.
    func writeGenericPassword(service: String, account: String, value: String) throws {
        throw KeychainError.writeFailed("Account-scoped Keychain writes are unavailable.")
    }

    /// Whether an item exists for `service`, without reading its secret. `nil` means the probe
    /// itself failed (locked keychain, denied) — the caller picks its own safe side, which is not
    /// the same for every caller. The default (for mocks) falls back to a read; the real
    /// `SecurityKeychainAccessor` overrides this with an in-process attributes-only probe, safe for
    /// the launch path — it can't trigger an unlock prompt and returns in microseconds.
    func genericPasswordExists(service: String) -> Bool? {
        do {
            return try readGenericPassword(service: service) != nil
        } catch {
            return nil
        }
    }
}

protocol SecurityItemAccessing: Sendable {
    func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?)
    func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?)
    func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus
    func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus
}

struct SystemSecurityItemAccessor: SecurityItemAccessing {
    /// Background reads must never raise UI. Every secret read in this app starts from a refresh or a
    /// launch probe — there is no user-initiated "reveal my credential" action — so the query forbids
    /// interaction (`kSecUseAuthenticationUIFail`) and a locked/unauthorized item fails fast with
    /// `errSecInteractionNotAllowed` instead of opening a Keychain password modal. Callers surface that
    /// as an error in the UI. Kept in one builder so a test can assert the policy.
    static func secretReadQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        let query = Self.secretReadQuery(service: service, account: account)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            // The attributes probe runs on the same background paths as the secret read; forbid UI here
            // too so an unauthorized item fails fast rather than prompting.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let account = (result as? [String: Any])?[kSecAttrAccount as String] as? String ?? ""
        return (status, account)
    }

    func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        SecItemUpdate(
            itemQuery(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        var attributes = itemQuery(service: service, account: account)
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func itemQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
}

/// Reads and writes other-app and app-own Keychain items through Apple's `/usr/bin/security` tool.
///
/// Items whose ACL partition list is `apple-tool:` — the Claude Code CLI's `Claude Code-credentials`,
/// and anything an older OpenUsage build created through this same tool — are unreachable from a
/// locally-signed app in-process: `SecItemCopyMatching` can never match that partition, so macOS raises
/// a Keychain password prompt, and the XARA "always allow" grant it leaves behind is attached to item
/// state and dies the moment the item is rewritten. The `/usr/bin/security` subprocess is Apple-signed,
/// so its partition matches and the same access is silent — this is how the reader worked before
/// `bb7de176` moved it in-process.
///
/// Used for the Claude CLI credential items, the launch-path existence probe, and the app's own
/// Keychain items. Writes also give any item this app creates an `apple-tool:` partition, so every
/// later build can read and rewrite it silently instead of prompting once per rebuild. CLI items
/// belonging to other tools (Codex, Cursor, gh) keep `SecurityKeychainAccessor` in-process.
struct AppleToolKeychainAccessor: KeychainAccessing {
    /// `security find-generic-password` exits 44 (`errSecItemNotFound`) when nothing matches — the
    /// legitimate "no credential stored" case. Any other non-zero exit is a real failure (locked
    /// keychain, denied read) that must not be silently rendered as "not signed in".
    private static let itemNotFoundExitCode: Int32 = 44
    private static let securityTool = "/usr/bin/security"
    private static let timeout: TimeInterval = 5

    let processRunner: any ProcessRunning

    init(processRunner: any ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func readGenericPassword(service: String) throws -> String? {
        try readPassword(["find-generic-password", "-s", service, "-w"], service: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readPassword(
            ["find-generic-password", "-a", currentUserAccount(), "-s", service, "-w"],
            service: service
        )
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try readPassword(["find-generic-password", "-a", account, "-s", service, "-w"], service: service)
    }

    func writeGenericPassword(service: String, value: String) throws {
        try writePassword(["add-generic-password", "-U", "-s", service, "-w", value], service: service)
    }

    func writeGenericPassword(service: String, account: String, value: String) throws {
        try writePassword(
            ["add-generic-password", "-U", "-a", account, "-s", service, "-w", value],
            service: service
        )
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writePassword(
            ["add-generic-password", "-U", "-a", currentUserAccount(), "-s", service, "-w", value],
            service: service
        )
    }

    /// Attributes-only existence probe: `find-generic-password -s <service>` with no `-w`, so the
    /// secret is never requested. `true` — an item exists; `false` — definitively absent (exit 44);
    /// `nil` — the probe itself failed (locked or denied), which callers read as "unknown" and resolve
    /// on their own safe side. Runs as a subprocess, so it is never on a caller's critical thread and
    /// can never raise a Keychain modal for an `apple-tool:` item.
    func genericPasswordExists(service: String) -> Bool? {
        let result: ProcessResult
        do {
            result = try runSecurity(["find-generic-password", "-s", service])
        } catch {
            AppLog.warn(.keychain, "existence probe failed for service '\(service)' (subprocess error)")
            return nil
        }
        switch result.exitCode {
        case 0:
            return true
        case Self.itemNotFoundExitCode:
            return false
        default:
            AppLog.warn(.keychain, "existence probe failed for service '\(service)' (exit \(result.exitCode))")
            return nil
        }
    }

    private func readPassword(_ arguments: [String], service: String) throws -> String? {
        let result = try runSecurity(arguments)
        guard result.succeeded else {
            if result.exitCode == Self.itemNotFoundExitCode {
                // The store already logs its own "read miss" per candidate source; stay quiet here.
                return nil
            }
            // Log the service and exit code only — never the credential material.
            AppLog.warn(.keychain, "read failed for service '\(service)' (exit \(result.exitCode))")
            throw KeychainError.readFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func writePassword(_ arguments: [String], service: String) throws {
        let result = try runSecurity(arguments)
        guard result.succeeded else {
            AppLog.warn(.keychain, "write failed for service '\(service)' (exit \(result.exitCode))")
            throw KeychainError.writeFailed(result.stderr)
        }
    }

    private func runSecurity(_ arguments: [String]) throws -> ProcessResult {
        try processRunner.run(
            executable: Self.securityTool,
            arguments: arguments,
            environment: [:],
            timeout: Self.timeout
        )
    }

    private func currentUserAccount() -> String {
        ProcessInfo.processInfo.environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? NSUserName()
    }
}

struct SecurityKeychainAccessor: KeychainAccessing {
    // Prevent concurrent refreshes for a service from stacking authorization dialogs before the first grant lands.
    private static let accessLocks = Mutex<[String: NSLock]>([:])
    let itemAccessor: any SecurityItemAccessing
    let processRunner: any ProcessRunning

    init(
        itemAccessor: any SecurityItemAccessing = SystemSecurityItemAccessor(),
        processRunner: any ProcessRunning = SystemProcessRunner()
    ) {
        self.itemAccessor = itemAccessor
        self.processRunner = processRunner
    }

    func readGenericPassword(service: String) throws -> String? {
        try readPassword(service: service, account: nil)
    }

    /// Attributes-only existence probe used on the launch path. It must run through the Apple-signed
    /// `/usr/bin/security` tool: an in-process query from this locally-signed build cannot match an
    /// `apple-tool:` ACL partition, and `kSecUseAuthenticationUIFail` does not suppress that legacy
    /// ACL/XARA prompt, so the attributes-only form still raised a password modal at launch. The
    /// subprocess partition matches, so the probe is silent. A failed probe reports `nil` ("unknown"),
    /// never a definite answer, so callers can pick their safe side. See `AppleToolKeychainAccessor`.
    func genericPasswordExists(service: String) -> Bool? {
        AppleToolKeychainAccessor(processRunner: processRunner).genericPasswordExists(service: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readPassword(service: service, account: currentUserAccount())
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try readPassword(service: service, account: account)
    }

    private func readPassword(service: String, account: String?) throws -> String? {
        let result = Self.withAccessLock(service: service) {
            itemAccessor.readGenericPasswordData(service: service, account: account)
        }
        guard result.status == errSecSuccess else {
            if result.status == errSecItemNotFound { return nil }
            let message = Self.errorMessage(for: result.status)
            AppLog.warn(.keychain, "read failed for service '\(service)' (\(result.status)): \(message)")
            throw KeychainError.readFailed(message)
        }
        guard let data = result.data, let password = String(data: data, encoding: .utf8) else {
            let message = "Keychain item for service '\(service)' is not valid UTF-8."
            AppLog.warn(.keychain, message)
            throw KeychainError.readFailed(message)
        }
        let value = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func writeGenericPassword(service: String, value: String) throws {
        try writePassword(service: service, account: nil, value: value)
    }

    func writeGenericPassword(service: String, account: String, value: String) throws {
        try writePassword(service: service, account: account, value: value)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writePassword(service: service, account: currentUserAccount(), value: value)
    }

    private func writePassword(service: String, account: String?, value: String) throws {
        let data = Data(value.utf8)
        let status = Self.withAccessLock(service: service) {
            if account == nil {
                let lookup = itemAccessor.firstGenericPasswordAccount(service: service)
                if lookup.status == errSecItemNotFound {
                    return itemAccessor.addGenericPasswordData(service: service, account: nil, data: data)
                }
                guard lookup.status == errSecSuccess else { return lookup.status }
                return updateOrAddPassword(
                    service: service,
                    account: lookup.account ?? "",
                    data: data
                )
            }
            return updateOrAddPassword(service: service, account: account, data: data)
        }
        guard status == errSecSuccess else {
            let message = Self.errorMessage(for: status)
            AppLog.warn(.keychain, "write failed for service '\(service)' (\(status)): \(message)")
            throw KeychainError.writeFailed(message)
        }
    }

    private func updateOrAddPassword(service: String, account: String?, data: Data) -> OSStatus {
        let updateStatus = itemAccessor.updateGenericPasswordData(
            service: service,
            account: account,
            data: data
        )
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        return itemAccessor.addGenericPasswordData(service: service, account: account, data: data)
    }

    private static func withAccessLock<T>(service: String, _ operation: () throws -> T) rethrows -> T {
        let lock = accessLocks.withLock { locks in
            if let lock = locks[service] { return lock }
            let lock = NSLock()
            locks[service] = lock
            return lock
        }
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func errorMessage(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }

    private func currentUserAccount() -> String {
        ProcessInfo.processInfo.environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? NSUserName()
    }
}

enum KeychainError: Error, LocalizedError {
    case writeFailed(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return message.isEmpty ? "Keychain write failed." : message
        case .readFailed(let message):
            return message.isEmpty ? "Keychain read failed." : message
        }
    }
}

func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return home + String(path.dropFirst())
}
