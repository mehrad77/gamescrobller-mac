import Foundation
import Security  // the Keychain: SecItemAdd, SecItemCopyMatching, ...

/// Keeps the GameScrobbler token in the macOS Keychain, the system's encrypted
/// store for passwords, instead of in a plain file or `UserDefaults`.
///
/// The token is a *generic password* item, found again by two attributes:
/// `service` (which app) and `account` (which secret). You can see the item in
/// the Keychain Access app by searching for the service name.
///
/// The Keychain API is C: every call takes a dictionary of `kSec...` keys and
/// returns an `OSStatus` code, where `errSecSuccess` (0) means it worked.
public struct KeychainTokenStore: Sendable {
    public let service: String
    public let account: String

    public init(
        service: String = "io.github.mehrad77.GameScrobbler",
        account: String = "personal-access-token"
    ) {
        self.service = service
        self.account = account
    }

    /// The attributes that name our one item. `[String: Any]` because the C API
    /// mixes value types; `as String` turns each `CFString` key into a Swift one.
    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Whether a token is saved, without reading it. Reading the secret itself
    /// can show a "GameScrobbler wants to use your keychain" prompt; asking
    /// only whether the item exists never does.
    public func hasToken() throws(KeychainError) -> Bool {
        let status = SecItemCopyMatching(itemQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainError(status: status)
        }
    }

    /// The saved token, or nil when there is none.
    public func token() throws(KeychainError) -> String? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        // `CFTypeRef?` is "any Core Foundation object, or nothing". The C call
        // fills it through the `&result` pointer.
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw KeychainError(status: errSecDecode)
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Saves the token, replacing any saved before.
    public func save(_ token: String) throws(KeychainError) {
        let data = Data(token.utf8)
        // Try to update the existing item first; add one only if none exists.
        let status = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = itemQuery
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "GameScrobbler personal access token"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    /// Deletes the saved token. Deleting when there is none is not an error.
    public func delete() throws(KeychainError) {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// A Keychain call that failed, with the system's own explanation.
public struct KeychainError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        // `SecCopyErrorMessageString` turns a code such as -25293 into text.
        // `as String?` bridges the Core Foundation string to a Swift one.
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
