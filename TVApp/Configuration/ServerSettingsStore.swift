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
    typealias ServerInfoLoader = @MainActor (TVHeadendConfiguration) async throws -> TVHeadendServerInfo
    typealias TimeshiftProbe = @MainActor (TVHeadendConfiguration) async throws -> Void

    private struct StoredPayload: Codable {
        var version = 1
        var profiles: [TVHeadendServerProfile]
        var activeProfileID: String?
    }

    private enum LegacyKey {
        static let baseURL = "tvheadend.baseURL"
        static let username = "tvheadend.username"
        static let streamProfile = "tvheadend.streamProfile"
        static let htspPort = "tvheadend.htspPort"
        static let guideCacheURL = "tvheadend.guideCacheURL"
        static let xmltvURL = "tvheadend.xmltvURL"
    }

    static let storageKey = "tvheadend.serverProfiles.v1"
    static let environmentProfileID = "environment-server"
    static let transientEnvironmentProfileKey = "TVPLAYER_TRANSIENT_ENVIRONMENT_PROFILE"

    @Published private(set) var profiles: [TVHeadendServerProfile] = []
    @Published private(set) var activeProfileID: String?
    @Published private(set) var editingProfileID: String?
    @Published private(set) var isAddingServer = false
    @Published private(set) var onlineProfileIDs: Set<String> = []
    @Published private(set) var revision = 0
    @Published private(set) var connectionStatus: ServerConnectionStatus = .notTested
    @Published private(set) var timeshiftStatus: TVHeadendTimeshiftStatus = .notTested
    @Published private(set) var draftIsDirty = false

    @Published var displayNameText = "" { didSet { draftDidChange() } }
    @Published var baseURLText = "" { didSet { draftDidChange(connectionRelevant: true) } }
    @Published var username = "" { didSet { draftDidChange(connectionRelevant: true) } }
    @Published var password = "" { didSet { draftDidChange(connectionRelevant: true) } }
    @Published var streamProfile = "pass" { didSet { draftDidChange() } }
    @Published var htspPortText = "9982" { didSet { draftDidChange(connectionRelevant: true) } }
    @Published var guideCacheURLText = "" { didSet { draftDidChange() } }
    @Published var xmltvURLText = "" { didSet { draftDidChange() } }

    private let defaults: UserDefaults
    private let keychain: any PasswordStoring
    private let sharedConfiguration: SharedTVHeadendConfigurationStore?
    private let usesTransientEnvironmentProfile: Bool
    private let automaticallyTestsConnections: Bool
    private let serverInfoLoader: ServerInfoLoader
    private let timeshiftProbe: TimeshiftProbe
    private var passwords: [String: String] = [:]
    private var discovery: TVHeadendDiscovery?
    private var latestDiscoveryByProfileID: [String: DiscoveredTVHeadendService] = [:]
    private var profileIDByServiceIdentity: [String: String] = [:]
    private var activeProfileIDBeforeTransientEnvironment: String?
    private var isLoadingDraft = false
    private var connectionTestGeneration = 0

    init(
        defaults: UserDefaults = .standard,
        keychain: any PasswordStoring = KeychainPasswordStore(),
        sharedConfiguration: SharedTVHeadendConfigurationStore? = SharedTVHeadendConfigurationStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        startsDiscovery: Bool = true,
        automaticallyTestsConnections: Bool = true,
        serverInfoLoader: @escaping ServerInfoLoader = {
            try await TVHeadendClient(configuration: $0).serverInfo()
        },
        timeshiftProbe: @escaping TimeshiftProbe = {
            try await HTSPConnection.probe(configuration: $0)
        }
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.sharedConfiguration = sharedConfiguration
        usesTransientEnvironmentProfile =
            environment[Self.transientEnvironmentProfileKey] == "1"
        self.automaticallyTestsConnections = automaticallyTestsConnections
        self.serverInfoLoader = serverInfoLoader
        self.timeshiftProbe = timeshiftProbe

        if let data = defaults.data(forKey: Self.storageKey),
           let payload = try? JSONDecoder().decode(StoredPayload.self, from: data),
           payload.version == 1 {
            profiles = payload.profiles
            activeProfileID = payload.activeProfileID.flatMap { id in
                profiles.contains(where: { $0.id == id }) ? id : nil
            } ?? profiles.first?.id
            for profile in profiles {
                passwords[profile.id] = keychain.read(account: Self.passwordAccount(for: profile.id))
            }
        } else if let migrated = Self.legacyConfiguration(
            defaults: defaults,
            keychain: keychain,
            shared: sharedConfiguration?.read(),
            environment: [:]
        ), let baseURL = migrated.baseURL {
            let id = migrated.serverProfileID ?? UUID().uuidString
            let profile = TVHeadendServerProfile(
                id: id,
                name: Self.defaultName(for: baseURL),
                baseURL: baseURL,
                username: migrated.username,
                streamProfile: migrated.streamProfile,
                htspPort: migrated.htspPort,
                guideCacheURL: migrated.guideCacheURL,
                xmltvURL: migrated.xmltvURL,
                resolvedAddresses: migrated.resolvedAddresses,
                guideResolvedAddresses: migrated.guideResolvedAddresses,
                origin: .manual,
                isEdited: true,
                lastSeenAt: migrated.cachedAddressesObservedAt
            )
            profiles = [profile]
            activeProfileID = id
            passwords[id] = migrated.password
            try? keychain.write(migrated.password, account: Self.passwordAccount(for: id))
        }

        if usesTransientEnvironmentProfile {
            let removedActiveProfile = activeProfileID == Self.environmentProfileID
            profiles.removeAll { $0.id == Self.environmentProfileID }
            if removedActiveProfile {
                activeProfileID = profiles.first?.id
            }
            activeProfileIDBeforeTransientEnvironment = activeProfileID
        }
        applyEnvironmentProfile(environment)

        editingProfileID = activeProfileID
        if let activeProfileID {
            loadDraft(profileID: activeProfileID)
        } else {
            beginAddingServer()
        }
        persist()
        syncSharedConfiguration()

        if startsDiscovery {
            let discovery = TVHeadendDiscovery { [weak self] event in
                self?.handleDiscoveryEvent(event)
            }
            self.discovery = discovery
            discovery.start()
        }
    }

    var activeProfile: TVHeadendServerProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    var editingProfile: TVHeadendServerProfile? {
        guard let editingProfileID else { return nil }
        return profiles.first { $0.id == editingProfileID }
    }

    var configuration: TVHeadendConfiguration {
        guard let profile = activeProfile else { return Self.emptyConfiguration }
        return profile.configuration(password: passwords[profile.id] ?? "")
    }

    func isOnline(_ profile: TVHeadendServerProfile) -> Bool {
        onlineProfileIDs.contains(profile.id)
    }

    func selectServer(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        let changed = activeProfileID != id
        let previousConnectionStatus = connectionStatus
        let previousTimeshiftStatus = timeshiftStatus
        activeProfileID = id
        editingProfileID = id
        isAddingServer = false
        loadDraft(profileID: id)
        if !changed {
            connectionStatus = previousConnectionStatus
            timeshiftStatus = previousTimeshiftStatus
        }
        persist()
        if changed {
            revision &+= 1
            syncSharedConfiguration()
            scheduleConnectionTest()
        }
    }

    func beginAddingServer() {
        editingProfileID = nil
        isAddingServer = true
        loadDraft(profile: nil)
    }

    func cancelEditing() {
        guard let activeProfileID else {
            beginAddingServer()
            return
        }
        editingProfileID = activeProfileID
        isAddingServer = false
        loadDraft(profileID: activeProfileID)
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
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUsername.isEmpty != password.isEmpty {
            throw ConfigurationError.incompleteCredentials
        }
        return TVHeadendConfiguration(
            serverProfileID: editingProfileID,
            baseURL: baseURL,
            username: trimmedUsername,
            password: password,
            streamProfile: normalizedProfile,
            htspPort: htspPort,
            guideCacheURL: guideCacheURL,
            xmltvURL: xmltvURL
        )
    }

    func save() throws {
        let draft = try validatedDraft()
        guard let baseURL = draft.baseURL else { throw ConfigurationError.invalidServerURL }
        let id = editingProfileID ?? UUID().uuidString
        try keychain.write(draft.password, account: Self.passwordAccount(for: id))

        let existing = editingProfileID.flatMap { id in profiles.first { $0.id == id } }
        let name = displayNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = TVHeadendServerProfile(
            id: id,
            name: name.isEmpty ? Self.defaultName(for: baseURL) : name,
            baseURL: baseURL,
            username: draft.username,
            streamProfile: draft.streamProfile,
            htspPort: draft.htspPort,
            guideCacheURL: draft.guideCacheURL,
            xmltvURL: draft.xmltvURL,
            resolvedAddresses: Self.sameHost(existing?.baseURL, baseURL)
                ? existing?.resolvedAddresses ?? []
                : [],
            guideResolvedAddresses: Self.sameHost(existing?.guideCacheURL, draft.guideCacheURL)
                ? existing?.guideResolvedAddresses ?? []
                : [],
            origin: existing?.origin ?? .manual,
            isEdited: existing?.origin == .discovered,
            discoveryID: existing?.discoveryID,
            discoveryServiceIdentity: existing?.discoveryServiceIdentity,
            lastSeenAt: existing?.lastSeenAt
        )

        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        passwords[id] = draft.password
        activeProfileID = id
        editingProfileID = id
        isAddingServer = false
        loadDraft(profile: profile)
        persist()
        revision &+= 1
        syncSharedConfiguration()
    }

    func canForget(_ profile: TVHeadendServerProfile) -> Bool {
        profile.origin == .manual || !isOnline(profile)
    }

    func forget(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }), canForget(profile) else { return }
        keychain.delete(account: Self.passwordAccount(for: id))
        profiles.removeAll { $0.id == id }
        passwords[id] = nil
        onlineProfileIDs.remove(id)
        latestDiscoveryByProfileID[id] = nil
        profileIDByServiceIdentity = profileIDByServiceIdentity.filter { $0.value != id }

        let activeChanged = activeProfileID == id
        if activeChanged { activeProfileID = profiles.first?.id }
        if let activeProfileID {
            editingProfileID = activeProfileID
            isAddingServer = false
            loadDraft(profileID: activeProfileID)
        } else {
            beginAddingServer()
        }
        persist()
        if activeChanged {
            revision &+= 1
            syncSharedConfiguration()
            scheduleConnectionTest()
        }
    }

    func restoreAutomaticUpdates(_ id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].origin == .discovered
        else { return }
        profiles[index].isEdited = false
        if let service = latestDiscoveryByProfileID[id] {
            apply(service, toProfileAt: index)
        } else {
            persist()
        }
        if editingProfileID == id { loadDraft(profileID: id) }
    }

    func testConnection() async {
        connectionTestGeneration &+= 1
        let testGeneration = connectionTestGeneration
        let testedProfileID = editingProfileID
        var testedConfiguration: TVHeadendConfiguration?
        connectionStatus = .checking
        timeshiftStatus = .checking
        do {
            let configuration = try validatedDraft()
            testedConfiguration = configuration
            guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }
            let info = try await serverInfoLoader(configuration)
            guard isCurrentConnectionTest(
                testGeneration,
                profileID: testedProfileID,
                configuration: configuration
            ) else { return }
            let version = [info.name, info.version].compactMap { $0 }.joined(separator: " ")
            connectionStatus = .connected(version)
            guard info.capabilities.contains("timeshift") else {
                timeshiftStatus = .unavailable("Disabled on the TVHeadend server")
                return
            }
            do {
                try await timeshiftProbe(configuration)
                guard isCurrentConnectionTest(
                    testGeneration,
                    profileID: testedProfileID,
                    configuration: configuration
                ) else { return }
                timeshiftStatus = .ready
            } catch is CancellationError {
                guard isCurrentConnectionTest(
                    testGeneration,
                    profileID: testedProfileID,
                    configuration: configuration
                ) else { return }
                timeshiftStatus = .notTested
            } catch {
                guard isCurrentConnectionTest(
                    testGeneration,
                    profileID: testedProfileID,
                    configuration: configuration
                ) else { return }
                timeshiftStatus = .unavailable(error.localizedDescription)
            }
        } catch is CancellationError {
            guard isCurrentConnectionTest(
                testGeneration,
                profileID: testedProfileID,
                configuration: testedConfiguration
            ) else { return }
            connectionStatus = .notTested
            timeshiftStatus = .notTested
        } catch {
            guard isCurrentConnectionTest(
                testGeneration,
                profileID: testedProfileID,
                configuration: testedConfiguration
            ) else { return }
            connectionStatus = .failed(error.localizedDescription)
            timeshiftStatus = .unavailable("Server connection failed")
        }
    }

    func handleDiscoveryEvent(_ event: TVHeadendDiscoveryEvent) {
        switch event {
        case let .upsert(service):
            adopt(service)
        case let .removed(serviceIdentity):
            guard let profileID = profileIDByServiceIdentity.removeValue(forKey: serviceIdentity),
                  !profileIDByServiceIdentity.values.contains(profileID)
            else { return }
            onlineProfileIDs.remove(profileID)
        }
    }

    private func adopt(_ service: DiscoveredTVHeadendService) {
        let settings = service.settings
        let index = settings.discoveryID.flatMap { discoveryID in
            profiles.firstIndex { $0.discoveryID == discoveryID }
        } ?? profiles.firstIndex { $0.discoveryServiceIdentity == service.serviceIdentity }
            ?? profiles.firstIndex { Self.sameServer($0.baseURL, settings.baseURL) }

        if let index {
            let profileID = profiles[index].id
            let wasManual = profiles[index].origin == .manual
            let oldConfiguration = profiles[index].configuration(
                password: passwords[profileID] ?? ""
            )
            latestDiscoveryByProfileID[profileID] = service
            profileIDByServiceIdentity[service.serviceIdentity] = profileID
            onlineProfileIDs.insert(profileID)

            profiles[index].origin = .discovered
            if wasManual { profiles[index].isEdited = true }
            profiles[index].discoveryID = settings.discoveryID ?? profiles[index].discoveryID
            profiles[index].discoveryServiceIdentity = service.serviceIdentity
            profiles[index].lastSeenAt = Date()
            if profiles[index].isEdited {
                cacheResolvedAddresses(from: service.settings, toProfileAt: index)
                let activeChanged = activeProfileID == profileID
                    && oldConfiguration != profiles[index].configuration(
                        password: passwords[profileID] ?? ""
                    )
                persist()
                if activeChanged {
                    revision &+= 1
                    syncSharedConfiguration()
                    scheduleConnectionTest()
                }
                return
            }
            apply(service, toProfileAt: index)
            return
        }

        let profile = TVHeadendServerProfile(
            name: service.name,
            baseURL: settings.baseURL,
            username: settings.username,
            streamProfile: settings.streamProfile,
            htspPort: settings.htspPort,
            guideCacheURL: settings.guideCacheURL,
            xmltvURL: settings.xmltvURL,
            resolvedAddresses: settings.resolvedAddresses,
            guideResolvedAddresses: settings.guideResolvedAddresses,
            origin: .discovered,
            isEdited: false,
            discoveryID: settings.discoveryID,
            discoveryServiceIdentity: service.serviceIdentity,
            lastSeenAt: Date()
        )
        do {
            try keychain.write(settings.password, account: Self.passwordAccount(for: profile.id))
        } catch {
            connectionStatus = .failed(error.localizedDescription)
            return
        }
        profiles.append(profile)
        passwords[profile.id] = settings.password
        latestDiscoveryByProfileID[profile.id] = service
        profileIDByServiceIdentity[service.serviceIdentity] = profile.id
        onlineProfileIDs.insert(profile.id)

        let becomesActive = activeProfileID == nil
        if becomesActive {
            activeProfileID = profile.id
            editingProfileID = profile.id
            isAddingServer = false
            loadDraft(profile: profile)
            revision &+= 1
            syncSharedConfiguration()
            scheduleConnectionTest()
        }
        persist()
    }

    private func apply(_ service: DiscoveredTVHeadendService, toProfileAt index: Int) {
        let oldConfiguration = profiles[index].configuration(password: passwords[profiles[index].id] ?? "")
        let oldBaseURL = profiles[index].baseURL
        let profileID = profiles[index].id
        do {
            try keychain.write(service.settings.password, account: Self.passwordAccount(for: profileID))
        } catch {
            if activeProfileID == profileID { connectionStatus = .failed(error.localizedDescription) }
            persist()
            return
        }

        profiles[index].name = service.name
        profiles[index].baseURL = service.settings.baseURL
        profiles[index].username = service.settings.username
        profiles[index].streamProfile = service.settings.streamProfile
        profiles[index].htspPort = service.settings.htspPort
        if let guideCacheURL = service.settings.guideCacheURL {
            let oldGuideCacheURL = profiles[index].guideCacheURL
            profiles[index].guideCacheURL = guideCacheURL
            if !Self.sameHost(oldGuideCacheURL, guideCacheURL)
                || !service.settings.guideResolvedAddresses.isEmpty {
                profiles[index].guideResolvedAddresses = service.settings.guideResolvedAddresses
            }
        }
        profiles[index].xmltvURL = service.settings.xmltvURL
        if !Self.sameHost(oldBaseURL, service.settings.baseURL)
            || !service.settings.resolvedAddresses.isEmpty {
            profiles[index].resolvedAddresses = service.settings.resolvedAddresses
        }
        profiles[index].origin = .discovered
        profiles[index].isEdited = false
        profiles[index].discoveryID = service.settings.discoveryID ?? profiles[index].discoveryID
        profiles[index].discoveryServiceIdentity = service.serviceIdentity
        profiles[index].lastSeenAt = Date()
        passwords[profileID] = service.settings.password

        let newConfiguration = profiles[index].configuration(password: service.settings.password)
        let activeChanged = activeProfileID == profileID && oldConfiguration != newConfiguration
        if editingProfileID == profileID, !draftIsDirty { loadDraft(profile: profiles[index]) }
        persist()
        if activeChanged {
            revision &+= 1
            syncSharedConfiguration()
            scheduleConnectionTest()
        }
    }

    private func loadDraft(profileID: String) {
        loadDraft(profile: profiles.first { $0.id == profileID })
    }

    private func cacheResolvedAddresses(
        from settings: DiscoveredTVHeadendSettings,
        toProfileAt index: Int
    ) {
        if Self.sameHost(profiles[index].baseURL, settings.baseURL),
           !settings.resolvedAddresses.isEmpty {
            profiles[index].resolvedAddresses = settings.resolvedAddresses
        }
        if let guideCacheURL = settings.guideCacheURL,
           Self.sameHost(profiles[index].guideCacheURL, guideCacheURL),
           !settings.guideResolvedAddresses.isEmpty {
            profiles[index].guideResolvedAddresses = settings.guideResolvedAddresses
        }
    }

    private func loadDraft(profile: TVHeadendServerProfile?) {
        isLoadingDraft = true
        displayNameText = profile?.name ?? ""
        baseURLText = profile?.baseURL.absoluteString ?? ""
        username = profile?.username ?? ""
        password = profile.flatMap { passwords[$0.id] } ?? ""
        streamProfile = profile?.streamProfile ?? "pass"
        htspPortText = String(profile?.htspPort ?? 9982)
        guideCacheURLText = profile?.guideCacheURL?.absoluteString ?? ""
        xmltvURLText = profile?.xmltvURL?.absoluteString ?? ""
        isLoadingDraft = false
        draftIsDirty = false
        invalidateConnectionStatus()
    }

    private func draftDidChange(connectionRelevant: Bool = false) {
        guard !isLoadingDraft else { return }
        draftIsDirty = true
        if connectionRelevant { invalidateConnectionStatus() }
    }

    private func invalidateConnectionStatus() {
        connectionTestGeneration &+= 1
        connectionStatus = .notTested
        timeshiftStatus = .notTested
    }

    private func isCurrentConnectionTest(
        _ generation: Int,
        profileID: String?,
        configuration: TVHeadendConfiguration?
    ) -> Bool {
        guard generation == connectionTestGeneration,
              editingProfileID == profileID
        else { return false }
        guard let configuration else { return true }
        return (try? validatedDraft()) == configuration
    }

    private func scheduleConnectionTest() {
        guard automaticallyTestsConnections else { return }
        Task { await testConnection() }
    }

    private func persist() {
        let persistedProfiles = usesTransientEnvironmentProfile
            ? profiles.filter { $0.id != Self.environmentProfileID }
            : profiles
        let persistedActiveProfileID =
            usesTransientEnvironmentProfile && activeProfileID == Self.environmentProfileID
            ? activeProfileIDBeforeTransientEnvironment
            : activeProfileID
        let payload = StoredPayload(
            profiles: persistedProfiles,
            activeProfileID: persistedActiveProfileID
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func syncSharedConfiguration() {
#if os(tvOS)
        guard !usesTransientEnvironmentProfile else { return }
        guard configuration.baseURL != nil else { return }
        try? sharedConfiguration?.write(configuration)
#endif
    }

    private func applyEnvironmentProfile(_ environment: [String: String]) {
        guard let rawURL = environment["TVPLAYER_TVH_URL"],
              let baseURL = Self.httpURL(from: rawURL)
        else { return }
        let existingIndex = profiles.firstIndex { $0.id == Self.environmentProfileID }
        let existing = existingIndex.map { profiles[$0] }
        let guideCacheURL = environment["TVPLAYER_GUIDE_URL"]
            .flatMap { Self.optionalHTTPURL(from: $0) }
            ?? existing?.guideCacheURL
        let xmltvURL = environment["TVPLAYER_XMLTV_URL"]
            .flatMap { Self.optionalHTTPURL(from: $0) }
            ?? existing?.xmltvURL
        let profile = TVHeadendServerProfile(
            id: Self.environmentProfileID,
            name: existing?.name ?? "Environment · \(Self.defaultName(for: baseURL))",
            baseURL: baseURL,
            username: environment["TVPLAYER_TVH_USERNAME"] ?? existing?.username ?? "",
            streamProfile: environment["TVPLAYER_TVH_PROFILE"] ?? existing?.streamProfile ?? "pass",
            htspPort: Int(environment["TVPLAYER_TVH_HTSP_PORT"] ?? "") ?? existing?.htspPort ?? 9982,
            guideCacheURL: guideCacheURL,
            xmltvURL: xmltvURL,
            resolvedAddresses: Self.sameHost(existing?.baseURL, baseURL)
                ? existing?.resolvedAddresses ?? []
                : [],
            guideResolvedAddresses: Self.sameHost(existing?.guideCacheURL, guideCacheURL)
                ? existing?.guideResolvedAddresses ?? []
                : [],
            origin: .manual,
            isEdited: true,
            lastSeenAt: existing?.lastSeenAt
        )
        let environmentPassword = environment["TVPLAYER_TVH_PASSWORD"]
            ?? existing.flatMap { passwords[$0.id] }
            ?? ""
        try? keychain.write(environmentPassword, account: Self.passwordAccount(for: profile.id))
        passwords[profile.id] = environmentPassword
        if let existingIndex {
            profiles[existingIndex] = profile
        } else {
            profiles.append(profile)
        }
        activeProfileID = profile.id
    }

    private static func legacyConfiguration(
        defaults: UserDefaults,
        keychain: any PasswordStoring,
        shared: TVHeadendConfiguration?,
        environment: [String: String]
    ) -> TVHeadendConfiguration? {
        let urlText = environment["TVPLAYER_TVH_URL"]
            ?? shared?.baseURL?.absoluteString
            ?? defaults.string(forKey: LegacyKey.baseURL)
            ?? ""
        guard let baseURL = httpURL(from: urlText) else { return nil }
        let guideCacheURL = optionalHTTPURL(from:
            environment["TVPLAYER_GUIDE_URL"]
                ?? shared?.guideCacheURL?.absoluteString
                ?? defaults.string(forKey: LegacyKey.guideCacheURL)
                ?? ""
        )
        let xmltvURL = optionalHTTPURL(from:
            environment["TVPLAYER_XMLTV_URL"]
                ?? shared?.xmltvURL?.absoluteString
                ?? defaults.string(forKey: LegacyKey.xmltvURL)
                ?? ""
        )
        return TVHeadendConfiguration(
            serverProfileID: shared?.serverProfileID,
            baseURL: baseURL,
            username: environment["TVPLAYER_TVH_USERNAME"]
                ?? shared?.username
                ?? defaults.string(forKey: LegacyKey.username)
                ?? "",
            password: environment["TVPLAYER_TVH_PASSWORD"]
                ?? shared?.password
                ?? keychain.read(account: KeychainPasswordStore.legacyAccount),
            streamProfile: environment["TVPLAYER_TVH_PROFILE"]
                ?? shared?.streamProfile
                ?? defaults.string(forKey: LegacyKey.streamProfile)
                ?? "pass",
            htspPort: Int(
                environment["TVPLAYER_TVH_HTSP_PORT"]
                    ?? shared.map { String($0.htspPort) }
                    ?? defaults.string(forKey: LegacyKey.htspPort)
                    ?? "9982"
            ) ?? 9982,
            guideCacheURL: guideCacheURL,
            xmltvURL: xmltvURL,
            resolvedAddresses: Self.sameHost(shared?.baseURL, baseURL)
                ? shared?.resolvedAddresses ?? []
                : [],
            guideResolvedAddresses: Self.sameHost(shared?.guideCacheURL, guideCacheURL)
                ? shared?.guideResolvedAddresses ?? []
                : [],
            cachedAddressesObservedAt: shared?.cachedAddressesObservedAt
        )
    }

    private var normalizedProfile: String {
        streamProfile.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "pass"
    }

    private var normalizedHTSPPort: Int? {
        guard let port = Int(htspPortText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port)
        else { return nil }
        return port
    }

    private static var emptyConfiguration: TVHeadendConfiguration {
        TVHeadendConfiguration(
            baseURL: nil,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
    }

    private static func passwordAccount(for profileID: String) -> String {
        "server-profile:\(profileID)"
    }

    private static func defaultName(for url: URL) -> String {
        url.host ?? "TVHeadend"
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
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url.absoluteString
            }
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            if (components.scheme == "http" && components.port == 80)
                || (components.scheme == "https" && components.port == 443) {
                components.port = nil
            }
            while components.percentEncodedPath.count > 1,
                  components.percentEncodedPath.hasSuffix("/") {
                components.percentEncodedPath.removeLast()
            }
            if components.percentEncodedPath == "/" { components.percentEncodedPath = "" }
            return components.string ?? url.absoluteString
        }
        return normalized(lhs) == normalized(rhs)
    }

    private static func sameHost(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.host?.caseInsensitiveCompare(rhs.host ?? "") == .orderedSame
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
