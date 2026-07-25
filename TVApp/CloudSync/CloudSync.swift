import CloudKit
import CryptoKit
import Foundation
import OSLog

enum CloudSyncRecordKind: String, Codable, CaseIterable, Sendable {
    case serverProfile = "ServerProfile"
    case channelPreference = "ChannelPreference"
    case appPreference = "AppPreference"
    case guideSlice = "GuideSlice"
    case commercialProfile = "CommercialProfile"
}

struct CloudSyncEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let kind: CloudSyncRecordKind
    let key: String
    let payload: Data
    let modifiedAt: Date
    let deletedAt: Date?

    init(
        kind: CloudSyncRecordKind,
        key: String,
        payload: Data,
        modifiedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        version = Self.currentVersion
        self.kind = kind
        self.key = key
        self.payload = payload
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }

    var recordName: String {
        "\(kind.rawValue)-\(CloudSyncIdentity.digest(key))"
    }
}

enum CloudSyncIdentity {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func normalizedServer(url: URL, username: String) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        if components?.path == "/" {
            components?.path = ""
        } else {
            while components?.path.hasSuffix("/") == true {
                components?.path.removeLast()
            }
        }
        let endpoint = components?.url?.absoluteString
            ?? url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return "server-\(digest("\(endpoint)|\(account)"))"
    }
}

enum CloudSyncAvailability: Equatable, Sendable {
    case disabled
    case checking
    case available
    case unavailable(String)
    case syncing
    case failed(String)

    var title: String {
        switch self {
        case .disabled: "Off"
        case .checking: "Checking iCloud…"
        case .available: "Up to Date"
        case .unavailable: "Unavailable"
        case .syncing: "Syncing…"
        case .failed: "Sync Error"
        }
    }

    var detail: String? {
        switch self {
        case let .unavailable(message), let .failed(message): message
        case .disabled, .checking, .available, .syncing: nil
        }
    }
}

enum CloudSyncError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "iCloud is unavailable. Sign in and synchronize before deleting cloud data."
    }
}

