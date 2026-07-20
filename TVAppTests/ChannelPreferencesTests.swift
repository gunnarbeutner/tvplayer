import XCTest
@testable import TVApp

final class ChannelPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ChannelPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor func testDefaultsToTVHeadendOrder() {
        let store = makeStore()
        let channels = makeChannels(["one", "two", "three"])

        XCTAssertEqual(store.displayedChannels(from: channels).map(\.id), ["one", "two", "three"])
        XCTAssertTrue(store.favoriteChannelIDs.isEmpty)
    }

    @MainActor func testFavoritesArePinnedWhileBothGroupsKeepTVHeadendOrder() {
        let store = makeStore()
        let channels = makeChannels(["one", "two", "three", "four"])

        store.toggleFavorite("three")
        store.toggleFavorite("two")

        XCTAssertEqual(store.displayedChannels(from: channels).map(\.id), ["two", "three", "one", "four"])
    }

    @MainActor func testRemovingFavoriteRestoresItsNormalRelativePosition() {
        let store = makeStore()
        let channels = makeChannels(["one", "two", "three"])

        store.toggleFavorite("three")
        XCTAssertEqual(store.displayedChannels(from: channels).map(\.id), ["three", "one", "two"])

        store.toggleFavorite("three")
        XCTAssertEqual(store.displayedChannels(from: channels).map(\.id), ["one", "two", "three"])
    }

    @MainActor func testMissingFavoriteIsRememberedWhenChannelReturns() {
        let store = makeStore()
        store.toggleFavorite("two")

        XCTAssertEqual(store.displayedChannels(from: makeChannels(["one", "three"])).map(\.id), ["one", "three"])
        XCTAssertEqual(store.displayedChannels(from: makeChannels(["one", "two", "three"])).map(\.id), ["two", "one", "three"])
    }

    @MainActor func testPreferencesRoundTripAndStayIsolatedByServer() {
        var store = makeStore(server: "server-a")
        store.toggleFavorite("two")

        store = ChannelPreferencesStore(defaults: defaults)
        store.activate(serverIdentifier: "server-a")
        XCTAssertEqual(store.favoriteChannelIDs, ["two"])

        store.activate(serverIdentifier: "server-b")
        XCTAssertTrue(store.favoriteChannelIDs.isEmpty)
    }

    @MainActor func testExistingOrderingAndFilterPayloadMigratesToFavoritesOnly() throws {
        let json = #"{"version":1,"profiles":{"server":{"favoriteChannelIDs":["two"],"orderedChannelIDs":["three","two","one"],"filter":"favorites"}}}"#
        defaults.set(try XCTUnwrap(json.data(using: .utf8)), forKey: "tvplayer.channelPreferences.v1")

        let store = makeStore()
        let channels = makeChannels(["one", "two", "three"])

        XCTAssertEqual(store.favoriteChannelIDs, ["two"])
        XCTAssertEqual(store.displayedChannels(from: channels).map(\.id), ["two", "one", "three"])
    }

    @MainActor func testCorruptPersistenceFallsBackToDefaults() {
        defaults.set(Data("not-json".utf8), forKey: "tvplayer.channelPreferences.v1")

        let store = makeStore()

        XCTAssertTrue(store.favoriteChannelIDs.isEmpty)
    }

    @MainActor func testConfigurationPreferenceIdentifierNormalizesCredentialsAndTrailingSlash() {
        let first = configuration(url: "HTTP://Example.test:9981/", username: " viewer ")
        let second = configuration(url: "http://example.test:9981", username: "viewer")

        XCTAssertEqual(first.channelPreferencesIdentifier, second.channelPreferencesIdentifier)
        XCTAssertFalse(first.channelPreferencesIdentifier?.contains("secret") == true)

        let distinctAccount = configuration(url: "http://example.test:9981", username: "Viewer")
        XCTAssertNotEqual(second.channelPreferencesIdentifier, distinctAccount.channelPreferencesIdentifier)
    }

    @MainActor private func makeStore(server: String = "server") -> ChannelPreferencesStore {
        let store = ChannelPreferencesStore(defaults: defaults)
        store.activate(serverIdentifier: server)
        return store
    }

    private func makeChannels(_ ids: [String]) -> [GuideChannel] {
        ids.enumerated().map { offset, id in
            GuideChannel(
                id: id,
                number: offset + 1,
                name: id.capitalized,
                monogram: String(id.prefix(1)).uppercased(),
                tint: .blue,
                iconURL: nil,
                programs: []
            )
        }
    }

    private func configuration(url: String, username: String) -> TVHeadendConfiguration {
        TVHeadendConfiguration(
            baseURL: URL(string: url),
            username: username,
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
    }
}
