import Foundation

enum GuideLoadState: Equatable {
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
    @Published private(set) var loadState: GuideLoadState = .needsConfiguration

    private var lastConfiguration: TVHeadendConfiguration?
    private var lastLoadedAt: Date?
    private var isLoading = false

    private static let refreshInterval: TimeInterval = 120

    init(now: Date = Date()) {
        let timeline = GuideTimeline.surrounding(now)
        self.now = now
        self.timeline = timeline
        channels = []
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
            timeline = refreshedTimeline
            channels = []
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

    var preferredInitialProgram: GuideProgram? {
        GuideFocusSelection.initialProgram(
            in: channels.first?.programs ?? [],
            at: now
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
