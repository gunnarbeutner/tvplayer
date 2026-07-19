import Foundation

enum GuideLoadState: Equatable {
    case preview
    case needsConfiguration
    case loading
    case loaded(serverName: String, channelCount: Int)
    case failed(String)
}

@MainActor
final class GuideViewModel: ObservableObject {
    @Published private(set) var now: Date
    @Published private(set) var timeline: GuideTimeline
    @Published private(set) var channels: [GuideChannel]
    @Published private(set) var loadState: GuideLoadState = .preview

    private var lastConfiguration: TVHeadendConfiguration?
    private var lastLoadedAt: Date?
    private var isLoading = false

    private static let refreshInterval: TimeInterval = 120

    init(now: Date = Date()) {
        let timeline = GuideTimeline.surrounding(now)
        self.now = now
        self.timeline = timeline
        channels = SampleGuideData.channels(for: timeline)
    }

    func tick(at date: Date = Date()) {
        now = date
    }

    func refreshWindow(at date: Date = Date()) {
        let refreshedTimeline = GuideTimeline.surrounding(date)
        now = date
        timeline = refreshedTimeline
        if case .preview = loadState {
            channels = SampleGuideData.channels(for: refreshedTimeline)
        }
    }

    func load(
        configuration: TVHeadendConfiguration,
        at date: Date = Date(),
        force: Bool = false
    ) async {
        let refreshedTimeline = GuideTimeline.surrounding(date)
        now = date

        guard configuration.isComplete else {
            timeline = refreshedTimeline
            channels = SampleGuideData.channels(for: refreshedTimeline)
            loadState = .needsConfiguration
            lastConfiguration = nil
            lastLoadedAt = nil
            return
        }

        let isFresh = lastConfiguration == configuration
            && lastLoadedAt.map { date.timeIntervalSince($0) < Self.refreshInterval } == true
        guard force || !isFresh else { return }
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        if lastLoadedAt == nil {
            loadState = .loading
        }
        do {
            let snapshot = try await TVHeadendClient(configuration: configuration)
                .fetchGuide(for: refreshedTimeline)
            try Task.checkCancellation()
            timeline = refreshedTimeline
            channels = snapshot.channels
            loadState = .loaded(serverName: snapshot.serverName, channelCount: snapshot.channels.count)
            lastConfiguration = configuration
            lastLoadedAt = date
        } catch is CancellationError {
            return
        } catch {
            if channels.isEmpty {
                channels = SampleGuideData.channels(for: refreshedTimeline)
            }
            loadState = .failed(error.localizedDescription)
        }
    }

    func program(withID id: GuideProgram.ID?) -> GuideProgram? {
        guard let id else { return nil }
        return channels.lazy.flatMap(\.programs).first { $0.id == id }
    }

    func channel(containing program: GuideProgram?) -> GuideChannel? {
        guard let program else { return nil }
        return channels.first { $0.id == program.channelID }
    }

    var firstCurrentProgram: GuideProgram? {
        channels.lazy.flatMap(\.programs).first { $0.isAiring(at: now) }
    }
}
