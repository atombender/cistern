import Foundation
import Security

class KeychainService {
    private static let service = "com.cistern.circleci"
    private static let account = "api-token"

    // Use UserDefaults for development (avoids Keychain prompts on rebuild)
    // In production with proper code signing, Keychain would work without prompts
    #if DEBUG
        private static let useKeychain = false
    #else
        private static let useKeychain = true
    #endif

    private static let tokenKey = "dev-api-token"

    static func hasToken() -> Bool {
        return getToken() != nil
    }

    static func getToken() -> String? {
        if useKeychain {
            return getTokenFromKeychain()
        } else {
            return UserDefaults.standard.string(forKey: tokenKey)
        }
    }

    static func setToken(_ token: String) -> Bool {
        if useKeychain {
            return setTokenInKeychain(token)
        } else {
            UserDefaults.standard.set(token, forKey: tokenKey)
            return true
        }
    }

    @discardableResult
    static func deleteToken() -> Bool {
        if useKeychain {
            return deleteTokenFromKeychain()
        } else {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            return true
        }
    }

    // MARK: - Keychain Implementation

    private static func getTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return token
    }

    private static func setTokenInKeychain(_ token: String) -> Bool {
        deleteTokenFromKeychain()

        guard let data = token.data(using: .utf8) else {
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    @discardableResult
    private static func deleteTokenFromKeychain() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
