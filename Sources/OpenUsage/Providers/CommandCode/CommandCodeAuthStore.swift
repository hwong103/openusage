import Foundation

struct CommandCodeAuth: Hashable, Sendable {
    var apiKey: String
}

enum CommandCodeAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialsUnreadable
    case invalidCredentials
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run cmd login and try again."
        case .credentialsUnreadable:
            return "Couldn't read Command Code credentials. Check ~/.commandcode/auth.json permissions or sign in again."
        case .invalidCredentials:
            return "Command Code credentials are invalid. Run cmd login again."
        case .sessionExpired:
            return "Command Code session expired. Run cmd login again."
        }
    }
}

/// Reads credentials already present on this Mac. The CLI environment variable wins, followed by the
/// standard Command Code login file. The router key is a final fallback for this fork's own install.
struct CommandCodeAuthStore: Sendable {
    static let environmentNames = ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"]
    static let credentialPaths = [
        "~/.commandcode/auth.json",
        "~/.codex/codex-router/commandcode-api-key.secret"
    ]

    var files: TextFileAccessing
    var environment: EnvironmentReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.environment = environment
    }

    func loadAuth() throws -> CommandCodeAuth? {
        for name in Self.environmentNames {
            if let key = trimmed(environment.value(for: name)) {
                return CommandCodeAuth(apiKey: key)
            }
        }

        var materialError: CommandCodeAuthError?
        for path in Self.credentialPaths {
            do {
                guard let text = try files.readTextIfPresent(path) else { continue }
                do {
                    if let key = try credentialKey(from: text) {
                        return CommandCodeAuth(apiKey: key)
                    }
                    materialError = .invalidCredentials
                } catch {
                    materialError = .invalidCredentials
                }
            } catch {
                materialError = .credentialsUnreadable
            }
        }
        if let materialError { throw materialError }
        return nil
    }

    func hasCredentialMaterial() -> Bool {
        Self.environmentNames.contains { trimmed(environment.value(for: $0)) != nil }
            || Self.credentialPaths.contains(where: files.exists)
    }

    private func credentialKey(from text: String) throws -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("{") {
            guard let data = value.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(CredentialPayload.self, from: data),
                  let key = trimmed(payload.apiKey)
            else {
                return nil
            }
            return key
        }
        guard value.split(whereSeparator: \.isWhitespace).count == 1 else { return nil }
        return value
    }

    private func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct CredentialPayload: Decodable {
    var apiKey: String?
}
