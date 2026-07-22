import XCTest
@testable import TVApp

final class ServerSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var keychain: MemoryPasswordStore!

    override func setUp() {
        super.setUp()
        suiteName = "ServerSettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        keychain = MemoryPasswordStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        keychain = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testLegacyConfigurationMigratesAsEditedProfileWithPerProfilePassword() throws {
        defaults.set("http://legacy.test:9981", forKey: "tvheadend.baseURL")
        defaults.set("viewer", forKey: "tvheadend.username")
        defaults.set("pass", forKey: "tvheadend.streamProfile")
        defaults.set("9982", forKey: "tvheadend.htspPort")
        keychain.values[KeychainPasswordStore.legacyAccount] = "legacy-secret"

        var store = makeStore()
        let profile = try XCTUnwrap(store.activeProfile)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(profile.origin, .manual)
        XCTAssertTrue(profile.isEdited)
        XCTAssertEqual(store.configuration.password, "legacy-secret")
        XCTAssertEqual(store.configuration.serverProfileID, profile.id)

        store = makeStore()
        XCTAssertEqual(store.activeProfile?.id, profile.id)
        XCTAssertEqual(store.configuration.password, "legacy-secret")
    }

    @MainActor
    func testDiscoveryAddsMultipleProfilesWithoutChangingExistingSelection() throws {
        let store = makeStore()
        store.handleDiscoveryEvent(.upsert(service(id: "one", name: "One", host: "one.test")))
        let firstID = try XCTUnwrap(store.activeProfileID)
        store.handleDiscoveryEvent(.upsert(service(id: "two", name: "Two", host: "two.test")))

        XCTAssertEqual(store.profiles.map(\.name), ["One", "Two"])
        XCTAssertEqual(store.activeProfileID, firstID)
        XCTAssertEqual(store.onlineProfileIDs.count, 2)
        XCTAssertEqual(store.configuration.baseURL?.host, "one.test")
    }

    @MainActor
    func testDiscoveryAdoptsAnonymousAccess() throws {
        let store = makeStore()

        store.handleDiscoveryEvent(.upsert(
            service(id: "anonymous", host: "server.test", password: "", username: "")
        ))

        XCTAssertEqual(store.configuration.username, "")
        XCTAssertEqual(store.configuration.password, "")
        XCTAssertTrue(store.configuration.isComplete)
    }

    @MainActor
    func testManualSettingsRejectPartialCredentials() {
        let store = makeStore()
        store.baseURLText = "http://server.test:9981"

        store.username = "viewer"
        store.password = ""
        XCTAssertThrowsError(try store.validatedDraft()) { error in
            guard let error = error as? ConfigurationError,
                  case .incompleteCredentials = error
            else { return XCTFail("Expected incomplete credentials") }
        }

        store.username = ""
        store.password = "secret"
        XCTAssertThrowsError(try store.validatedDraft()) { error in
            guard let error = error as? ConfigurationError,
                  case .incompleteCredentials = error
            else { return XCTFail("Expected incomplete credentials") }
        }
    }

    @MainActor
    func testUneditedDiscoveryProfileFollowsAdvertisedChangesUsingStableID() throws {
        let store = makeStore()
        store.handleDiscoveryEvent(.upsert(service(id: "stable", host: "old.test", password: "old")))
        let profileID = try XCTUnwrap(store.activeProfileID)
        let dataIdentifier = store.configuration.dataStoreIdentifier

        store.handleDiscoveryEvent(
            .upsert(service(id: "stable", host: "new.test", password: "new", username: "updated"))
        )

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.activeProfileID, profileID)
        XCTAssertEqual(store.configuration.baseURL?.host, "new.test")
        XCTAssertEqual(store.configuration.username, "updated")
        XCTAssertEqual(store.configuration.password, "new")
        XCTAssertEqual(store.configuration.dataStoreIdentifier, dataIdentifier)
    }

    @MainActor
    func testManualSaveFreezesWholeDiscoveredProfileUntilAutomaticUpdatesAreRestored() throws {
        let store = makeStore()
        store.handleDiscoveryEvent(.upsert(service(id: "stable", host: "old.test", password: "old")))
        let profileID = try XCTUnwrap(store.activeProfileID)

        store.username = "manual-user"
        try store.save()
        XCTAssertTrue(try XCTUnwrap(store.activeProfile).isEdited)

        store.handleDiscoveryEvent(
            .upsert(service(id: "stable", host: "new.test", password: "new", username: "automatic-user"))
        )
        XCTAssertEqual(store.configuration.baseURL?.host, "old.test")
        XCTAssertEqual(store.configuration.username, "manual-user")
        XCTAssertEqual(store.configuration.password, "old")

        store.restoreAutomaticUpdates(profileID)
        XCTAssertFalse(try XCTUnwrap(store.activeProfile).isEdited)
        XCTAssertEqual(store.configuration.baseURL?.host, "new.test")
        XCTAssertEqual(store.configuration.username, "automatic-user")
        XCTAssertEqual(store.configuration.password, "new")
    }

    @MainActor
    func testOnlineDiscoveredProfileCanOnlyBeForgottenAfterRemoval() throws {
        let store = makeStore()
        let discovered = service(id: "stable", host: "server.test")
        store.handleDiscoveryEvent(.upsert(discovered))
        let profile = try XCTUnwrap(store.activeProfile)

        XCTAssertFalse(store.canForget(profile))
        store.forget(profile.id)
        XCTAssertEqual(store.profiles.count, 1)

        store.handleDiscoveryEvent(.removed(serviceIdentity: discovered.serviceIdentity))
        XCTAssertFalse(store.isOnline(try XCTUnwrap(store.activeProfile)))
        store.forget(profile.id)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(keychain.deletedAccounts.contains("server-profile:\(profile.id)"))
    }

    @MainActor
    func testMatchingManualServerBecomesEditedDiscoveryProfileWithoutBeingOverwritten() throws {
        let store = makeStore()
        store.baseURLText = "HTTP://SERVER.test:9981/"
        store.username = "manual-user"
        store.password = "manual-password"
        try store.save()

        store.handleDiscoveryEvent(
            .upsert(service(id: "stable", host: "server.test", password: "automatic-password"))
        )

        let profile = try XCTUnwrap(store.activeProfile)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(profile.origin, .discovered)
        XCTAssertTrue(profile.isEdited)
        XCTAssertEqual(profile.discoveryID, "stable")
        XCTAssertEqual(store.configuration.username, "manual-user")
        XCTAssertEqual(store.configuration.password, "manual-password")
    }

    @MainActor
    func testActiveSelectionAndProfilesRoundTrip() throws {
        var store = makeStore()
        store.handleDiscoveryEvent(.upsert(service(id: "one", name: "One", host: "one.test")))
        store.handleDiscoveryEvent(.upsert(service(id: "two", name: "Two", host: "two.test")))
        let secondID = try XCTUnwrap(store.profiles.last?.id)
        store.selectServer(secondID)

        store = makeStore()
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(store.activeProfileID, secondID)
        XCTAssertEqual(store.configuration.baseURL?.host, "two.test")
        XCTAssertTrue(store.onlineProfileIDs.isEmpty)
    }

    @MainActor
    func testSelectingActiveServerForEditingPreservesConnectionStatus() async throws {
        let serverInfo = try JSONDecoder().decode(
            TVHeadendServerInfo.self,
            from: Data(#"{"name":"TVHeadend","version":"4.3","capabilities":["timeshift"]}"#.utf8)
        )
        let store = ServerSettingsStore(
            defaults: defaults,
            keychain: keychain,
            sharedConfiguration: nil,
            environment: [:],
            startsDiscovery: false,
            automaticallyTestsConnections: false,
            serverInfoLoader: { _ in serverInfo },
            timeshiftProbe: { _ in }
        )
        store.handleDiscoveryEvent(.upsert(service(
            id: "active",
            name: "Active",
            host: "active.test"
        )))
        let activeID = try XCTUnwrap(store.activeProfileID)
        await store.testConnection()
        let connectionStatus = store.connectionStatus
        let timeshiftStatus = store.timeshiftStatus

        store.selectServer(activeID)

        XCTAssertEqual(store.connectionStatus, connectionStatus)
        XCTAssertEqual(store.timeshiftStatus, timeshiftStatus)
    }

    @MainActor
    func testDiscoveredAddressesPersistAndRefreshForAnEditedProfile() throws {
        var store = makeStore()
        store.handleDiscoveryEvent(.upsert(service(
            id: "stable",
            host: "tvheadend.local",
            resolvedAddresses: ["192.168.10.20", "2001:db8::20"]
        )))

        XCTAssertEqual(
            store.configuration.resolvedAddresses,
            ["192.168.10.20", "2001:db8::20"]
        )

        store.username = "manual-user"
        try store.save()
        let revisionBeforeAddressRefresh = store.revision
        store.handleDiscoveryEvent(.upsert(service(
            id: "stable",
            host: "tvheadend.local",
            resolvedAddresses: ["192.168.10.21"]
        )))

        XCTAssertEqual(store.configuration.username, "manual-user")
        XCTAssertEqual(store.configuration.resolvedAddresses, ["192.168.10.21"])
        XCTAssertEqual(store.revision, revisionBeforeAddressRefresh + 1)

        store = makeStore()
        XCTAssertEqual(store.configuration.resolvedAddresses, ["192.168.10.21"])
    }

    @MainActor
    func testMissingAddressesInAnUpdateDoNotEraseThePersistentCache() {
        let store = makeStore()
        store.handleDiscoveryEvent(.upsert(service(
            id: "stable",
            host: "tvheadend.local",
            resolvedAddresses: ["192.168.10.20"]
        )))

        store.handleDiscoveryEvent(.upsert(service(
            id: "stable",
            host: "tvheadend.local",
            resolvedAddresses: []
        )))

        XCTAssertEqual(store.configuration.resolvedAddresses, ["192.168.10.20"])
    }

    func testOlderProfilesDecodeWithAnEmptyAddressCache() throws {
        let data = Data(#"""
        {
          "id": "legacy",
          "name": "Legacy",
          "baseURL": "http:\/\/tvheadend.local:9981",
          "username": "viewer",
          "streamProfile": "pass",
          "htspPort": 9982,
          "origin": "manual",
          "isEdited": true
        }
        """#.utf8)

        let profile = try JSONDecoder().decode(TVHeadendServerProfile.self, from: data)

        XCTAssertEqual(profile.resolvedAddresses, [])
        XCTAssertEqual(profile.guideResolvedAddresses, [])
    }

    @MainActor
    func testConnectionResultIsDiscardedWhenTheSameProfileDraftChanges() async throws {
        let requestStarted = expectation(description: "Connection test started")
        var continuation: CheckedContinuation<TVHeadendServerInfo, Never>?
        let serverInfo = try JSONDecoder().decode(
            TVHeadendServerInfo.self,
            from: Data(#"{"name":"TVHeadend","capabilities":[]}"#.utf8)
        )
        let store = ServerSettingsStore(
            defaults: defaults,
            keychain: keychain,
            sharedConfiguration: nil,
            environment: [:],
            startsDiscovery: false,
            automaticallyTestsConnections: false,
            serverInfoLoader: { _ in
                requestStarted.fulfill()
                return await withCheckedContinuation { continuation = $0 }
            }
        )
        store.baseURLText = "http://old.test:9981"
        try store.save()
        let profileID = store.editingProfileID

        let test = Task { await store.testConnection() }
        await fulfillment(of: [requestStarted], timeout: 1)
        store.baseURLText = "http://new.test:9981"
        continuation?.resume(returning: serverInfo)
        await test.value

        XCTAssertEqual(store.editingProfileID, profileID)
        XCTAssertEqual(store.connectionStatus, .notTested)
        XCTAssertEqual(store.timeshiftStatus, .notTested)
    }

    @MainActor
    private func makeStore() -> ServerSettingsStore {
        ServerSettingsStore(
            defaults: defaults,
            keychain: keychain,
            sharedConfiguration: nil,
            environment: [:],
            startsDiscovery: false,
            automaticallyTestsConnections: false
        )
    }

    private func service(
        id: String,
        name: String = "TVHeadend",
        host: String,
        password: String = "secret",
        username: String = "viewer",
        resolvedAddresses: [String] = []
    ) -> DiscoveredTVHeadendService {
        var fields = [
            "txtvers": Data("1".utf8),
            "id": Data(id.utf8),
            "scheme": Data("http".utf8),
            "path": Data("/".utf8),
            "profile": Data("pass".utf8),
            "htsp_port": Data("9982".utf8),
        ]
        if !username.isEmpty, !password.isEmpty {
            fields["username"] = Data(username.utf8)
            fields["password"] = Data(password.utf8)
        }
        return DiscoveredTVHeadendService(
            name: name,
            serviceIdentity: "local.|_tvplayer._tcp.|\(id)",
            settings: DiscoveredTVHeadendSettings(
                fields: fields,
                hostName: host,
                port: 9981,
                resolvedAddresses: resolvedAddresses
            )!
        )
    }
}

private final class MemoryPasswordStore: PasswordStoring {
    var values: [String: String] = [:]
    var deletedAccounts: Set<String> = []

    func read(account: String) -> String { values[account] ?? "" }

    func write(_ password: String, account: String) throws {
        if password.isEmpty {
            delete(account: account)
        } else {
            values[account] = password
        }
    }

    func delete(account: String) {
        values[account] = nil
        deletedAccounts.insert(account)
    }
}
