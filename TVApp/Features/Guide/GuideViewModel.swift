import Foundation

enum GuideLoadState: Equatable {
    case needsConfiguration
    case loading
    case loaded(serverName: String, channelCount: Int)
    case failed(String)
}

@MainActor
final class GuideViewModel: ObservableObject {
    typealias GuideFetch = @MainActor (
        _ configuration: TVHeadendConfiguration,
        _ timeline: GuideTimeline,
        _ channelUpdate: (@MainActor @Sendable ([GuideChannel]) -> Void)?
    ) async throws -> TVProviderSnapshot

    @Published private(set) var now: Date
    @Published private(set) var timeline: GuideTimeline {
        didSet { guideRevision &+= 1 }
    }
    @Published private(set) var channels: [GuideChannel] {
        didSet {
            rebuildGuideIndexes()
            guideRevision &+= 1
        }
    }
    @Published private(set) var loadState: GuideLoadState = .needsConfiguration
    @Published private(set) var hasUsableGuide = false

    /// Changes only when layout-bearing guide data changes. This lets the
    /// UIKit grid skip expensive value comparisons during unrelated updates.
    @Published private(set) var guideRevision = 0

    private var lastConfiguration: TVHeadendConfiguration?
    private var lastLoadedAt: Date?
    private var activeSnapshotIdentifier: String?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private let fetchGuide: GuideFetch
    private var programByID: [GuideProgram.ID: GuideProgram] = [:]
    private var channelByID: [GuideChannel.ID: GuideChannel] = [:]

    private static let refreshInterval: TimeInterval = 120

    init(
        now: Date = Date(),
        configuration: TVHeadendConfiguration? = nil,
        cachedSnapshot: PersistedGuideSnapshot? = nil,
        fetchGuide: @escaping GuideFetch = { configuration, timeline, channelUpdate in
            try await TVHeadendClient(configuration: configuration).fetchGuide(
                for: timeline,
                channelUpdate: channelUpdate
            )
        }
    ) {
        let timeline = GuideTimeline.surrounding(now)
        self.now = now
        self.timeline = timeline
        self.fetchGuide = fetchGuide
        channels = []
        defer { rebuildGuideIndexes() }

        guard let cachedSnapshot else { return }
        if let configuration, configuration.isComplete,
           cachedSnapshot.serverIdentifier != configuration.guideSnapshotIdentifier,
           cachedSnapshot.serverIdentifier != configuration.legacyGuideSnapshotIdentifier {
            return
        }

        let restoredChannels = cachedSnapshot.restoredChannels(for: timeline)
        let hasCurrentOrFutureProgramme = restoredChannels.lazy
            .flatMap(\.programs)
            .contains { $0.end > now }
        guard hasCurrentOrFutureProgramme else { return }

        channels = restoredChannels
        hasUsableGuide = true
        loadState = .loaded(
            serverName: cachedSnapshot.serverName,
            channelCount: restoredChannels.count
        )
        activeSnapshotIdentifier = configuration?.guideSnapshotIdentifier
            ?? cachedSnapshot.serverIdentifier
    }

    func tick(at date: Date = Date()) {
        now = date
    }

