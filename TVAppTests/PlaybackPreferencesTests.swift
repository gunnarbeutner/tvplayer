import XCTest
@testable import TVApp

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
}
