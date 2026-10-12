import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        codex: CodexAccountDiscovery = CodexAccountDiscovery(),
        claudeIdentityKeys: [String: String] = [:]
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name.
        // Claude Desktop's Keychain item is opt-in; see `ClaudeDesktopImportSetting`. Read live so
        // flipping the Settings toggle applies on the next refresh rather than at relaunch.
        let desktopImportEnabled: @Sendable () -> Bool = { ClaudeDesktopImportSetting.isEnabled }
        var providers: [ProviderRuntime]
        if claudeCards.isEmpty {
            providers = [ClaudeProvider(authStore: ClaudeAuthStore(desktopImportEnabled: desktopImportEnabled))]
        } else {
            providers = claudeCards.map { card in
                let identity = claudeIdentityKeys[card.id] ?? card.identityKey
                let user = identity.split(separator: "|").first.map(String.init)
                let scanner = ClaudeLogUsageScanner(
                    accountUUID: user, organizationUUID: card.organizationID,
                    allowsUnattributedSessions: card.allowsUnattributedPiUsage,
                    additionalConfigDirectories: card.additionalLogDirectories
                )
                return ClaudeProvider(
                    provider: ClaudeProvider.makeProvider(
                        id: card.id,
                        displayName: claudeCards.count == 1 ? "Claude" : card.displayName
                    ),
                    authStore: ClaudeAuthStore(
                        desktopOrganization: card.organizationID,
                        expectedIdentityKey: identity,
                        desktopOnly: card.usesDesktopCredentials,
                        swapAccount: card.swapAccount,
                        preferOrganizationScopedDesktop: claudeCards.count > 1
                            && card.organizationID != nil && !card.usesDesktopCredentials,
                        desktopImportEnabled: desktopImportEnabled
                    ),
                    logUsageScanner: scanner,
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage
                )
            }
        }
        if codex.cards.isEmpty {
            providers.append(CodexProvider(
                authStore: CodexAuthStore(
                    additionalAuthHomes: codex.plainAuthHomes,
                    writableAuthHomes: Set(codex.plainWritableAuthHomes),
                    piCredentialSources: codex.plainPiCredentialSources
                ),
                logUsageScanner: CodexLogUsageScanner(additionalHomes: codex.plainAuthHomes)
            ))
        } else {
            providers += codex.cards.map { card in
                CodexProvider(
                    provider: CodexProvider.makeProvider(id: card.id, displayName: card.displayName),
                    authStore: CodexAuthStore(
                        expectedIdentity: card.identity,
                        additionalAuthHomes: card.authHomes,
                        writableAuthHomes: Set(card.writableAuthHomes),
                        piCredentialSources: card.piCredentialSources
                    ),
                    historyScope: .account(card.identity, codex.historyHomes, claimsPiUsage: card.claimsPiUsage)
                )
            }
        }
        providers += [
            CursorProvider(),
            AntigravityProvider(),
            CommandCodeProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            OllamaProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
        return providers
    }
}
