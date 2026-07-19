@preconcurrency import Foundation
import SwiftUI

final class TVHeadendClient: NSObject, TVProvider, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: TVHeadendConfiguration
    private lazy var session: URLSession = {
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 20
        sessionConfiguration.timeoutIntervalForResource = 45
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
    }()

    init(configuration: TVHeadendConfiguration) {
        self.configuration = configuration
        super.init()
    }

    func fetchGuide(for timeline: GuideTimeline) async throws -> TVProviderSnapshot {
        guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }

        async let serverInfo: TVHeadendServerInfo = get(path: "/api/serverinfo")
        let channelGrid: TVHeadendGrid<TVHeadendChannel> = try await get(
            path: "/api/channel/grid",
            queryItems: [URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "limit", value: "10000")]
        )
        guard !channelGrid.entries.isEmpty else { throw TVProviderError.noChannels }

        let programmesByChannel: [String: [GuideProgram]]
        if let guideCacheURL = configuration.guideCacheURL {
            let data = try await fetchData(at: guideCacheURL)
            let document = try JSONDecoder().decode(TVPlayerGuideCacheDocument.self, from: data)
            guard document.version == 1 else { throw TVProviderError.invalidResponse }
            programmesByChannel = Self.mapEPG(document.events, timeline: timeline)
        } else if let xmltvURL = configuration.xmltvURL {
            let data = try await fetchData(at: xmltvURL)
            let document = try XMLTVParser.parse(data)
            programmesByChannel = Self.mapXMLTV(document, to: channelGrid.entries, timeline: timeline)
        } else {
            let epgGrid: TVHeadendGrid<TVHeadendEPGEvent> = try await get(
                path: "/api/epg/events/grid",
                queryItems: [URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "limit", value: "20000")]
            )
            let serverIdentifier = "\(configuration.baseURL?.absoluteString ?? "tvheadend")|\(configuration.username)"
            let events = await EPGHistoryStore.shared.merging(
                freshEvents: epgGrid.entries,
                serverIdentifier: serverIdentifier
            )
            programmesByChannel = Self.mapEPG(events, timeline: timeline)
        }

        let channels = channelGrid.entries
            .enumerated()
            .map { offset, channel in
                GuideChannel(
                    id: channel.uuid,
                    number: channel.number.map { Int($0.rounded()) } ?? offset + 1,
                    name: channel.name,
                    monogram: Self.monogram(for: channel.name),
                    tint: Self.tint(for: channel.uuid),
                    iconURL: Self.iconURL(for: channel, baseURL: configuration.baseURL),
                    programs: Self.programsFillingPastGap(
                        programmesByChannel[channel.uuid, default: []],
                        channelID: channel.uuid,
                        timeline: timeline
                    )
                )
            }
            .sorted {
                if $0.number == $1.number {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.number < $1.number
            }

        let info = try await serverInfo
        return TVProviderSnapshot(channels: channels, serverName: info.name ?? "TVHeadend")
    }

    func liveStreamURL(channelID: String) throws -> URL {
        try endpointURL(
            path: "/stream/channel/\(channelID)",
            queryItems: [URLQueryItem(name: "profile", value: configuration.streamProfile)]
        )
    }

    /// Uses TVHeadend's ticketed playlist because it contains both the server's
    /// canonical numeric `channelid` stream path and a short-lived credential.
    /// VLC can then open the stream without having to implement TVHeadend's
    /// Digest authentication flow itself.
    func canonicalLiveStreamURL(channelID: String, profile: String? = nil) async throws -> URL {
        let playlistURL = try endpointURL(
            path: "/playlist/ticket/channels",
            queryItems: [URLQueryItem(name: "profile", value: profile ?? configuration.streamProfile)]
        )
        let data = try await fetchData(at: playlistURL)
        guard let playlist = String(data: data, encoding: .utf8),
              let streamURL = Self.streamURL(for: channelID, in: playlist)
        else { throw TVProviderError.channelNotInPlaylist }
        return streamURL
    }

    func streamProfiles() async throws -> [TVHeadendStreamProfile] {
        let result: TVHeadendGrid<TVHeadendStreamProfile> = try await get(path: "/api/profile/list")
        return result.entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func serverVersion() async throws -> String {
        let info: TVHeadendServerInfo = try await get(path: "/api/serverinfo")
        return [info.name, info.version].compactMap { $0 }.joined(separator: " ")
    }

    func fetchRecordings() async throws -> TVRecordingSnapshot {
        guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }

        // TVheadend's convenience grids are not exhaustive. In particular,
        // some versions omit completedError and completedRerecord entries from
        // grid_failed as well as from the finished grid. The complete grid is
        // the only reliable source for everything the user has scheduled.
        async let recordingGrid: TVHeadendGrid<TVHeadendDVREntry> = get(
            path: "/api/dvr/entry/grid",
            queryItems: Self.fullGridQuery
        )
        async let autorecGrid: TVHeadendGrid<TVHeadendAutorecEntry> = get(
            path: "/api/dvr/autorec/grid",
            queryItems: Self.fullGridQuery
        )

        let (recordingEntries, autorecs) = try await (
            recordingGrid,
            autorecGrid
        )

        let now = Date()
        let recordings = recordingEntries.entries.map {
            Self.recording(from: $0, state: Self.recordingState(for: $0, at: now))
        }
        .filter { $0.state != .removed }
        .sorted {
            if $0.state == $1.state { return $0.start > $1.start }
            return Self.recordingStateOrder($0.state) < Self.recordingStateOrder($1.state)
        }
        let rules = autorecs.entries.map {
            TVRecordingRule(
                id: $0.uuid,
                name: $0.name ?? $0.title ?? "Record All",
                titlePattern: $0.title ?? "",
                channelID: $0.channelUUID,
                channelName: $0.channelName,
                seriesLink: $0.seriesLink,
                enabled: $0.enabled ?? true
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return TVRecordingSnapshot(entries: recordings, rules: rules)
    }

    func recordOnce(_ program: GuideProgram) async throws {
        if let eventID = program.providerEventID {
            try await postForm(
                path: "/api/dvr/entry/create_by_event",
                parameters: [
                    "event_id": String(eventID),
                    // Empty means the requesting user's default DVR profile.
                    "config_uuid": "",
                ]
            )
            return
        }

        let configuration: [String: Any] = [
            "enabled": true,
            "start": Int64(program.start.timeIntervalSince1970),
            "stop": Int64(program.end.timeIntervalSince1970),
            "channel": program.channelID,
            "disp_title": program.title,
            "disp_subtitle": program.subtitle ?? "",
            "disp_extratext": program.overview,
            "description": ["und": program.overview],
            // Empty means the requesting user's default DVR profile.
            "config_name": "",
        ]
        try await postJSONConfiguration(path: "/api/dvr/entry/create", configuration: configuration)
    }

    func recordAll(_ program: GuideProgram) async throws {
        if program.seriesLink?.isEmpty == false, let eventID = program.providerEventID {
            do {
                try await postForm(
                    path: "/api/dvr/autorec/create_by_series",
                    parameters: [
                        "event_id": String(eventID),
                        "config_uuid": "",
                    ]
                )
                return
            } catch let TVProviderError.httpStatus(status) where status == 400 || status == 404 {
                // Some grabbers expose a series URI that the installed
                // TVheadend version cannot turn into an autorec. Preserve the
                // user action with the exact-title/channel fallback below.
            }
        }

        let escapedTitle = NSRegularExpression.escapedPattern(for: program.title)
        let configuration: [String: Any] = [
            "enabled": true,
            "name": program.title,
            "title": "^\(escapedTitle)$",
            "channel": program.channelID,
            "config_name": "",
        ]
        try await postJSONConfiguration(path: "/api/dvr/autorec/create", configuration: configuration)
    }

    func cancelRecording(id: String) async throws {
        try await postForm(path: "/api/dvr/entry/cancel", parameters: ["uuid": Self.uuidList(id)])
    }

    func stopRecording(id: String) async throws {
        try await postForm(path: "/api/dvr/entry/stop", parameters: ["uuid": Self.uuidList(id)])
    }

    func deleteRecording(id: String) async throws {
        try await postForm(path: "/api/dvr/entry/remove", parameters: ["uuid": Self.uuidList(id)])
    }

    func deleteRecordingRule(id: String) async throws {
        try await postForm(path: "/api/idnode/delete", parameters: ["uuid": Self.uuidList(id)])
    }

    func recordingStreamURL(recordingID: String) async throws -> URL {
        do {
            let data = try await fetchData(
                at: endpointURL(path: "/play/ticket/dvrfile/\(recordingID)")
            )
            if let url = Self.firstMediaURL(in: data) { return url }
        } catch let TVProviderError.httpStatus(status) where status == 400 || status == 404 {
            // Older TVheadend versions only expose the aggregate playlist.
        }

        let data = try await fetchData(at: endpointURL(path: "/playlist/ticket/recordings"))
        guard let playlist = String(data: data, encoding: .utf8) else {
            throw TVProviderError.invalidResponse
        }
        let recordingPath = "/dvrfile/\(recordingID)"
        for rawLine in playlist.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("#"),
                  let url = URL(string: line),
                  url.path.contains(recordingPath)
            else { continue }
            return url
        }
        throw TVProviderError.channelNotInPlaylist
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let supported = [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate,
        ]

        guard supported.contains(method), challenge.previousFailureCount == 0 else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(
            .useCredential,
            URLCredential(
                user: configuration.username,
                password: configuration.password,
                persistence: .forSession
            )
        )
    }

    private func get<Value: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Value {
        let data = try await fetchData(at: endpointURL(path: path, queryItems: queryItems))
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func postJSONConfiguration(path: String, configuration: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: configuration)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TVProviderError.invalidResponse
        }
        try await postForm(path: path, parameters: ["conf": json])
    }

    private func postForm(path: String, parameters: [String: String]) async throws {
        var request = URLRequest(url: try endpointURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TVProviderError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw TVProviderError.httpStatus(response.statusCode)
        }
    }

    private func fetchData(at url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else { throw TVProviderError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw TVProviderError.httpStatus(response.statusCode)
        }
        return data
    }

    private func endpointURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard let baseURL = configuration.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { throw TVProviderError.invalidEndpoint }

        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw TVProviderError.invalidEndpoint }
        return url
    }

    private static func mapEPG(
        _ events: [TVHeadendEPGEvent],
        timeline: GuideTimeline
    ) -> [String: [GuideProgram]] {
        let programs = events.compactMap { event -> GuideProgram? in
            guard let channelID = event.channelUUID,
                  let title = event.title,
                  !title.isEmpty
            else { return nil }

            let start = Date(timeIntervalSince1970: TimeInterval(event.start))
            let end = Date(timeIntervalSince1970: TimeInterval(event.stop))
            guard end > timeline.start, start < timeline.end, end > start else { return nil }
            let id = event.eventID.map { String($0) } ?? "\(channelID)-\(event.start)"
            return GuideProgram(
                id: id,
                providerEventID: event.eventID,
                seriesLink: event.seriesLink,
                channelID: channelID,
                title: title,
                subtitle: event.subtitle,
                overview: event.description
                    ?? event.summary
                    ?? event.extraText
                    ?? event.subtitle
                    ?? "No programme description available.",
                start: start,
                end: end,
                metadata: GuideProgramMetadata(
                    episodeURI: event.episodeURI,
                    seasonNumber: event.seasonNumber,
                    episodeNumber: event.episodeNumber,
                    partNumber: event.partNumber,
                    genres: event.genres,
                    categories: event.categories,
                    ageRating: event.ageRating,
                    ratingLabel: event.ratingLabel,
                    ratingLabelIcon: event.ratingLabelIcon,
                    starRating: event.starRating,
                    imageURL: event.imageURL,
                    isHD: event.isHD,
                    isWidescreen: event.isWidescreen,
                    isSubtitled: event.isSubtitled,
                    isNew: event.isNew,
                    dvrUUID: event.dvrUUID,
                    dvrState: event.dvrState
                )
            )
        }
        return Dictionary(grouping: programs, by: \GuideProgram.channelID)
    }

    private static func mapXMLTV(
        _ document: XMLTVDocument,
        to channels: [TVHeadendChannel],
        timeline: GuideTimeline
    ) -> [String: [GuideProgram]] {
        let channelNames = Dictionary(uniqueKeysWithValues: document.channels.map {
            ($0.id, normalized($0.displayName))
        })

        var tvheadendIDByXMLTVID: [String: String] = [:]
        for channel in channels {
            let candidates = (channel.epggrab ?? []) + [channel.uuid]
            for candidate in candidates { tvheadendIDByXMLTVID[candidate] = channel.uuid }

            let normalizedName = normalized(channel.name)
            for (xmltvID, displayName) in channelNames where displayName == normalizedName {
                tvheadendIDByXMLTVID[xmltvID] = channel.uuid
            }
        }

        let programs = document.programmes.compactMap { programme -> GuideProgram? in
            guard let channelID = tvheadendIDByXMLTVID[programme.channelID],
                  programme.end > timeline.start,
                  programme.start < timeline.end
            else { return nil }

            return GuideProgram(
                id: "xmltv-\(programme.channelID)-\(Int(programme.start.timeIntervalSince1970))",
                channelID: channelID,
                title: programme.title,
                subtitle: programme.subtitle,
                overview: programme.description ?? programme.subtitle ?? "No programme description available.",
                start: programme.start,
                end: programme.end
            )
        }
        return Dictionary(grouping: programs, by: \GuideProgram.channelID)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func streamURL(for channelID: String, in playlist: String) -> URL? {
        var precedingChannelID: String?

        for rawLine in playlist.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                precedingChannelID = attribute(named: "tvg-id", in: line)
            } else if !line.hasPrefix("#"), precedingChannelID == channelID {
                return URL(string: line)
            }
        }
        return nil
    }

    private static func firstMediaURL(in data: Data) -> URL? {
        guard let playlist = String(data: data, encoding: .utf8) else { return nil }
        for rawLine in playlist.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.hasPrefix("#"), let url = URL(string: line) { return url }
        }
        return nil
    }

    private static func uuidList(_ id: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [id]),
              let result = String(data: data, encoding: .utf8)
        else { return "[\"\(id)\"]" }
        return result
    }

    private static let fullGridQuery = [
        URLQueryItem(name: "start", value: "0"),
        URLQueryItem(name: "limit", value: "10000"),
    ]

    private static func recording(from entry: TVHeadendDVREntry, state: TVRecordingState) -> TVRecording {
        TVRecording(
            id: entry.uuid,
            eventID: entry.eventID,
            title: entry.displayTitle?.nonEmpty ?? "Untitled recording",
            subtitle: entry.displaySubtitle?.nonEmpty,
            overview: entry.displayDescription?.nonEmpty ?? "No recording description available.",
            channelID: entry.channelUUID?.nonEmpty,
            channelName: entry.channelName?.nonEmpty ?? "Unknown channel",
            start: Date(timeIntervalSince1970: TimeInterval(entry.start)),
            end: Date(timeIntervalSince1970: TimeInterval(entry.stop)),
            state: state,
            statusText: entry.status?.nonEmpty,
            fileSize: entry.fileSize,
            errorCount: entry.errors,
            dataErrorCount: entry.dataErrors,
            autorecID: entry.autorecUUID?.nonEmpty,
            streamPath: entry.url?.nonEmpty
        )
    }

    static func recordingState(for entry: TVHeadendDVREntry, at now: Date) -> TVRecordingState {
        let scheduleStatus = entry.scheduleStatus?.lowercased() ?? ""
        let status = entry.status?.lowercased() ?? ""

        if scheduleStatus.contains("removed") {
            return .removed
        }
        if scheduleStatus.contains("completed") {
            let failedCompletion = scheduleStatus.contains("error")
                || scheduleStatus.contains("rerecord")
                || status.contains("missing")
                || status.contains("missed")
                || status.contains("failed")
            return failedCompletion ? .failed : .completed
        }
        if scheduleStatus.contains("recording") || status == "recording" {
            return .recording
        }
        if scheduleStatus.contains("scheduled") || entry.start > Int64(now.timeIntervalSince1970) {
            return .upcoming
        }
        if scheduleStatus.contains("error")
            || scheduleStatus.contains("failed")
            || status.contains("missing")
            || status.contains("missed")
            || status.contains("failed") {
            return .failed
        }

        let hasRecordingFile = entry.fileSize > 0 || entry.url?.nonEmpty != nil
        return hasRecordingFile ? .completed : .failed
    }

    private static func recordingStateOrder(_ state: TVRecordingState) -> Int {
        switch state {
        case .recording: 0
        case .upcoming: 1
        case .completed: 2
        case .failed: 3
        case .removed: 4
        }
    }

    private static func attribute(named name: String, in line: String) -> String? {
        let marker = "\(name)=\""
        guard let start = line.range(of: marker)?.upperBound,
              let end = line[start...].firstIndex(of: "\"")
        else { return nil }
        return String(line[start..<end])
    }

    private static func programsFillingPastGap(
        _ programs: [GuideProgram],
        channelID: String,
        timeline: GuideTimeline,
        now: Date = Date()
    ) -> [GuideProgram] {
        let sorted = programs.sorted { $0.start < $1.start }
        guard timeline.start < now else { return sorted }

        let firstStart = sorted.first?.start ?? now
        let gapEnd = min(min(firstStart, now), timeline.end)
        guard gapEnd.timeIntervalSince(timeline.start) > 120 else { return sorted }

        let placeholder = GuideProgram(
            id: "earlier-\(channelID)-\(Int(timeline.start.timeIntervalSince1970))",
            channelID: channelID,
            title: "Earlier programme",
            subtitle: "Guide history unavailable",
            overview: "TVHeadend removes finished EPG events. TV Guide will retain programme names locally after it has observed them.",
            start: timeline.start,
            end: gapEnd
        )
        return [placeholder] + sorted
    }

    private static func monogram(for name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." })
        if words.count >= 2 {
            return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private static func tint(for identifier: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .teal, .cyan]
        let value = identifier.unicodeScalars.reduce(0) {
            ($0 &* 31 &+ Int($1.value)) & 0x7fffffff
        }
        return palette[value % palette.count]
    }

    private static func iconURL(for channel: TVHeadendChannel, baseURL: URL?) -> URL? {
        guard let value = channel.iconPublicURL ?? channel.icon, !value.isEmpty else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return baseURL?.appending(path: value.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
