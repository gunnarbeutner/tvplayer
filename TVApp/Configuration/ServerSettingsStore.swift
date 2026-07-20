import Foundation

enum ServerConnectionStatus: Equatable {
    case notTested
    case checking
    case connected(String)
    case failed(String)
}

enum TVHeadendTimeshiftStatus: Equatable {
    case notTested
    case checking
    case ready
    case unavailable(String)
}

@MainActor
final class ServerSettingsStore: ObservableObject {
    private enum Key {
        static let baseURL = "tvheadend.baseURL"
        static let username = "tvheadend.username"
        static let streamProfile = "tvheadend.streamProfile"
        static let htspPort = "tvheadend.htspPort"
        static let guideCacheURL = "tvheadend.guideCacheURL"
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
    @Published var htspPortText: String {
        didSet { invalidateConnectionStatus() }
    }
    @Published var guideCacheURLText: String
    @Published var xmltvURLText: String
    @Published private(set) var revision = 0
    @Published private(set) var connectionStatus: ServerConnectionStatus = .notTested
    @Published private(set) var timeshiftStatus: TVHeadendTimeshiftStatus = .notTested

    private let defaults: UserDefaults
    private let keychain: KeychainPasswordStore
    private var discovery: TVHeadendDiscovery?

    init(defaults: UserDefaults = .standard, keychain: KeychainPasswordStore = KeychainPasswordStore()) {
        self.defaults = defaults
        self.keychain = keychain

        let environment = ProcessInfo.processInfo.environment
        baseURLText = environment["TVPLAYER_TVH_URL"] ?? defaults.string(forKey: Key.baseURL) ?? ""
        username = environment["TVPLAYER_TVH_USERNAME"] ?? defaults.string(forKey: Key.username) ?? ""
        password = environment["TVPLAYER_TVH_PASSWORD"] ?? keychain.read()
        streamProfile = environment["TVPLAYER_TVH_PROFILE"] ?? defaults.string(forKey: Key.streamProfile) ?? "pass"
        htspPortText = environment["TVPLAYER_TVH_HTSP_PORT"]
            ?? defaults.string(forKey: Key.htspPort)
            ?? "9982"
        guideCacheURLText = environment["TVPLAYER_GUIDE_URL"] ?? defaults.string(forKey: Key.guideCacheURL) ?? ""
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
        if environment["TVPLAYER_TVH_HTSP_PORT"] != nil {
            defaults.set(htspPortText, forKey: Key.htspPort)
        }
        if environment["TVPLAYER_GUIDE_URL"] != nil {
            defaults.set(guideCacheURLText, forKey: Key.guideCacheURL)
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

        let persistedURL = defaults.string(forKey: Key.baseURL) ?? ""
        let hasGuidePreference = environment["TVPLAYER_GUIDE_URL"] != nil
            || defaults.object(forKey: Key.guideCacheURL) != nil
        if persistedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !hasGuidePreference {
            let discovery = TVHeadendDiscovery { [weak self] discovered in
                self?.adopt(discovered)
            }
            self.discovery = discovery
            discovery.start()
        }
    }

    var configuration: TVHeadendConfiguration {
        TVHeadendConfiguration(
            baseURL: Self.httpURL(from: baseURLText),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            streamProfile: normalizedProfile,
            htspPort: normalizedHTSPPort ?? 9982,
            guideCacheURL: Self.optionalHTTPURL(from: guideCacheURLText),
            xmltvURL: Self.optionalHTTPURL(from: xmltvURLText)
        )
    }

    func validatedDraft() throws -> TVHeadendConfiguration {
        guard let baseURL = Self.httpURL(from: baseURLText) else {
            throw ConfigurationError.invalidServerURL
        }

        let trimmedGuideCache = guideCacheURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let guideCacheURL = Self.optionalHTTPURL(from: trimmedGuideCache)
        if !trimmedGuideCache.isEmpty, guideCacheURL == nil {
            throw ConfigurationError.invalidGuideCacheURL
        }

        let trimmedXMLTV = xmltvURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let xmltvURL = Self.optionalHTTPURL(from: trimmedXMLTV)
        if !trimmedXMLTV.isEmpty, xmltvURL == nil {
            throw ConfigurationError.invalidXMLTVURL
        }
        guard let htspPort = normalizedHTSPPort else {
            throw ConfigurationError.invalidHTSPPort
        }

        return TVHeadendConfiguration(
            baseURL: baseURL,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            streamProfile: normalizedProfile,
            htspPort: htspPort,
            guideCacheURL: guideCacheURL,
            xmltvURL: xmltvURL
        )
    }

    func save() throws {
        let configuration = try validatedDraft()
        defaults.set(configuration.baseURL?.absoluteString, forKey: Key.baseURL)
        defaults.set(configuration.username, forKey: Key.username)
        defaults.set(configuration.streamProfile, forKey: Key.streamProfile)
        defaults.set(String(configuration.htspPort), forKey: Key.htspPort)
        defaults.set(configuration.guideCacheURL?.absoluteString ?? "", forKey: Key.guideCacheURL)

        if let xmltvURL = configuration.xmltvURL {
            defaults.set(xmltvURL.absoluteString, forKey: Key.xmltvURL)
        } else {
            defaults.removeObject(forKey: Key.xmltvURL)
        }

        try keychain.write(configuration.password)
        streamProfile = configuration.streamProfile
        htspPortText = String(configuration.htspPort)
        revision += 1
    }

    func testConnection() async {
        connectionStatus = .checking
        timeshiftStatus = .checking
        do {
            let configuration = try validatedDraft()
            guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }
            let info = try await TVHeadendClient(configuration: configuration).serverInfo()
            let version = [info.name, info.version].compactMap { $0 }.joined(separator: " ")
            connectionStatus = .connected(version)
            guard info.capabilities.contains("timeshift") else {
                timeshiftStatus = .unavailable("Disabled on the TVHeadend server")
                return
            }
            do {
                try await HTSPConnection.probe(configuration: configuration)
                timeshiftStatus = .ready
            } catch is CancellationError {
                timeshiftStatus = .notTested
            } catch {
                timeshiftStatus = .unavailable(error.localizedDescription)
            }
        } catch is CancellationError {
            connectionStatus = .notTested
            timeshiftStatus = .notTested
        } catch {
            connectionStatus = .failed(error.localizedDescription)
            timeshiftStatus = .unavailable("Server connection failed")
        }
    }

