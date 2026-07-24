@preconcurrency import Foundation
import SwiftUI

struct TVHeadendPlaylistChannel: Equatable, Sendable {
    let id: UInt32
    let name: String
    let playlistID: String?

    init(id: UInt32, name: String, playlistID: String? = nil) {
        self.id = id
        self.name = name
        self.playlistID = playlistID
    }
}

final class TVHeadendClient: TVProvider, @unchecked Sendable {
    private let configuration: TVHeadendConfiguration
    private let serverCapabilitiesCache = TVHeadendServerCapabilitiesCache()
    private let ticketedPlaylistCache = TVHeadendTicketedPlaylistCache()
    private let session: URLSession

    init(
        configuration: TVHeadendConfiguration,
        sessionConfiguration urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.configuration = configuration
        let sessionConfiguration = urlSessionConfiguration.copy() as! URLSessionConfiguration
        sessionConfiguration.timeoutIntervalForRequest = 20
        sessionConfiguration.timeoutIntervalForResource = 45
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        CachedAddressProxy.shared.configure(sessionConfiguration, for: configuration)
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: TVHeadendHTTPAuthenticationDelegate(configuration: configuration),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func fetchGuide(for timeline: GuideTimeline) async throws -> TVProviderSnapshot {
        try await fetchGuide(for: timeline, channelUpdate: nil)
    }

    func fetchGuide(
        for timeline: GuideTimeline,
        channelUpdate: (@MainActor @Sendable ([GuideChannel]) -> Void)?
    ) async throws -> TVProviderSnapshot {
        guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }

        async let serverInfo: TVHeadendServerInfo = get(path: "/api/serverinfo")
        let channelGrid: TVHeadendGrid<TVHeadendChannel> = try await get(
            path: "/api/channel/grid",
            queryItems: [URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "limit", value: "10000")]
        )
        guard !channelGrid.entries.isEmpty else { throw TVProviderError.noChannels }

        if let channelUpdate {
            let channelShells = Self.makeChannels(
                from: channelGrid.entries,
                programsByChannel: [:],
                timeline: timeline,
                fillPastGap: false,
                baseURL: configuration.baseURL
            )
            await channelUpdate(channelShells)
        }

