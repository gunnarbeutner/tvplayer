import Foundation
import Security

/// Persists the Tvheadend connection independently of the active Apple TV
/// profile. Everything else in the app continues to use the current user's
/// defaults and cache container.
struct SharedTVHeadendConfigurationStore {
    private struct Payload: Codable {
        let version: Int
        let serverProfileID: String?
        let baseURL: String?
        let username: String
        let password: String
        let streamProfile: String
        let htspPort: Int
        let guideCacheURL: String?
        let xmltvURL: String?
        let resolvedAddresses: [String]
        let guideResolvedAddresses: [String]
        let cachedAddressesObservedAt: Date?

        init(configuration: TVHeadendConfiguration) {
            version = 4
            serverProfileID = configuration.serverProfileID
            baseURL = configuration.baseURL?.absoluteString
            username = configuration.username
            password = configuration.password
            streamProfile = configuration.streamProfile
            htspPort = configuration.htspPort
            guideCacheURL = configuration.guideCacheURL?.absoluteString
            xmltvURL = configuration.xmltvURL?.absoluteString
            resolvedAddresses = configuration.resolvedAddresses
            guideResolvedAddresses = configuration.guideResolvedAddresses
            cachedAddressesObservedAt = configuration.cachedAddressesObservedAt
        }

        var configuration: TVHeadendConfiguration? {
            guard (1...4).contains(version) else { return nil }
            return TVHeadendConfiguration(
                serverProfileID: serverProfileID,
                baseURL: baseURL.flatMap(URL.init(string:)),
                username: username,
                password: password,
                streamProfile: streamProfile,
                htspPort: htspPort,
                guideCacheURL: guideCacheURL.flatMap(URL.init(string:)),
                xmltvURL: xmltvURL.flatMap(URL.init(string:)),
                resolvedAddresses: resolvedAddresses,
                guideResolvedAddresses: guideResolvedAddresses,
                cachedAddressesObservedAt: cachedAddressesObservedAt
            )
        }

        private enum CodingKeys: String, CodingKey {
            case version, serverProfileID, baseURL, username, password, streamProfile
            case htspPort, guideCacheURL, xmltvURL
            case resolvedAddresses, guideResolvedAddresses, cachedAddressesObservedAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            serverProfileID = try values.decodeIfPresent(String.self, forKey: .serverProfileID)
            baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL)
            username = try values.decode(String.self, forKey: .username)
            password = try values.decode(String.self, forKey: .password)
            streamProfile = try values.decode(String.self, forKey: .streamProfile)
            htspPort = try values.decode(Int.self, forKey: .htspPort)
            guideCacheURL = try values.decodeIfPresent(String.self, forKey: .guideCacheURL)
            xmltvURL = try values.decodeIfPresent(String.self, forKey: .xmltvURL)
            resolvedAddresses = try values.decodeIfPresent(
                [String].self,
                forKey: .resolvedAddresses
            ) ?? []
            guideResolvedAddresses = try values.decodeIfPresent(
                [String].self,
                forKey: .guideResolvedAddresses
            ) ?? []
            cachedAddressesObservedAt = try values.decodeIfPresent(
                Date.self,
                forKey: .cachedAddressesObservedAt
            )
        }
    }

    private let service = "de.beutner.TVPlayer.tvheadend"
    private let account = "shared-server-configuration-v1"

    func read() -> TVHeadendConfiguration? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return payload.configuration
    }

    func write(_ configuration: TVHeadendConfiguration) throws {
        let data = try JSONEncoder().encode(Payload(configuration: configuration))
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw error(for: addStatus) }
        } else if status != errSecSuccess {
            throw error(for: status)
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
#if os(tvOS)
        query[kSecUseUserIndependentKeychain as String] = true
#endif
        return query
    }

    private func error(for status: OSStatus) -> ConfigurationError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .keychain(message)
    }
}