    private func invalidateConnectionStatus() {
        connectionStatus = .notTested
        timeshiftStatus = .notTested
    }

    private func adopt(_ discovered: DiscoveredTVHeadendSettings) {
        if let configuredURL = Self.httpURL(from: baseURLText) {
            guard Self.sameServer(configuredURL, discovered.baseURL) else { return }

            var changed = false
            if guideCacheURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let guideCacheURL = discovered.guideCacheURL {
                guideCacheURLText = guideCacheURL.absoluteString
                defaults.set(guideCacheURLText, forKey: Key.guideCacheURL)
                changed = true
            }
            if xmltvURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let xmltvURL = discovered.xmltvURL {
                xmltvURLText = xmltvURL.absoluteString
                defaults.set(xmltvURLText, forKey: Key.xmltvURL)
                changed = true
            }
            if htspPortText == "9982", discovered.htspPort != 9982 {
                htspPortText = String(discovered.htspPort)
                defaults.set(htspPortText, forKey: Key.htspPort)
                changed = true
            }

            discovery?.stop()
            discovery = nil
            if changed { revision += 1 }
            return
        }

        do {
            // Write the secret first: an mDNS bootstrap must never fall back to
            // persisting its password in UserDefaults.
            try keychain.write(discovered.password)

            baseURLText = discovered.baseURL.absoluteString
            username = discovered.username
            password = discovered.password
            streamProfile = discovered.streamProfile
            htspPortText = String(discovered.htspPort)
            guideCacheURLText = discovered.guideCacheURL?.absoluteString ?? ""
            xmltvURLText = discovered.xmltvURL?.absoluteString ?? ""

            defaults.set(baseURLText, forKey: Key.baseURL)
            defaults.set(username, forKey: Key.username)
            defaults.set(streamProfile, forKey: Key.streamProfile)
            defaults.set(htspPortText, forKey: Key.htspPort)
            defaults.set(guideCacheURLText, forKey: Key.guideCacheURL)
            if xmltvURLText.isEmpty {
                defaults.removeObject(forKey: Key.xmltvURL)
            } else {
                defaults.set(xmltvURLText, forKey: Key.xmltvURL)
            }

            discovery?.stop()
            discovery = nil
            revision += 1
            Task { await testConnection() }
        } catch {
            discovery?.stop()
            discovery = nil
            connectionStatus = .failed(error.localizedDescription)
        }
    }

    private var normalizedProfile: String {
        let value = streamProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "pass" : value
    }

    private var normalizedHTSPPort: Int? {
        guard let port = Int(htspPortText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port)
        else { return nil }
        return port
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

    private static func sameServer(_ lhs: URL, _ rhs: URL) -> Bool {
        func normalized(_ url: URL) -> String {
            url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return normalized(lhs) == normalized(rhs)
    }
}
