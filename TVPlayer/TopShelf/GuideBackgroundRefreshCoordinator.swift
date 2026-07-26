import Foundation
import OSLog

#if os(iOS) || os(tvOS)
@preconcurrency import BackgroundTasks
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum BackgroundGuideRefreshWorkflow {
    @MainActor
    static func run<Value: Sendable>(
        fetch: () async throws -> Value,
        sync: () async throws -> Void
    ) async throws -> Value {
        let value = try await fetch()
        try await sync()
        return value
    }
}

private enum BackgroundGuideRefreshScheduleState {
    static let coverageEndKey = "tvplayer.backgroundGuideRefresh.coverageEnd"

    static func record(
        coverageEnd: Date?,
        defaults: UserDefaults = .standard
    ) {
        if let coverageEnd {
            defaults.set(coverageEnd.timeIntervalSince1970, forKey: coverageEndKey)
        } else {
            defaults.removeObject(forKey: coverageEndKey)
        }
    }

    static func nextDate(
        after now: Date = Date(),
        retrySoon: Bool = false,
        defaults: UserDefaults = .standard
    ) -> Date {
        if retrySoon {
            return now.addingTimeInterval(GuideBackgroundRefreshPolicy.retryDelay)
        }
        let timestamp = defaults.object(forKey: coverageEndKey) as? Double
        return GuideBackgroundRefreshPolicy.nextRefreshDate(
            after: now,
            guideCoverageEnd: timestamp.map(Date.init(timeIntervalSince1970:))
        )
    }
}

private struct BackgroundGuideRefreshResult {
    let coverageEnd: Date?
    let cloudSynced: Bool

    var completedSuccessfully: Bool { cloudSynced }
}

@MainActor
private final class BackgroundGuideRefreshService {
    static let shared = BackgroundGuideRefreshService()

    private let logger = Logger(
        subsystem: "de.beutner.TVPlayer",
        category: "GuideBackgroundRefresh"
    )

