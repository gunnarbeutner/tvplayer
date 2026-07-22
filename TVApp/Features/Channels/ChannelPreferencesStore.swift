import Foundation

@MainActor
final class ChannelPreferencesStore: ObservableObject {
    private struct StoredProfile: Codable, Equatable {
        var favoriteChannelIDs: Set<GuideChannel.ID> = []
    }

    private struct StoredPayload: Codable {
        var version = 1
        var profiles: [String: StoredProfile] = [:]
    }

    private static let storageKey = "tvplayer.channelPreferences.v1"

    @Published private(set) var favoriteChannelIDs: Set<GuideChannel.ID> = []
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private var payload: StoredPayload
    private var activeServerIdentifier: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(StoredPayload.self, from: data),
           decoded.version == 1 {
            payload = decoded
        } else {
            payload = StoredPayload()
        }
    }

    func activate(serverIdentifier: String?, migratingFrom legacyIdentifier: String? = nil) {
        guard activeServerIdentifier != serverIdentifier else { return }
        if let serverIdentifier,
           payload.profiles[serverIdentifier] == nil,
           let legacyIdentifier,
           let legacy = payload.profiles[legacyIdentifier] {
            payload.profiles[serverIdentifier] = legacy
            persist()
        }
        activeServerIdentifier = serverIdentifier
        let activatedFavoriteChannelIDs = serverIdentifier
            .flatMap { payload.profiles[$0]?.favoriteChannelIDs }
            ?? []
        // A discovered server may replace a legacy/cache identifier without
        // changing the actual favourites. Do not make the guide rebuild and
        // restore focus when its visible ordering is already correct.
        guard favoriteChannelIDs != activatedFavoriteChannelIDs else { return }
        favoriteChannelIDs = activatedFavoriteChannelIDs
        revision &+= 1
    }

    func isFavorite(_ channelID: GuideChannel.ID) -> Bool {
        favoriteChannelIDs.contains(channelID)
    }

    func toggleFavorite(_ channelID: GuideChannel.ID) {
        if favoriteChannelIDs.contains(channelID) {
            favoriteChannelIDs.remove(channelID)
        } else {
            favoriteChannelIDs.insert(channelID)
        }
        saveActiveProfile()
    }

    /// Preserves TVHeadend's order within both groups while keeping favourites
    /// together at the front of every channel-based view.
    func displayedChannels(from channels: [GuideChannel]) -> [GuideChannel] {
        let favorites = channels.filter { favoriteChannelIDs.contains($0.id) }
        return favorites + channels.filter { !favoriteChannelIDs.contains($0.id) }
    }

    private func saveActiveProfile() {
        guard let activeServerIdentifier else { return }
        payload.profiles[activeServerIdentifier] = StoredProfile(
            favoriteChannelIDs: favoriteChannelIDs
        )
        persist()
        revision &+= 1
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
