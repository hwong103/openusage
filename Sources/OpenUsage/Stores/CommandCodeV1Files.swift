import Foundation

/// Moves the fork's 0.7.x Command Code key into the 0.8 account store once. The old build read the
/// environment, `~/.commandcode/auth.json`, or the fork's router key. A key is saved only after Command
/// Code accepts it, and no path reads or prints another tool's credentials again.
enum CommandCodeV1Files {
    static let importedKey = "openusage.commandCodeKey.v1.imported"
    /// Only the fork's explicitly named development install imports the old key. A generic upstream
    /// development build still follows 0.8's account-owned boundary.
    static let migrationBundleIdentifier = "com.robinebers.openusage.dev"

    @MainActor
    static func importOnce(
        into accounts: AccountStore,
        defaults: UserDefaults = .standard,
        home: URL = .homeDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        http: any HTTPClient = URLSessionHTTPClient(),
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) async {
        guard DefaultsKey.isDedicatedDevelopmentInstall(bundleIdentifier),
              !defaults.bool(forKey: importedKey),
              !accounts.accounts.contains(where: { $0.kind == .commandcode })
        else { return }

        guard let key = firstKey(home: home, environment: environment) else {
            defaults.set(true, forKey: importedKey)
            return
        }
        let account = Account(kind: .commandcode, label: "Command Code")
        let runtime = AccountProviderRuntime(account: account, vault: accounts.credentialVault, http: http)
        do {
            try await runtime.readSnapshot(using: .apiKey(key))
            guard !accounts.accounts.contains(where: { $0.kind == .commandcode }) else { return }
            let added = accounts.add(kind: .commandcode, label: "Command Code", credential: .apiKey(key))
            guard accounts.accounts.contains(where: { $0.id == added.id }) else {
                AppLog.warn(.config, "could not save the imported Command Code key; trying again next launch")
                return
            }
            defaults.set(true, forKey: importedKey)
            AppLog.notice(.config, "imported the 0.7.x Command Code key")
        } catch ProviderError.keyRejected(let message) {
            defaults.set(true, forKey: importedKey)
            AppLog.warn(.config, "did not import the 0.7.x Command Code key: \(message)")
        } catch {
            AppLog.warn(.config, "could not check the 0.7.x Command Code key; trying again next launch: \(error.localizedDescription)")
        }
    }

    static func firstKey(home: URL, environment: [String: String]) -> String? {
        for name in ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"] {
            if let key = nonempty(environment[name]) { return key }
        }
        for path in [
            home.appending(path: ".commandcode/auth.json"),
            home.appending(path: ".codex/codex-router/commandcode-api-key.secret")
        ] {
            guard let data = try? Data(contentsOf: path) else { continue }
            if let key = jsonKey(data) ?? plainKey(data) { return key }
        }
        return nil
    }

    private static func jsonKey(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return nonempty(object["apiKey"] as? String)
    }

    private static func plainKey(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return nonempty(text)
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private enum DefaultsKey {
    /// The dedicated development bundle. The official installer uses the production bundle ID and never
    /// runs this migration.
    static func isDedicatedDevelopmentInstall(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == CommandCodeV1Files.migrationBundleIdentifier
    }
}
