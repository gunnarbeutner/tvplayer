import XCTest
@testable import TVPlayer

@MainActor
final class PlaybackPreferencesTests: XCTestCase {
    func testPlaybackPreferencesPersist() {
        let suiteName = "PlaybackPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = PlaybackCoordinator(defaults: defaults)
        coordinator.preferredAudioLanguage = .german
        coordinator.subtitlePreference = .automatic
        coordinator.startupBehavior = .lastUsed
        coordinator.recordVisitedSection(.channels)

        let restored = PlaybackCoordinator(defaults: defaults)
        XCTAssertEqual(restored.preferredAudioLanguage, .german)
        XCTAssertEqual(restored.subtitlePreference, .automatic)
        XCTAssertEqual(restored.startupBehavior, .lastUsed)
        XCTAssertEqual(restored.initialStartupSection, .channels)
    }

    func testDefaultStartupSectionIsGuide() {
        let suiteName = "PlaybackPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            PlaybackCoordinator(defaults: defaults).initialStartupSection,
            .guide
        )
    }

    func testLeavingPlayerPreparesGuideFocusBeforeRevealingIt() async {
        let suiteName = "PlaybackPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = PlaybackCoordinator(defaults: defaults)
        let channel = GuideChannel(
            id: "channel",
            number: 1,
            name: "Channel",
            monogram: "CH",
            tint: .orange,
            iconURL: nil,
            programs: []
        )
        coordinator.start(
            channel: channel,
            program: nil,
            configuration: TVHeadendConfiguration(
                baseURL: nil,
                username: "",
                password: "",
                streamProfile: "",
                guideCacheURL: nil,
                xmltvURL: nil
            )
        )
        let focusRevision = coordinator.focusReturnRevision

        coordinator.leavePlayer()

        XCTAssertEqual(coordinator.focusReturnRevision, focusRevision + 1)
        XCTAssertTrue(
            coordinator.isPlayerPresented,
            "The player must cover the guide until its restored selection has been applied"
        )

        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(coordinator.isPlayerPresented)
    }
}
