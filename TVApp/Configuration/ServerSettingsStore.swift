import Foundation

enum ServerConnectionStatus: Equatable {
    case notTested
    case checking
    case connected(String)
    case failed(String)
}

@MainActor
final class ServerSettingsStore: ObservableObject {
    private enum Key {
        static let baseURL = "tvheadend.baseURL"
        static let username = "tvheadend.username"
        static let streamProfile = "tvheadend.streamProfile"
        static let xmltvURL = "tvheadend.xmltvURL"
    }

    @Published var baseURLText: String {
        didSet { invalidateConnectionStatus() }
    }
    @Published var username: String {
        didSet { invalidateConnectionStatus() }
    }
    @Published var password: String {
        didSet { invalidateConnectionStatus() }
    }
    @Published var streamProfile: String
    @Published var xmltvURLText: String
    @Published private(set) var revision = 0
    @Published private(set) var connectionStatus: ServerConnectionStatus = .notTested

    private let defaults: UserDefaults
    private let keychain: KeychainPasswordStore

    init(defaults: UserDefaults = .standard, keychain: KeychainPasswordStore = KeychainPasswordStore()) {
        self.defaults = defaults
        self.keychain = keychain

        let environment = ProcessInfo.processInfo.environment
        baseURLText = environment["TVPLAYER_TVH_URL"] ?? defaults.string(forKey: Key.baseURL) ?? ""
        username = environment["TVPLAYER_TVH_USERNAME"] ?? defaults.string(forKey: Key.username) ?? ""
        password = environment["TVPLAYER_TVH_PASSWORD"] ?? keychain.read()
        streamProfile = environment["TVPLAYER_TVH_PROFILE"] ?? defaults.string(forKey: Key.streamProfile) ?? "pass"
        xmltvURLText = environment["TVPLAYER_XMLTV_URL"] ?? defaults.string(forKey: Key.xmltvURL) ?? ""

        // Device deployments can provide configuration at launch without putting
        // credentials in the project. Persist that bootstrap just as Settings does,
        // keeping the password in the device Keychain for later launches.
        if environment["TVPLAYER_TVH_URL"] != nil {
            defaults.set(baseURLText, forKey: Key.baseURL)
        }
        if environment["TVPLAYER_TVH_USERNAME"] != nil {
            defaults.set(username, forKey: Key.username)
        }
        if environment["TVPLAYER_TVH_PROFILE"] != nil {
            defaults.set(streamProfile, forKey: Key.streamProfile)
        }
        if environment["TVPLAYER_XMLTV_URL"] != nil {
            if xmltvURLText.isEmpty {
                defaults.removeObject(forKey: Key.xmltvURL)
            } else {
                defaults.set(xmltvURLText, forKey: Key.xmltvURL)
            }
        }
        if let environmentPassword = environment["TVPLAYER_TVH_PASSWORD"] {
            try? keychain.write(environmentPassword)
        }
    }

    var configuration: TVHeadendConfiguration {
        TVHeadendConfiguration(
            baseURL: Self.httpURL(from: baseURLText),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            streamProfile: normalizedProfile,
            xmltvURL: Self.optionalHTTPURL(from: xmltvURLText)
        )
    }

    func validatedDraft() throws -> TVHeadendConfiguration {
        guard let baseURL = Self.httpURL(from: baseURLText) else {
            throw ConfigurationError.invalidServerURL
        }

        let trimmedXMLTV = xmltvURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let xmltvURL = Self.optionalHTTPURL(from: trimmedXMLTV)
        if !trimmedXMLTV.isEmpty, xmltvURL == nil {
            throw ConfigurationError.invalidXMLTVURL
        }

        return TVHeadendConfiguration(
            baseURL: baseURL,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            streamProfile: normalizedProfile,
            xmltvURL: xmltvURL
        )
    }

    func save() throws {
        let configuration = try validatedDraft()
        defaults.set(configuration.baseURL?.absoluteString, forKey: Key.baseURL)
        defaults.set(configuration.username, forKey: Key.username)
        defaults.set(configuration.streamProfile, forKey: Key.streamProfile)

        if let xmltvURL = configuration.xmltvURL {
            defaults.set(xmltvURL.absoluteString, forKey: Key.xmltvURL)
        } else {
            defaults.removeObject(forKey: Key.xmltvURL)
        }

        try keychain.write(configuration.password)
        streamProfile = configuration.streamProfile
        revision += 1
    }

    func testConnection() async {
        connectionStatus = .checking
        do {
            let configuration = try validatedDraft()
            guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }
            let version = try await TVHeadendClient(configuration: configuration).serverVersion()
            connectionStatus = .connected(version)
        } catch is CancellationError {
            connectionStatus = .notTested
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }

    private func invalidateConnectionStatus() {
        guard connectionStatus != .notTested else { return }
        connectionStatus = .notTested
    }

    private var normalizedProfile: String {
        let value = streamProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "pass" : value
    }

    private static func optionalHTTPURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return httpURL(from: trimmed)
    }

    private static func httpURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}
