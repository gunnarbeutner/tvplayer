import Foundation

enum RecordingLoadState: Equatable {
    case needsConfiguration
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [TVRecording] = []
    @Published private(set) var rules: [TVRecordingRule] = []
    @Published private(set) var loadState: RecordingLoadState = .needsConfiguration
    @Published private(set) var performingActions: Set<String> = []
    @Published var errorMessage: String?

    private var lastConfiguration: TVHeadendConfiguration?
    private var lastLoadedAt: Date?
    private var isLoading = false

    var recordingNow: [TVRecording] {
        recordings.filter { $0.state == .recording }.sorted { $0.start < $1.start }
    }

    var upcoming: [TVRecording] {
        recordings.filter { $0.state == .upcoming }.sorted { $0.start < $1.start }
    }

    var completed: [TVRecording] {
        recordings.filter { $0.state == .completed }.sorted { $0.start > $1.start }
    }

    var failed: [TVRecording] {
        recordings.filter { $0.state == .failed }.sorted { $0.start > $1.start }
    }

    var recommendedRefreshInterval: Duration {
        recordingNow.isEmpty ? .seconds(60) : .seconds(30)
    }

    func load(
        configuration: TVHeadendConfiguration,
        at date: Date = Date(),
        force: Bool = false
    ) async {
        guard configuration.isComplete else {
            recordings = []
            rules = []
            loadState = .needsConfiguration
            lastConfiguration = nil
            lastLoadedAt = nil
            return
        }

        let interval: TimeInterval = recordingNow.isEmpty ? 60 : 30
        let isFresh = lastConfiguration == configuration
            && lastLoadedAt.map { date.timeIntervalSince($0) < interval } == true
        guard force || !isFresh else { return }

        if isLoading {
            // An action-triggered refresh must not be discarded just because
            // the periodic background refresh is still in flight. Wait for
            // that request and then fetch the post-action state explicitly.
            guard force else { return }
            while isLoading, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            await load(configuration: configuration, at: date, force: true)
            return
        }

        isLoading = true
        if lastLoadedAt == nil { loadState = .loading }
        defer { isLoading = false }

        do {
            let snapshot = try await TVHeadendClient(configuration: configuration).fetchRecordings()
            try Task.checkCancellation()
            recordings = snapshot.entries
            rules = snapshot.rules
            loadState = .loaded
            lastConfiguration = configuration
            lastLoadedAt = date
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func recording(for program: GuideProgram) -> TVRecording? {
        if let eventID = program.providerEventID,
           let exact = recordings.first(where: { $0.eventID == eventID }) {
            return exact
        }

        return recordings.first {
            guard $0.channelID == program.channelID else { return false }
            let startsTogether = abs($0.start.timeIntervalSince(program.start)) < 120
            let overlaps = $0.start < program.end && program.start < $0.end
            return startsTogether || ($0.title == program.title && overlaps)
        }
    }

    func scheduledRecording(for program: GuideProgram) -> TVRecording? {
        guard let recording = recording(for: program),
              recording.state == .upcoming || recording.state == .recording
        else { return nil }
        return recording
    }

    func hasRecordAllRule(for program: GuideProgram) -> Bool {
        rules.contains { rule in
            if let seriesLink = program.seriesLink, !seriesLink.isEmpty,
               rule.seriesLink == seriesLink {
                return true
            }
            let sameChannel = rule.channelID == nil || rule.channelID == program.channelID
            return sameChannel && rule.name.localizedCaseInsensitiveCompare(program.title) == .orderedSame
        }
    }

    func recordOnce(_ program: GuideProgram, configuration: TVHeadendConfiguration) async {
        await perform(key: "program:\(program.id)", configuration: configuration) { client in
            try await client.recordOnce(program)
        }
        if let recording = recording(for: program), recording.state == .failed {
            let reason = recording.statusText?.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = if let reason, !reason.isEmpty {
                "TVheadend could not record this programme: \(reason)."
            } else {
                "TVheadend could not record this programme. Check its DVR configuration and recording directory."
            }
        }
    }

    func recordAll(_ program: GuideProgram, configuration: TVHeadendConfiguration) async {
        await perform(key: "series:\(program.id)", configuration: configuration) { client in
            try await client.recordAll(program)
        }
    }

    func cancel(_ recording: TVRecording, configuration: TVHeadendConfiguration) async {
        await perform(key: recording.id, configuration: configuration) { client in
            try await client.cancelRecording(id: recording.id)
        }
    }

    func stop(_ recording: TVRecording, configuration: TVHeadendConfiguration) async {
        await perform(key: recording.id, configuration: configuration) { client in
            try await client.stopRecording(id: recording.id)
        }
    }

    func delete(_ recording: TVRecording, configuration: TVHeadendConfiguration) async {
        await perform(key: recording.id, configuration: configuration) { client in
            try await client.deleteRecording(id: recording.id)
        }
    }

    func delete(_ rule: TVRecordingRule, configuration: TVHeadendConfiguration) async {
        await perform(key: rule.id, configuration: configuration) { client in
            try await client.deleteRecordingRule(id: rule.id)
        }
    }

    func isPerforming(_ key: String) -> Bool {
        performingActions.contains(key)
    }

    private func perform(
        key: String,
        configuration: TVHeadendConfiguration,
        operation: (TVHeadendClient) async throws -> Void
    ) async {
        guard !performingActions.contains(key) else { return }
        guard configuration.isComplete else {
            errorMessage = TVProviderError.incompleteConfiguration.localizedDescription
            return
        }

        performingActions.insert(key)
        defer { performingActions.remove(key) }
        do {
            try await operation(TVHeadendClient(configuration: configuration))
            await load(configuration: configuration, force: true)
        } catch {
            errorMessage = error.localizedDescription
            await load(configuration: configuration, force: true)
        }
    }
}
