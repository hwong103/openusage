import Foundation

/// Whether OpenUsage may open Claude Desktop's `Claude Safe Storage` Keychain item.
///
/// Off by default in this fork. That item's partition list is scoped to each signed build's cdhash, and
/// this fork is signed with a self-signed certificate (no Team ID), so every rebuild looks like a
/// brand-new app to macOS and it asks for the Keychain password again. The dialog cannot be suppressed
/// in code: on macOS the "fail instead of prompting" flags only apply to items in the Data Protection
/// Keychain, and this is a legacy login-Keychain item (see `SecItem.h`). The only reliable way to stop
/// the prompting is to not open the item unless the user asks for it.
///
/// With this off, Claude's meters come from the Claude Code login — its Keychain item or credentials
/// file — plus local logs, which is the source the app already prefers when one is usable. Turning it
/// on imports a Claude Desktop login (and any extra organizations it knows about), at the cost of one
/// Keychain prompt per freshly built app.
enum ClaudeDesktopImportSetting {
    static let key = "importClaudeDesktopLogin"

    /// The value the Settings toggle starts from, and the answer when nothing is stored yet.
    static let fallback = false

    static var isEnabled: Bool {
        isEnabled(in: .standard)
    }

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}
