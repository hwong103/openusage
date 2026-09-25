import Foundation
import Security

enum ProcessCodeSignature {
    /// Whether the running executable has only an ad-hoc signature.
    ///
    /// Stable code identities can retain Keychain ACLs across rebuilds. An ad-hoc process cannot
    /// cleanly acquire those ACLs, so callers use this to avoid externally owned Keychain prompts
    /// and blocking lookups in locally staged builds.
    static func isAdHoc() -> Bool {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return false
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let information = information as? [String: Any],
              let signatureFlags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        else {
            return false
        }

        // `kSecCodeSignatureAdhoc` is declared in CSCommon.h but not imported by Swift.
        let adHocSignatureFlag: UInt32 = 0x0002
        return signatureFlags & adHocSignatureFlag != 0
    }
}
