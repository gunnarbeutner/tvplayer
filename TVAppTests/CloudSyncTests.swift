import XCTest
@testable import TVApp

final class CloudSyncTests: XCTestCase {
    func testServerIdentityNormalizesEndpointWithoutEmbeddingCredentials() throws {
        let first = try XCTUnwrap(URL(string: "HTTP://Example.test:9981/path/"))
        let second = try XCTUnwrap(URL(string: "http://example.test:9981/path"))

        let firstID = CloudSyncIdentity.normalizedServer(url: first, username: " viewer ")
        let secondID = CloudSyncIdentity.normalizedServer(url: second, username: "viewer")

        XCTAssertEqual(firstID, secondID)
        XCTAssertFalse(firstID.contains("viewer"))
        XCTAssertFalse(firstID.contains("example"))
    }

    func testRecordNameIsStableAndDoesNotContainTheLogicalKey() {
        let first = CloudSyncEnvelope(
            kind: .serverProfile,
            key: "private-server-key",
            payload: Data("one".utf8)
        )
        let second = CloudSyncEnvelope(
            kind: .serverProfile,
            key: "private-server-key",
            payload: Data("two".utf8)
        )

        XCTAssertEqual(first.recordName, second.recordName)
        XCTAssertFalse(first.recordName.contains("private-server-key"))
    }

    func testEquivalentUpsertDoesNotAdvanceMirrorTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CloudSyncEngineStore(directoryURL: directory)
        let original = CloudSyncEnvelope(
            kind: .appPreference,
            key: "playback",
            payload: Data("same".utf8),
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let redundant = CloudSyncEnvelope(
            kind: .appPreference,
            key: "playback",
            payload: Data("same".utf8),
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        await store.upsert(original)
        await store.upsert(redundant)

        let records = await store.records(kind: .appPreference)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.modifiedAt, original.modifiedAt)
    }

    @MainActor
    func testCloudFavoriteChangesOnlyOneChannel() {
        let suite = "CloudSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChannelPreferencesStore(defaults: defaults)
        store.activate(serverIdentifier: "server")

        store.setCloudFavorite(true, channelID: "one", serverIdentifier: "server")
        store.setCloudFavorite(true, channelID: "two", serverIdentifier: "server")
        store.setCloudFavorite(false, channelID: "one", serverIdentifier: "server")

        XCTAssertEqual(store.favoriteChannelIDs, ["two"])
    }

    func testGuideSliceImportKeepsOneDayOfHistory() async {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EPGHistoryStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let recent = event(
            id: 1,
            start: Int64(now.timeIntervalSince1970) - 7_200,
            stop: Int64(now.timeIntervalSince1970) - 3_600
        )
        let expired = event(
            id: 2,
            start: Int64(now.timeIntervalSince1970) - 100_000,
            stop: Int64(now.timeIntervalSince1970) - 90_000
        )
        let slice = SyncedGuideSlice(
            serverIdentifier: "server",
            channelID: "channel",
            day: 0,
            partIndex: 0,
            partCount: 1,
            observedAt: now,
            events: [recent, expired]
        )

        await store.mergeCloudSlice(slice, now: now)

        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["eventsByServer"] as? [String: Any],
              let events = servers["server"] as? [[String: Any]]
        else {
            return XCTFail("Expected the imported guide slice to be persisted")
        }
        XCTAssertEqual(events.compactMap { $0["eventId"] as? Int }, [1])
    }

    func testCommercialProfilesMergeEvidenceFromBothDevices() {
        let bounds = CommercialLogoBounds(x: 0, y: 0, width: 2, height: 2)
        let local = CommercialLogoCandidateModel(
            id: UUID(),
            bounds: bounds,
            edgeMask: [1, 1, 0, 0],
            role: .untrusted,
            observedSeconds: 30,
            sceneCount: 2,
            programmeIDs: ["local"],
            lastSeenAt: nil
        )
        let remote = CommercialLogoCandidateModel(
            id: UUID(),
            bounds: bounds,
            edgeMask: [1, 1, 0, 0],
            role: .channelIdentity,
            observedSeconds: 60,
            sceneCount: 4,
            programmeIDs: ["remote"],
            lastSeenAt: nil
        )

        let merged = CommercialLogoProfileStore.merged(
            CommercialLogoModel(candidates: [local]),
            CommercialLogoModel(candidates: [remote])
        )

        XCTAssertEqual(merged.candidates.count, 1)
        XCTAssertEqual(merged.candidates[0].observedSeconds, 60)
        XCTAssertEqual(merged.candidates[0].programmeIDs, ["local", "remote"])
        XCTAssertEqual(merged.candidates[0].role, .channelIdentity)
    }

    private func event(id: Int, start: Int64, stop: Int64) -> TVHeadendEPGEvent {
        try! JSONDecoder().decode(
            TVHeadendEPGEvent.self,
            from: Data(
                #"{"eventId":\#(id),"channelUuid":"channel","title":"Programme","start":\#(start),"stop":\#(stop)}"#.utf8
            )
        )
    }
}