    func load(
        configuration: TVHeadendConfiguration,
        at date: Date = Date(),
        force: Bool = false
    ) async {
        let refreshedTimeline = GuideTimeline.surrounding(date)
        now = date

        guard configuration.isComplete else {
            cancelActiveLoad()
            // mDNS may restore configuration just after the first frame. Keep
            // showing a usable local snapshot during that brief interval.
            guard !hasUsableGuide else { return }
            timeline = refreshedTimeline
            channels = []
            hasUsableGuide = false
            loadState = .needsConfiguration
            lastConfiguration = nil
            lastLoadedAt = nil
            activeSnapshotIdentifier = nil
            return
        }

        let snapshotIdentifier = configuration.guideSnapshotIdentifier
        if activeSnapshotIdentifier != snapshotIdentifier {
            cancelActiveLoad()
            timeline = refreshedTimeline
            channels = []
            hasUsableGuide = false
            lastConfiguration = nil
            lastLoadedAt = nil
            activeSnapshotIdentifier = snapshotIdentifier
        }

        let isFresh = lastConfiguration == configuration
            && lastLoadedAt.map { date.timeIntervalSince($0) < Self.refreshInterval } == true
        guard force || !isFresh else { return }
        guard loadTask == nil || force else { return }

        cancelActiveLoad()
        loadGeneration &+= 1
        let generation = loadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(
                configuration: configuration,
                snapshotIdentifier: snapshotIdentifier,
                timeline: refreshedTimeline,
                date: date,
                generation: generation
            )
        }
        loadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == loadGeneration {
            loadTask = nil
        }
    }

    private func performLoad(
        configuration: TVHeadendConfiguration,
        snapshotIdentifier: String,
        timeline refreshedTimeline: GuideTimeline,
        date: Date,
        generation: Int
    ) async {
        guard isCurrentLoad(generation, snapshotIdentifier: snapshotIdentifier) else { return }

        if !hasUsableGuide {
            loadState = .loading
        }

        if !hasUsableGuide,
           let cached = await GuideSnapshotStore.shared.load(serverIdentifier: snapshotIdentifier) {
            guard !Task.isCancelled,
                  isCurrentLoad(generation, snapshotIdentifier: snapshotIdentifier)
            else { return }
            let restoredChannels = cached.restoredChannels(for: refreshedTimeline)
            let hasCurrentOrFutureProgramme = restoredChannels.lazy
                .flatMap(\.programs)
                .contains { $0.end > date }
            if hasCurrentOrFutureProgramme {
                timeline = refreshedTimeline
                channels = restoredChannels
                hasUsableGuide = true
                loadState = .loaded(
                    serverName: cached.serverName,
                    channelCount: restoredChannels.count
                )
            }
        }

        do {
            let snapshot = try await fetchGuide(
                configuration,
                refreshedTimeline,
                { [weak self] channelShells in
                    guard let self,
                          self.isCurrentLoad(generation, snapshotIdentifier: snapshotIdentifier),
                          !self.hasUsableGuide
                    else { return }
                    self.timeline = refreshedTimeline
                    self.channels = channelShells
                }
            )
            try Task.checkCancellation()
            guard isCurrentLoad(generation, snapshotIdentifier: snapshotIdentifier) else { return }
            timeline = refreshedTimeline
            channels = snapshot.channels
            hasUsableGuide = true
            loadState = .loaded(serverName: snapshot.serverName, channelCount: snapshot.channels.count)
            lastConfiguration = configuration
            lastLoadedAt = date

            let persistedSnapshot = PersistedGuideSnapshot(
                serverIdentifier: snapshotIdentifier,
                channelPreferencesIdentifier: configuration.channelPreferencesIdentifier,
                serverName: snapshot.serverName,
                savedAt: date,
                channels: snapshot.channels
            )
            await GuideSnapshotStore.shared.save(persistedSnapshot)
        } catch {
            // URLSession reports cancellation as URLError.cancelled rather
            // than Swift.CancellationError. Startup discovery can supersede
            // the first refresh, so neither form should briefly replace a
            // cached programme description with an error message.
            guard !Task.isCancelled, !Self.isCancellation(error) else { return }
            guard isCurrentLoad(generation, snapshotIdentifier: snapshotIdentifier) else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isCancellation(underlying)
        }
        return false
    }

    private func isCurrentLoad(_ generation: Int, snapshotIdentifier: String) -> Bool {
        generation == loadGeneration && activeSnapshotIdentifier == snapshotIdentifier
    }

    private func cancelActiveLoad() {
        guard let loadTask else { return }
        loadGeneration &+= 1
        loadTask.cancel()
        self.loadTask = nil
    }

    func program(withID id: GuideProgram.ID?) -> GuideProgram? {
        guard let id else { return nil }
        return programByID[id]
    }

    func channel(containing program: GuideProgram?) -> GuideChannel? {
        guard let program else { return nil }
        return channelByID[program.channelID]
    }

    var firstCurrentProgram: GuideProgram? {
        channels.lazy.flatMap(\.programs).first { $0.isAiring(at: now) }
    }

    var preferredInitialProgram: GuideProgram? {
        GuideFocusSelection.initialProgram(
            in: channels.first?.programs ?? [],
            at: now
        )
    }

    var isColdLoading: Bool {
        !hasUsableGuide && loadState == .loading
    }

    private func rebuildGuideIndexes() {
        channelByID = Dictionary(
            channels.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        programByID = Dictionary(
            channels.lazy.flatMap(\.programs).map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }
}

enum GuideFocusSelection {
    static func initialProgram(in programs: [GuideProgram], at date: Date) -> GuideProgram? {
        if let current = programs.first(where: { $0.isAiring(at: date) }) {
            return current
        }

        if let next = programs
            .filter({ $0.phase(at: date) == .future })
            .min(by: { $0.start < $1.start }) {
            return next
        }

        // A channel without current or future EPG data may only contain the
        // locally generated history placeholder. Prefer real metadata if any
        // remains, and otherwise allow normal focus resolution to take over.
        return programs.first { !$0.id.hasPrefix("earlier-") }
    }
}

enum PlaybackFocusSelection {
    static func channelID(
        in channels: [GuideChannel],
        selection: PlaybackNavigationSelection?
    ) -> GuideChannel.ID? {
        guard let selection,
              channels.contains(where: { $0.id == selection.channelID })
        else { return nil }
        return selection.channelID
    }

    static func programID(
        in channels: [GuideChannel],
        selection: PlaybackNavigationSelection?,
        at date: Date
    ) -> GuideProgram.ID? {
        guard let channelID = channelID(in: channels, selection: selection),
              let channel = channels.first(where: { $0.id == channelID }),
              let selection
        else { return nil }

        if let selectedProgram = channel.programs.first(where: { $0.id == selection.programID }),
           selectedProgram.isAiring(at: date) {
            return selectedProgram.id
        }

        if let currentProgram = channel.programs.first(where: { $0.isAiring(at: date) }) {
            return currentProgram.id
        }

        if let selectedProgram = channel.programs.first(where: { $0.id == selection.programID }) {
            return selectedProgram.id
        }

        return GuideFocusSelection.initialProgram(in: channel.programs, at: date)?.id
    }
}
