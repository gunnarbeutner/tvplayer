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
        if let xmltvURL = configuration.xmltvURL {
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
    func canonicalLiveStreamURL(channelID: String) async throws -> URL {
        let playlistURL = try endpointURL(
            path: "/playlist/ticket/channels",
            queryItems: [URLQueryItem(name: "profile", value: configuration.streamProfile)]
        )
        let data = try await fetchData(at: playlistURL)
        guard let playlist = String(data: data, encoding: .utf8),
              let streamURL = Self.streamURL(for: channelID, in: playlist)
        else { throw TVProviderError.channelNotInPlaylist }
        return streamURL
    }

    func serverVersion() async throws -> String {
        let info: TVHeadendServerInfo = try await get(path: "/api/serverinfo")
        return [info.name, info.version].compactMap { $0 }.joined(separator: " ")
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
                channelID: channelID,
                title: title,
                subtitle: event.subtitle,
                overview: event.description ?? event.summary ?? event.subtitle ?? "No programme description available.",
                start: start,
                end: end
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