actor CloudSyncEngineStore: CKSyncEngineDelegate {
    static let shared = CloudSyncEngineStore()
    static let zoneName = "TVPlayerSync"

    private struct PersistedMirror: Codable {
        var version = 1
        var records: [String: CloudSyncEnvelope] = [:]
    }

    private let logger = Logger(subsystem: "de.beutner.TVPlayer", category: "CloudSync")
    private let container: CKContainer
    private let mirrorURL: URL
    private let stateURL: URL
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private var mirror: PersistedMirror
    private var engine: CKSyncEngine?
    private var changeHandler: (@Sendable ([CloudSyncEnvelope]) async -> Void)?
    private var statusHandler: (@Sendable (CloudSyncAvailability) async -> Void)?

    init(
        container: CKContainer = CKContainer(identifier: "iCloud.de.beutner.TVPlayer"),
        directoryURL: URL? = nil
    ) {
        self.container = container
        let directory = directoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appending(path: "TVPlayer/CloudSync", directoryHint: .isDirectory)
        mirrorURL = directory.appending(path: "mirror-v1.json")
        stateURL = directory.appending(path: "engine-state-v1.json")
        if let data = try? Data(contentsOf: mirrorURL),
           let decoded = try? JSONDecoder().decode(PersistedMirror.self, from: data),
           decoded.version == 1 {
            mirror = decoded
        } else {
            mirror = PersistedMirror()
        }
    }

    func setHandlers(
        changes: @escaping @Sendable ([CloudSyncEnvelope]) async -> Void,
        status: @escaping @Sendable (CloudSyncAvailability) async -> Void
    ) {
        changeHandler = changes
        statusHandler = status
    }

    func start(enabled: Bool) async {
        guard enabled else {
            await stop()
            await statusHandler?(.disabled)
            return
        }
        guard engine == nil else { return }
        await statusHandler?(.checking)
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                await statusHandler?(.unavailable(Self.message(for: accountStatus)))
                return
            }
            let state: CKSyncEngine.State.Serialization?
            if let data = try? Data(contentsOf: stateURL) {
                state = try? JSONDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: data
                )
            } else {
                state = nil
            }
            var configuration = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: state,
                delegate: self
            )
            configuration.automaticallySync = true
            configuration.subscriptionID = "tvplayer-sync-private"
            let engine = CKSyncEngine(configuration)
            self.engine = engine
            if engine.state.pendingDatabaseChanges.isEmpty {
                engine.state.add(pendingDatabaseChanges: [
                    CKSyncEngine.PendingDatabaseChange.saveZone(
                        CKRecordZone(zoneID: zoneID)
                    )
                ])
            }
            await statusHandler?(.available)
            if !mirror.records.isEmpty {
                await changeHandler?(Array(mirror.records.values))
            }
            Task { try? await self.fetchAndSend() }
        } catch {
            await statusHandler?(.failed(error.localizedDescription))
        }
    }

    func prepareForBackgroundSync(enabled: Bool) async throws {
        await start(enabled: enabled)
        guard !enabled || engine != nil else { throw CloudSyncError.unavailable }
    }

    func stop() async {
        if let engine {
            await engine.cancelOperations()
        }
        engine = nil
    }

    func fetchAndSend() async throws {
        guard let engine else { return }
        await statusHandler?(.syncing)
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            await statusHandler?(.available)
        } catch {
            await statusHandler?(.failed(error.localizedDescription))
            throw error
        }
    }

    func upsert(_ envelope: CloudSyncEnvelope) async {
        let name = envelope.recordName
        if let existing = mirror.records[name],
           existing.kind == envelope.kind,
           existing.key == envelope.key,
           existing.payload == envelope.payload,
           existing.deletedAt == envelope.deletedAt {
            return
        }
        if let existing = mirror.records[name],
           existing.modifiedAt > envelope.modifiedAt {
            return
        }
        mirror.records[name] = envelope
        persistMirror()
        guard let engine else { return }
        let id = CKRecord.ID(recordName: name, zoneID: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
    }

    func records(kind: CloudSyncRecordKind) -> [CloudSyncEnvelope] {
        mirror.records.values.filter { $0.kind == kind }
    }

    func deleteCloudData() async throws {
        guard let engine else { throw CloudSyncError.unavailable }
        engine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
        try await engine.sendChanges()
        mirror.records.removeAll()
        persistMirror()
        try? FileManager.default.removeItem(at: stateURL)
        await stop()
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            persistState(update.stateSerialization)
        case let .accountChange(change):
            logger.info("CloudKit account changed: \(change.description, privacy: .public)")
            mirror.records.removeAll()
            persistMirror()
            try? FileManager.default.removeItem(at: stateURL)
        case let .fetchedRecordZoneChanges(changes):
            var changed: [CloudSyncEnvelope] = []
            for modification in changes.modifications {
                guard modification.record.recordID.zoneID == zoneID,
                      let envelope = Self.envelope(from: modification.record)
                else { continue }
                let name = modification.record.recordID.recordName
                if mirror.records[name].map({ $0.modifiedAt > envelope.modifiedAt }) == true {
                    continue
                }
                mirror.records[name] = envelope
                changed.append(envelope)
            }
            for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
                mirror.records[deletion.recordID.recordName] = nil
            }
            persistMirror()
            if !changed.isEmpty {
                await changeHandler?(changed)
            }
        case let .sentRecordZoneChanges(result):
            for failure in result.failedRecordSaves {
                logger.error(
                    "CloudKit record save failed: \(failure.error.localizedDescription, privacy: .public)"
                )
                syncEngine.state.add(pendingRecordZoneChanges: [
                    .saveRecord(failure.record.recordID)
                ])
            }
            for (id, error) in result.failedRecordDeletes {
                logger.error(
                    "CloudKit record delete failed: \(error.localizedDescription, privacy: .public)"
                )
                syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(id)])
            }
        case let .sentDatabaseChanges(result):
            for failure in result.failedZoneSaves {
                logger.error(
                    "CloudKit zone save failed: \(failure.error.localizedDescription, privacy: .public)"
                )
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(failure.zone)])
            }
        case .didFetchChanges:
            await statusHandler?(.available)
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .willSendChanges, .didSendChanges, .fetchedDatabaseChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pending
        ) { [mirror, zoneID] recordID in
            guard recordID.zoneID == zoneID,
                  let envelope = mirror.records[recordID.recordName]
            else { return nil }
            return Self.record(from: envelope, zoneID: zoneID)
        }
    }

    private func persistMirror() {
        do {
            try FileManager.default.createDirectory(
                at: mirrorURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(mirror).write(to: mirrorURL, options: .atomic)
        } catch {
            logger.error("Could not persist CloudKit mirror: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistState(_ state: CKSyncEngine.State.Serialization) {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            logger.error("Could not persist CloudKit state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func record(
        from envelope: CloudSyncEnvelope,
        zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let record = CKRecord(
            recordType: envelope.kind.rawValue,
            recordID: CKRecord.ID(recordName: envelope.recordName, zoneID: zoneID)
        )
        record["version"] = envelope.version as CKRecordValue
        record["key"] = envelope.key as CKRecordValue
        record["payload"] = envelope.payload as CKRecordValue
        record["modifiedAt"] = envelope.modifiedAt as CKRecordValue
        record["deletedAt"] = envelope.deletedAt as CKRecordValue?
        return record
    }

    private static func envelope(from record: CKRecord) -> CloudSyncEnvelope? {
        guard let kind = CloudSyncRecordKind(rawValue: record.recordType),
              let key = record["key"] as? String,
              let payload = record["payload"] as? Data,
              let modifiedAt = record["modifiedAt"] as? Date
        else { return nil }
        return CloudSyncEnvelope(
            kind: kind,
            key: key,
            payload: payload,
            modifiedAt: modifiedAt,
            deletedAt: record["deletedAt"] as? Date
        )
    }

    private static func message(for status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: "Sign in to iCloud to synchronize TV Player."
        case .restricted: "This iCloud account cannot use CloudKit."
        case .couldNotDetermine: "TV Player could not determine the iCloud account status."
        case .temporarilyUnavailable: "iCloud is temporarily unavailable."
        case .available: ""
        @unknown default: "iCloud is unavailable."
        }
    }
}

@MainActor
final class CloudSyncCoordinator: ObservableObject {
    static let enabledKey = "tvplayer.cloudSync.enabled"

    @Published private(set) var availability: CloudSyncAvailability = .checking
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            Task { await engineStore.start(enabled: isEnabled) }
        }
    }

    private let defaults: UserDefaults
    private let engineStore: CloudSyncEngineStore
    private weak var settings: ServerSettingsStore?
    private weak var channels: ChannelPreferencesStore?
    private weak var playback: PlaybackCoordinator?
    private var connected = false

    init(
        defaults: UserDefaults = .standard,
        engineStore: CloudSyncEngineStore = .shared
    ) {
        self.defaults = defaults
        self.engineStore = engineStore
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func connect(
        settings: ServerSettingsStore,
        channels: ChannelPreferencesStore,
        playback: PlaybackCoordinator
    ) async {
        guard !connected else { return }
        connected = true
        self.settings = settings
        self.channels = channels
        self.playback = playback
        await engineStore.setHandlers(
            changes: { [weak self] records in
                await self?.apply(records)
            },
            status: { [weak self] status in
                await MainActor.run { self?.availability = status }
            }
        )
        await CloudSyncBridge.shared.connect(engineStore)
        await engineStore.start(enabled: isEnabled)
        exportServers()
        exportChannelPreferences()
        exportPlaybackPreferences()
    }

    func synchronizeNow() async {
        guard isEnabled else { return }
        do {
            try await engineStore.fetchAndSend()
        } catch {
            // Status is published by the engine store.
        }
    }

    func exportServers() {
        guard isEnabled, let settings else { return }
        let profiles = settings.profiles.filter { $0.id != ServerSettingsStore.environmentProfileID }
        Task {
            let existing = await engineStore.records(kind: .serverProfile)
            let currentKeys = Set(profiles.map(\.cloudSyncIdentifier))
            for profile in profiles {
                guard let data = try? JSONEncoder().encode(profile.cloudRepresentation) else { continue }
                await engineStore.upsert(CloudSyncEnvelope(
                    kind: .serverProfile,
                    key: profile.cloudSyncIdentifier,
                    payload: data
                ))
            }
            for record in existing where record.deletedAt == nil && !currentKeys.contains(record.key) {
                await engineStore.upsert(CloudSyncEnvelope(
                    kind: .serverProfile,
                    key: record.key,
                    payload: Data(),
                    deletedAt: Date()
                ))
            }
        }
    }

    func exportChannelPreferences() {
        guard isEnabled, let channels,
              let serverID = channels.activeSyncServerIdentifier
        else { return }
        let favorites = channels.favoriteChannelIDs
        Task {
            let existing = await engineStore.records(kind: .channelPreference)
                .compactMap { try? JSONDecoder().decode(SyncedChannelPreference.self, from: $0.payload) }
                .filter { $0.serverIdentifier == serverID }
            let existingIDs = Set(existing.map(\.channelID))
            for channelID in favorites.union(existingIDs) {
                let payload = SyncedChannelPreference(
                    serverIdentifier: serverID,
                    channelID: channelID,
                    isFavorite: favorites.contains(channelID)
                )
                guard let data = try? JSONEncoder().encode(payload) else { continue }
                await engineStore.upsert(CloudSyncEnvelope(
                    kind: .channelPreference,
                    key: "\(serverID)|\(channelID)",
                    payload: data
                ))
            }
        }
    }

    func exportPlaybackPreferences() {
        guard isEnabled, let playback else { return }
        let payload = SyncedPlaybackPreferences(
            commercialDetectionMode: playback.commercialDetectionMode,
            preferredAudioLanguage: playback.preferredAudioLanguage,
            subtitlePreference: playback.subtitlePreference,
            startupBehavior: playback.startupBehavior
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        Task {
            await engineStore.upsert(CloudSyncEnvelope(
                kind: .appPreference,
                key: "playback",
                payload: data
            ))
        }
    }

    func deleteCloudData() async {
        do {
            try await engineStore.deleteCloudData()
            isEnabled = false
        } catch {
            availability = .failed(error.localizedDescription)
        }
    }

    private func apply(_ records: [CloudSyncEnvelope]) async {
        for record in records {
            if record.deletedAt != nil {
                if record.kind == .serverProfile {
                    settings?.removeCloudProfile(syncIdentifier: record.key)
                }
                continue
            }
            switch record.kind {
            case .serverProfile:
                guard let profile = try? JSONDecoder().decode(
                    SyncedServerProfile.self,
                    from: record.payload
                ) else { continue }
                settings?.mergeCloudProfile(profile)
            case .channelPreference:
                guard let preferences = try? JSONDecoder().decode(
                    SyncedChannelPreference.self,
                    from: record.payload
                ) else { continue }
                channels?.setCloudFavorite(
                    preferences.isFavorite,
                    channelID: preferences.channelID,
                    serverIdentifier: preferences.serverIdentifier
                )
            case .appPreference:
                guard let preferences = try? JSONDecoder().decode(
                    SyncedPlaybackPreferences.self,
                    from: record.payload
                ) else { continue }
                playback?.applyCloudPreferences(preferences)
            case .guideSlice:
                guard let slice = try? JSONDecoder().decode(
                    SyncedGuideSlice.self,
                    from: record.payload
                ) else { continue }
                await EPGHistoryStore.shared.mergeCloudSlice(slice)
            case .commercialProfile:
                guard let profile = try? JSONDecoder().decode(
                    SyncedCommercialProfile.self,
                    from: record.payload
                ) else { continue }
                await CommercialLogoProfileStore.shared.mergeCloudProfile(profile)
            }
        }
    }
}

struct SyncedServerProfile: Codable, Equatable, Sendable {
    let syncIdentifier: String
    let name: String
    let baseURL: URL
    let username: String
    let streamProfile: String
    let htspPort: Int
    let guideCacheURL: URL?
    let xmltvURL: URL?
    let discoveryID: String?
}

struct SyncedChannelPreference: Codable, Equatable, Sendable {
    let serverIdentifier: String
    let channelID: GuideChannel.ID
    let isFavorite: Bool
}

struct SyncedPlaybackPreferences: Codable, Equatable, Sendable {
    let commercialDetectionMode: CommercialDetectionMode
    let preferredAudioLanguage: PreferredAudioLanguage
    let subtitlePreference: SubtitlePreference
    let startupBehavior: StartupBehavior
}

struct SyncedGuideSlice: Codable, Sendable {
    let serverIdentifier: String
    let channelID: String
    let day: Int64
    let partIndex: Int
    let partCount: Int
    let observedAt: Date
    let events: [TVHeadendEPGEvent]

    var key: String { "\(serverIdentifier)|\(channelID)|\(day)|\(partIndex)" }
}

struct SyncedCommercialProfile: Codable, Equatable, Sendable {
    let key: String
    let model: CommercialLogoModel
}

actor CloudSyncBridge {
    static let shared = CloudSyncBridge()

    private var engineStore: CloudSyncEngineStore?
    private var pendingGuides: [
        String: (events: [TVHeadendEPGEvent], observedAt: Date)
    ] = [:]

    func connect(_ engineStore: CloudSyncEngineStore) async {
        self.engineStore = engineStore
        let pending = pendingGuides
        pendingGuides.removeAll()
        for (serverIdentifier, guide) in pending {
            await publishGuide(
                events: guide.events,
                serverIdentifier: serverIdentifier,
                observedAt: guide.observedAt
            )
        }
    }

    func publishGuide(
        events: [TVHeadendEPGEvent],
        serverIdentifier: String,
        observedAt: Date = Date()
    ) async {
        guard let engineStore else {
            pendingGuides[serverIdentifier] = (events, observedAt)
            return
        }
        let calendar = Calendar(identifier: .gregorian)
        let groups = Dictionary(grouping: events) { event -> String in
            let day = calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(event.start))
            )
            return "\(event.channelUUID ?? "unknown")|\(Int64(day.timeIntervalSince1970))"
        }
        for group in groups.values {
            guard let first = group.first,
                  let channelID = first.channelUUID
            else { continue }
            let day = Int64(calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(first.start))
            ).timeIntervalSince1970)
            let ordered = group.sorted { $0.start < $1.start }
            let parts = stride(from: 0, to: ordered.count, by: 100).map {
                Array(ordered[$0..<min($0 + 100, ordered.count)])
            }
            for (partIndex, events) in parts.enumerated() {
                let slice = SyncedGuideSlice(
                    serverIdentifier: serverIdentifier,
                    channelID: channelID,
                    day: day,
                    partIndex: partIndex,
                    partCount: parts.count,
                    observedAt: observedAt,
                    events: events
                )
                guard let data = try? JSONEncoder().encode(slice) else { continue }
                await engineStore.upsert(CloudSyncEnvelope(
                    kind: .guideSlice,
                    key: slice.key,
                    payload: data,
                    modifiedAt: observedAt
                ))
            }
        }
    }

    func publishCommercial(key: String, model: CommercialLogoModel) async {
        guard let engineStore,
              let data = try? JSONEncoder().encode(
                SyncedCommercialProfile(key: key, model: model)
              )
        else { return }
        await engineStore.upsert(CloudSyncEnvelope(
            kind: .commercialProfile,
            key: key,
            payload: data,
            modifiedAt: model.savedAt
        ))
    }
}
