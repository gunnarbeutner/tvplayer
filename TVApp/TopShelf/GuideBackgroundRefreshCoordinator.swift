#if os(tvOS)
@preconcurrency import BackgroundTasks
import OSLog
import UIKit

@MainActor
final class TVAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        GuideBackgroundRefreshCoordinator.shared.register()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        GuideBackgroundRefreshCoordinator.shared.scheduleFromStoredSnapshot()
    }
}

@MainActor
final class GuideBackgroundRefreshCoordinator {
    static let shared = GuideBackgroundRefreshCoordinator()
    static let taskIdentifier = "de.beutner.TVPlayer.refresh-guide"

    private let logger = Logger(
        subsystem: "de.beutner.TVPlayer",
        category: "GuideBackgroundRefresh"
    )
    private var isRegistered = false

    private init() {}

    func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self.handle(refreshTask)
            }
        }
    }

    func scheduleFromStoredSnapshot(now: Date = Date()) {
        schedule(
            after: GuideBackgroundRefreshPolicy.nextRefreshDate(
                after: now,
                guideCoverageEnd: TopShelfSnapshotStore.load()?.guideCoverageEnd
            )
        )
    }

    func schedule(after date: Date) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = date
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled guide refresh after \(date, privacy: .public)")
        } catch {
            logger.error(
                "Could not schedule guide refresh: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        let work = Task { @MainActor in
            await refreshGuide()
        }
        task.expirationHandler = {
            work.cancel()
        }
        Task { @MainActor in
            let succeeded = await work.value
            self.scheduleFromStoredSnapshot()
            task.setTaskCompleted(success: succeeded)
        }
    }

    private func refreshGuide(now: Date = Date()) async -> Bool {
        guard let configuration = SharedTVHeadendConfigurationStore().read(),
              configuration.isComplete
        else {
            logger.error("Skipped background guide refresh because no server is configured")
            return false
        }

        let timeline = GuideTimeline.surrounding(now)
        let client = TVHeadendClient(configuration: configuration)
        do {
            async let guideRequest = client.fetchGuide(for: timeline)
            async let recordingRequest = client.fetchRecordings()
            let (guide, recordings) = try await (guideRequest, recordingRequest)
            try Task.checkCancellation()
            let guideCoverageEnd = timeline.availableCoverageEnd(in: guide.channels)

            let preferences = ChannelPreferencesStore()
            preferences.activate(
                serverIdentifier: configuration.channelPreferencesIdentifier,
                migratingFrom: configuration.legacyChannelPreferencesIdentifier
            )
            let displayedChannels = preferences.displayedChannels(from: guide.channels)

            let persistedSnapshot = PersistedGuideSnapshot(
                serverIdentifier: configuration.guideSnapshotIdentifier,
                channelPreferencesIdentifier: configuration.channelPreferencesIdentifier,
                serverName: guide.serverName,
                savedAt: now,
                guideCoverageEnd: guideCoverageEnd,
                channels: guide.channels
            )
            await GuideSnapshotStore.shared.save(persistedSnapshot)
            await TopShelfSnapshotPublisher.shared.publish(
                channels: displayedChannels,
                favoriteChannelIDs: preferences.favoriteChannelIDs,
                recordings: recordings.entries,
                configuration: configuration,
                now: now,
                guideCoverageEnd: guideCoverageEnd
            )
            logger.info(
                "Refreshed the guide in the background through \(String(describing: guideCoverageEnd), privacy: .public)"
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            logger.error(
                "Background guide refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
#endif