    func refresh(now: Date = Date()) async -> BackgroundGuideRefreshResult? {
        guard let configuration = SharedTVHeadendConfigurationStore().read(),
              configuration.isComplete
        else {
            logger.error("Skipped background guide refresh because no server is configured")
            return nil
        }

        let cloudEnabled = UserDefaults.standard.object(
            forKey: CloudSyncCoordinator.enabledKey
        ) as? Bool ?? true
        let engineStore = CloudSyncEngineStore.shared
        var cloudReady = !cloudEnabled
        if cloudEnabled {
            await CloudSyncBridge.shared.connect(engineStore)
            do {
                try await engineStore.prepareForBackgroundSync(enabled: true)
                cloudReady = true
            } catch {
                logger.error(
                    "CloudKit could not start for background refresh: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let timeline = GuideTimeline.surrounding(now)
        let client = TVHeadendClient(configuration: configuration)
        do {
            let guide = try await BackgroundGuideRefreshWorkflow.run(
                fetch: {
                    try await client.fetchGuide(for: timeline)
                },
                sync: {
                    guard cloudEnabled, cloudReady else { return }
                    do {
                        try await engineStore.fetchAndSend()
                    } catch {
                        cloudReady = false
                        logger.error(
                            "CloudKit background upload failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            )
            try Task.checkCancellation()
            let guideCoverageEnd = timeline.availableCoverageEnd(in: guide.channels)
            let persistedSnapshot = PersistedGuideSnapshot(
                serverIdentifier: configuration.guideSnapshotIdentifier,
                channelPreferencesIdentifier: configuration.channelPreferencesIdentifier,
                serverName: guide.serverName,
                savedAt: now,
                guideCoverageEnd: guideCoverageEnd,
                channels: guide.channels
            )
            await GuideSnapshotStore.shared.save(persistedSnapshot)

#if os(tvOS)
            await publishTopShelf(
                guide: guide,
                client: client,
                configuration: configuration,
                now: now,
                coverageEnd: guideCoverageEnd
            )
#endif

            BackgroundGuideRefreshScheduleState.record(coverageEnd: guideCoverageEnd)
            logger.info(
                "Refreshed the guide in the background through \(String(describing: guideCoverageEnd), privacy: .public); CloudKit synced: \(cloudReady, privacy: .public)"
            )
            return BackgroundGuideRefreshResult(
                coverageEnd: guideCoverageEnd,
                cloudSynced: cloudReady
            )
        } catch is CancellationError {
            return nil
        } catch {
            logger.error(
                "Background guide refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

#if os(tvOS)
    private func publishTopShelf(
        guide: TVProviderSnapshot,
        client: TVHeadendClient,
        configuration: TVHeadendConfiguration,
        now: Date,
        coverageEnd: Date?
    ) async {
        do {
            let recordings = try await client.fetchRecordings()
            let preferences = ChannelPreferencesStore()
            preferences.activate(
                serverIdentifier: configuration.channelPreferencesIdentifier,
                migratingFrom: configuration.legacyChannelPreferencesIdentifier
            )
            await TopShelfSnapshotPublisher.shared.publish(
                channels: preferences.displayedChannels(from: guide.channels),
                favoriteChannelIDs: preferences.favoriteChannelIDs,
                recordings: recordings.entries,
                configuration: configuration,
                now: now,
                guideCoverageEnd: coverageEnd
            )
        } catch {
            logger.error(
                "Guide refreshed but Top Shelf recordings failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
#endif
}

#if os(iOS) || os(tvOS)
@MainActor
final class TVPlayerDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        GuideBackgroundRefreshCoordinator.shared.register()
        GuideBackgroundRefreshCoordinator.shared.scheduleFromStoredSnapshot()
        application.registerForRemoteNotifications()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        GuideBackgroundRefreshCoordinator.shared.scheduleFromStoredSnapshot()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let enabled = UserDefaults.standard.object(
                forKey: CloudSyncCoordinator.enabledKey
            ) as? Bool ?? true
            guard enabled else {
                completionHandler(.noData)
                return
            }
            do {
                let engineStore = CloudSyncEngineStore.shared
                await CloudSyncBridge.shared.connect(engineStore)
                try await engineStore.prepareForBackgroundSync(enabled: true)
                try await engineStore.fetchAndSend()
                completionHandler(.newData)
            } catch {
                completionHandler(.failed)
            }
        }
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
            using: nil,
            launchHandler: Self.launch
        )
    }

    nonisolated private static func launch(_ task: BGTask) {
        guard let refreshTask = task as? BGAppRefreshTask else {
            task.setTaskCompleted(success: false)
            return
        }
        Task { @MainActor in
            shared.handle(refreshTask)
        }
    }

    func scheduleFromStoredSnapshot(
        now: Date = Date(),
        retrySoon: Bool = false
    ) {
        schedule(
            after: BackgroundGuideRefreshScheduleState.nextDate(
                after: now,
                retrySoon: retrySoon
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
            await BackgroundGuideRefreshService.shared.refresh()
        }
        task.expirationHandler = {
            work.cancel()
        }
        Task { @MainActor in
            let result = await work.value
            let succeeded = result?.completedSuccessfully == true
            self.scheduleFromStoredSnapshot(retrySoon: !succeeded)
            task.setTaskCompleted(success: succeeded)
        }
    }
}
#elseif os(macOS)
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacGuideBackgroundRefreshCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MacGuideBackgroundRefreshCoordinator.shared.stop()
    }
}

@MainActor
final class MacGuideBackgroundRefreshCoordinator {
    static let shared = MacGuideBackgroundRefreshCoordinator()

    private let scheduler = NSBackgroundActivityScheduler(
        identifier: "de.beutner.TVPlayer.refresh-guide"
    )
    private var isScheduled = false

    private init() {}

    func start(now: Date = Date()) {
        guard !isScheduled else { return }
        isScheduled = true
        configureNextRun(now: now)
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion(.finished)
                    return
                }
                guard !self.scheduler.shouldDefer else {
                    completion(.deferred)
                    return
                }
                let result = await BackgroundGuideRefreshService.shared.refresh()
                self.configureNextRun(
                    now: Date(),
                    retrySoon: result?.completedSuccessfully != true
                )
                completion(.finished)
            }
        }
    }

    func stop() {
        scheduler.invalidate()
        isScheduled = false
    }

    private func configureNextRun(
        now: Date,
        retrySoon: Bool = false
    ) {
        let date = BackgroundGuideRefreshScheduleState.nextDate(
            after: now,
            retrySoon: retrySoon
        )
        scheduler.interval = max(
            GuideBackgroundRefreshPolicy.minimumDelay,
            date.timeIntervalSince(now)
        )
        scheduler.tolerance = min(30 * 60, scheduler.interval / 2)
    }
}
#endif