        let programmesByChannel: [String: [GuideProgram]]
        if let guideCacheURL = configuration.guideCacheURL {
            let data = try await fetchConditionalGuideData(at: guideCacheURL)
            let document = try JSONDecoder().decode(TVPlayerGuideCacheDocument.self, from: data)
            guard document.version == 1 else { throw TVProviderError.invalidResponse }
            programmesByChannel = Self.mapEPG(
                document.events,
                timeline: timeline,
                artworkBaseURL: configuration.baseURL
            )
        } else if let xmltvURL = configuration.xmltvURL {
            let data = try await fetchData(at: xmltvURL)
            let document = try XMLTVParser.parse(data)
            programmesByChannel = Self.mapXMLTV(
                document,
                to: channelGrid.entries,
                timeline: timeline,
                sourceURL: configuration.xmltvURL
            )
        } else {
            let epgGrid: TVHeadendGrid<TVHeadendEPGEvent> = try await get(
                path: "/api/epg/events/grid",
                queryItems: [URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "limit", value: "20000")]
            )
            let serverIdentifier = configuration.dataStoreIdentifier
            let events = await EPGHistoryStore.shared.merging(
                freshEvents: epgGrid.entries,
                serverIdentifier: serverIdentifier
            )
            programmesByChannel = Self.mapEPG(
                events,
                timeline: timeline,
                artworkBaseURL: configuration.baseURL
            )
        }

        let channels = Self.makeChannels(
            from: channelGrid.entries,
            programsByChannel: programmesByChannel,
            timeline: timeline,
            fillPastGap: true,
            baseURL: configuration.baseURL
        )

        let info = try await serverInfo
        return TVProviderSnapshot(channels: channels, serverName: info.name ?? "TVHeadend")
    }

    private static func makeChannels(
        from entries: [TVHeadendChannel],
        programsByChannel: [String: [GuideProgram]],
        timeline: GuideTimeline,
        fillPastGap: Bool,
        baseURL: URL?
    ) -> [GuideChannel] {
        entries
            .enumerated()
            .map { offset, channel in
                GuideChannel(
                    id: channel.uuid,
                    number: channel.number.map { Int($0.rounded()) } ?? offset + 1,
                    name: channel.name,
                    monogram: GuideChannelAppearance.monogram(for: channel.name),
                    tint: GuideChannelAppearance.tint(for: channel.uuid),
                    iconURL: Self.iconURL(for: channel, baseURL: baseURL),
                    programs: fillPastGap
                        ? Self.programsFillingPastGap(
                            programsByChannel[channel.uuid, default: []],
                            channelID: channel.uuid,
                            timeline: timeline
                        )
                        : []
                )
            }
            .sorted {
                if $0.number == $1.number {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.number < $1.number
            }
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
        let selectedProfile = profile ?? configuration.streamProfile
        let playlistURL = try endpointURL(
            path: "/playlist/ticket/channels",
            queryItems: [URLQueryItem(name: "profile", value: selectedProfile)]
        )
        let streamURLs = try await ticketedPlaylistCache.streamURLs(for: selectedProfile) { [self] in
            let data = try await fetchData(at: playlistURL)
            guard let playlist = String(data: data, encoding: .utf8) else {
                throw TVProviderError.invalidResponse
            }
            return Self.streamURLs(in: playlist)
        }
        guard let streamURL = streamURLs[channelID]
        else { throw TVProviderError.channelNotInPlaylist }
        return streamURL
    }

    func ticketedChannels(profile: String? = nil) async throws -> [TVHeadendPlaylistChannel] {
        let selectedProfile = profile ?? configuration.streamProfile
        let playlistURL = try endpointURL(
            path: "/playlist/ticket/channels",
            queryItems: [URLQueryItem(name: "profile", value: selectedProfile)]
        )
        let data = try await fetchData(at: playlistURL)
        guard let playlist = String(data: data, encoding: .utf8) else {
            throw TVProviderError.invalidResponse
        }
        return Self.playlistChannels(in: playlist)
    }

    func streamProfiles() async throws -> [TVHeadendStreamProfile] {
        let result: TVHeadendGrid<TVHeadendStreamProfile> = try await get(path: "/api/profile/list")
        return result.entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func serverVersion() async throws -> String {
        let info = try await serverInfo()
        return [info.name, info.version].compactMap { $0 }.joined(separator: " ")
    }

    func serverInfo() async throws -> TVHeadendServerInfo {
        try await get(path: "/api/serverinfo")
    }

    func livePlaybackRequest(
        channelID: String,
        profile: String? = nil,
        networkCachingMilliseconds: Int = 1_500
    ) async throws -> LiveStreamRequest {
        let selectedProfile = profile ?? configuration.streamProfile
        if let replay = TVPlaybackAutomation.livePlaybackRequest(
            channelID: channelID,
            configuration: configuration,
            profile: selectedProfile,
            networkCachingMilliseconds: networkCachingMilliseconds
        ) {
            return replay
        }
        async let pendingURL = canonicalLiveStreamURL(
            channelID: channelID,
            profile: selectedProfile
        )
        async let pendingCapabilities = cachedServerCapabilities()

        let url = try await pendingURL
        let capabilities = try? await pendingCapabilities
        let mode: LivePlaybackMode
        if capabilities?.contains("timeshift") == true {
            if let numericChannelID = Self.numericChannelID(from: url) {
                mode = .nativeTimeshift(
                    HTSPPlaybackConfiguration(
                        configuration: configuration,
                        channelID: numericChannelID
                    )
                )
            } else {
                mode = .liveOnly(reason: "TVHeadend did not provide an HTSP channel identifier")
            }
        } else {
            mode = .liveOnly(reason: "Native timeshift is disabled on TVHeadend")
        }
        return LiveStreamRequest(
            url: url,
            networkCachingMilliseconds: networkCachingMilliseconds,
            profile: selectedProfile,
            kind: .live(mode)
        )
    }

    private func cachedServerCapabilities() async throws -> Set<String> {
        try await serverCapabilitiesCache.capabilities(using: self)
    }

    static func numericChannelID(from url: URL) -> UInt32? {
        let components = url.pathComponents
        guard let marker = components.firstIndex(of: "channelid"),
              components.indices.contains(marker + 1)
        else { return nil }
        return UInt32(components[marker + 1])
    }

    /// Loads artwork exposed by TVHeadend's protected `/imagecache` endpoint.
    /// `AsyncImage` uses the shared URL session and cannot answer TVHeadend's
    /// authentication challenge, so channel badges must use the client's
    /// credential-aware session instead.
    func fetchChannelIcon(at url: URL) async throws -> Data {
        if Self.hasSameOrigin(url, configuration.baseURL) {
            return try await fetchData(at: url)
        }

        // TVHeadend may advertise an externally hosted public icon. Do not
        // offer the server password to authentication challenges from a
        // different origin.
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw TVProviderError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TVProviderError.httpStatus(response.statusCode)
        }
        return data
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

    private func fetchConditionalGuideData(at url: URL) async throws -> Data {
        let cached = await GuideHTTPResponseCache.shared.response(for: url)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let cached {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TVProviderError.invalidResponse
        }

        if response.statusCode == 304 {
            guard let cached else { throw TVProviderError.invalidResponse }
            return cached.data
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TVProviderError.httpStatus(response.statusCode)
        }

        await GuideHTTPResponseCache.shared.store(
            data: data,
            etag: response.value(forHTTPHeaderField: "ETag"),
            for: url
        )
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

    private static func hasSameOrigin(_ first: URL, _ second: URL?) -> Bool {
        guard let second else { return false }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased()
            && effectivePort(for: first) == effectivePort(for: second)
    }

    static func isServerProtectionSpace(
        _ protectionSpace: URLProtectionSpace,
        for configuration: TVHeadendConfiguration
    ) -> Bool {
        guard let baseURL = configuration.baseURL else { return false }
        return protectionSpace.protocol?.lowercased() == baseURL.scheme?.lowercased()
            && protectionSpace.host.lowercased() == baseURL.host?.lowercased()
            && protectionSpace.port == effectivePort(for: baseURL)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func mapEPG(
        _ events: [TVHeadendEPGEvent],
        timeline: GuideTimeline,
        artworkBaseURL: URL?
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
                    seasonCount: event.seasonCount,
                    episodeNumber: event.episodeNumber,
                    episodeCount: event.episodeCount,
                    episodeOnscreen: event.episodeOnscreen,
                    partNumber: event.partNumber,
                    partCount: event.partCount,
                    firstAired: event.firstAired,
                    genres: event.genres,
                    categories: event.categories,
                    summary: event.summary,
                    extraText: event.extraText,
                    ageRating: event.ageRating,
                    ratingLabel: event.ratingLabel,
                    ratingLabelIcon: event.ratingLabelIcon,
                    ratingCountry: event.ratingCountry,
                    ratingAuthority: event.ratingAuthority,
                    starRating: event.starRating,
                    imageURL: resolvedArtworkURLString(event.imageURL, relativeTo: artworkBaseURL),
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
        timeline: GuideTimeline,
        sourceURL: URL?
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
                end: programme.end,
                metadata: GuideProgramMetadata(
                    imageURL: resolvedArtworkURLString(
                        programme.imageURL,
                        relativeTo: sourceURL?.deletingLastPathComponent()
                    )
                )
            )
        }
        return Dictionary(grouping: programs, by: \GuideProgram.channelID)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func resolvedArtworkURLString(_ value: String?, relativeTo baseURL: URL?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        if let absoluteURL = URL(string: value), absoluteURL.scheme != nil {
            guard absoluteURL.scheme?.lowercased() == "http",
                  absoluteURL.host?.caseInsensitiveCompare(baseURL?.host ?? "") != .orderedSame,
                  var secureComponents = URLComponents(
                    url: absoluteURL,
                    resolvingAgainstBaseURL: false
                  )
            else { return absoluteURL.absoluteString }

            // XMLTV providers commonly publish artwork as plain HTTP even
            // when the same resource is available over HTTPS. External HTTP
            // is rejected by App Transport Security; same-origin TVHeadend
            // image-cache URLs remain HTTP so local authenticated servers
            // continue to work.
            secureComponents.scheme = "https"
            if secureComponents.port == 80 { secureComponents.port = nil }
            return secureComponents.url?.absoluteString ?? absoluteURL.absoluteString
        }
        return baseURL.flatMap {
            let directoryURL = $0.appendingPathComponent("")
            return URL(string: value, relativeTo: directoryURL)?.absoluteURL.absoluteString
        }
    }

    private static func streamURLs(in playlist: String) -> [String: URL] {
        var precedingChannelID: String?
        var result: [String: URL] = [:]

        for rawLine in playlist.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                precedingChannelID = attribute(named: "tvg-id", in: line)
            } else if !line.hasPrefix("#"),
                      let channelID = precedingChannelID,
                      let url = URL(string: line) {
                result[channelID] = url
                precedingChannelID = nil
            }
        }
        return result
    }

    static func playlistChannels(in playlist: String) -> [TVHeadendPlaylistChannel] {
        var name = "Live channel"
        var playlistID: String?
        var result: [TVHeadendPlaylistChannel] = []

        for rawLine in playlist.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                name = line.split(separator: ",", maxSplits: 1).last
                    .map(String.init) ?? name
                playlistID = attribute(named: "tvg-id", in: line)
            } else if !line.hasPrefix("#"),
                      let streamURL = URL(string: line),
                      let channelID = numericChannelID(from: streamURL) {
                result.append(TVHeadendPlaylistChannel(
                    id: channelID,
                    name: name,
                    playlistID: playlistID
                ))
                playlistID = nil
            }
        }
        return result
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
            warningText: Self.recordingWarning(for: entry, state: state),
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
        let hasRecordingFile = entry.fileSize > 0 || entry.url?.nonEmpty != nil

        if scheduleStatus.contains("removed") {
            return .removed
        }
        if scheduleStatus.contains("completed") {
            // completedError can describe a usable recording with a quality
            // warning (for example, TVHeadend's "Weak stream"). Likewise,
            // completedRerecord is the retained first copy after TVHeadend
            // requested another attempt. A real recording file is therefore
            // authoritative; these states must not make that file unplayable.
            if hasRecordingFile {
                return .completed
            }

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

        return hasRecordingFile ? .completed : .failed
    }

    static func recordingWarning(
        for entry: TVHeadendDVREntry,
        state: TVRecordingState
    ) -> String? {
        guard state == .completed else { return nil }

        let scheduleStatus = entry.scheduleStatus?.lowercased() ?? ""
        if scheduleStatus.contains("rerecord") {
            return "TVheadend requested a re-record because quality issues were detected."
        }
        if scheduleStatus.contains("error") {
            return entry.status?.nonEmpty ?? "TVheadend completed this recording with a warning."
        }
        return nil
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

    static func programsFillingPastGap(
        _ programs: [GuideProgram],
        channelID: String,
        timeline: GuideTimeline,
        now: Date = Date()
    ) -> [GuideProgram] {
        let sorted = programs.sorted { $0.start < $1.start }

        if sorted.isEmpty {
            return [GuideProgram(
                id: "unavailable-\(channelID)-\(Int(timeline.start.timeIntervalSince1970))",
                channelID: channelID,
                title: "No programme information",
                subtitle: "Guide data unavailable",
                overview: "No programme metadata is currently available for this channel.",
                start: timeline.start,
                end: timeline.end
            )]
        }

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

    private static func iconURL(for channel: TVHeadendChannel, baseURL: URL?) -> URL? {
        guard let value = channel.iconPublicURL ?? channel.icon, !value.isEmpty else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return baseURL?.appending(path: value.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

final class TVHeadendHTTPAuthenticationDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: TVHeadendConfiguration

    init(configuration: TVHeadendConfiguration) {
        self.configuration = configuration
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let supportedMethods = [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate,
        ]
        guard supportedMethods.contains(method), challenge.previousFailureCount == 0 else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard configuration.usesAuthentication else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard TVHeadendClient.isServerProtectionSpace(
            challenge.protectionSpace,
            for: configuration
        ) else {
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
}

private actor TVHeadendServerCapabilitiesCache {
    private var cachedCapabilities: Set<String>?
    private var loadTask: Task<Set<String>, Error>?

    func capabilities(using client: TVHeadendClient) async throws -> Set<String> {
        if let cachedCapabilities { return cachedCapabilities }
        if let loadTask { return try await loadTask.value }

        let task = Task {
            Set(try await client.serverInfo().capabilities)
        }
        loadTask = task

        do {
            let capabilities = try await task.value
            cachedCapabilities = capabilities
            loadTask = nil
            return capabilities
        } catch {
            loadTask = nil
            throw error
        }
    }
}

private actor TVHeadendTicketedPlaylistCache {
    private struct Entry {
        let streamURLs: [String: URL]
        let loadedAt: Date
    }

    private static let lifetime: TimeInterval = 8
    private var entriesByProfile: [String: Entry] = [:]
    private var loadTasksByProfile: [String: Task<[String: URL], Error>] = [:]

    func streamURLs(
        for profile: String,
        load: @escaping @Sendable () async throws -> [String: URL]
    ) async throws -> [String: URL] {
        if let entry = entriesByProfile[profile],
           Date().timeIntervalSince(entry.loadedAt) < Self.lifetime {
            return entry.streamURLs
        }
        if let task = loadTasksByProfile[profile] {
            return try await task.value
        }

        let task = Task { try await load() }
        loadTasksByProfile[profile] = task
        do {
            let streamURLs = try await task.value
            entriesByProfile[profile] = Entry(streamURLs: streamURLs, loadedAt: Date())
            loadTasksByProfile[profile] = nil
            return streamURLs
        } catch {
            loadTasksByProfile[profile] = nil
            throw error
        }
    }
}

private actor GuideHTTPResponseCache {
    struct Response: Sendable {
        let data: Data
        let etag: String
    }

    static let shared = GuideHTTPResponseCache()

    private var responses: [URL: Response] = [:]

    func response(for url: URL) -> Response? {
        responses[url]
    }

    func store(data: Data, etag: String?, for url: URL) {
        guard let etag, !etag.isEmpty else {
            responses[url] = nil
            return
        }
        responses[url] = Response(data: data, etag: etag)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
