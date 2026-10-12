import Foundation
import XCTest
@testable import OpenUsage

/// Acceptance: the Claude store's keychain read **and** its rotation write both go through the
/// injected accessor. In production that accessor is the Apple-signed `/usr/bin/security` reader, so a
/// locally-signed build never trips the Keychain ACL-partition prompt.
final class ClaudeCLIKeychainRoutingTests: XCTestCase {
    private static let credentialBlob = #"""
    {"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}
    """#

    func testClaudeAuthStoreDefaultsToAppleToolAccessor() {
        // The default is what every un-parameterised construction path picks up (`ProviderCatalog`,
        // `ClaudeProvider`, the swap-account inner store), so it has to be the CLI accessor.
        XCTAssertTrue(ClaudeAuthStore().keychain is AppleToolKeychainAccessor)
    }

    func testLoadReadsTheClaudeServiceThroughTheInjectedAccessor() throws {
        let service = "Claude Code-credentials"
        let keychain = ServiceKeychain(currentUserValues: [service: Self.credentialBlob])
        let store = makeStore(keychain: keychain)

        let candidate = try XCTUnwrap(store.loadCredentialSet().candidates.first)

        XCTAssertEqual(candidate.source, ClaudeCredentialState.Source.keychainCurrentUser(service: service))
        XCTAssertEqual(candidate.oauth.accessToken, "old-access" as String?)
    }

    func testRotationWritePersistsThroughTheInjectedAccessor() throws {
        let service = "Claude Code-credentials"
        let keychain = ServiceKeychain(currentUserValues: [service: Self.credentialBlob])
        let store = makeStore(keychain: keychain)
        let generation = store.credentialGeneration()
        var state = try XCTUnwrap(store.loadCredentialSet().candidates.first)
        state.oauth.accessToken = "rotated-access"
        state.oauth.refreshToken = "rotated-refresh"

        XCTAssertTrue(try store.save(state, ifUnchanged: generation))

        let written = try XCTUnwrap(keychain.currentUserValues[service])
        XCTAssertTrue(written.contains("rotated-access"))
        XCTAssertTrue(written.contains("rotated-refresh"))
        // The write must land on the account-scoped item, not the legacy service-only slot.
        XCTAssertNil(keychain.values[service])
    }

    private func makeStore(keychain: ServiceKeychain) -> ClaudeAuthStore {
        let now = Date(timeIntervalSince1970: 1_771_603_200)
        return ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles(),
            keychain: keychain,
            desktopImportEnabled: { false },
            now: { now }
        )
    }
}
