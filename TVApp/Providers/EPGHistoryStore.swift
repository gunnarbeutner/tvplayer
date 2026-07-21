import Foundation

/// TVHeadend removes EPG events as soon as they finish. Keeping previously
/// observed events locally lets the guide retain useful recent history.
actor EPGHistoryStore {
    static let shared = EPGHistoryStore()

    private struct Payload: Codable {
        var eventsByServer: [String: [TVHeadendEPGEvent]] = [:]
    }

    private let fileURL: URL?
    private var payload: Payload

    private init() {
        fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appending(path: "tvplayer-epg-history.json")

        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = decoded
        } else {
            payload = Payload()
        }
    }

    func merging(
        freshEvents: [TVHeadendEPGEvent],
        serverIdentifier: String,
        now: Date = Date()
    ) -> [TVHeadendEPGEvent] {
        let cachedEvents = payload.eventsByServer[serverIdentifier, default: []]
        let retainedHistory = Self.retainedCachedEvents(
            cachedEvents,
            freshEvents: freshEvents,
            now: now
        )

        var eventsByKey: [String: TVHeadendEPGEvent] = [:]
        for event in retainedHistory + freshEvents {
            eventsByKey[key(for: event)] = event
        }

        let oldest = Int64(now.addingTimeInterval(-21_600).timeIntervalSince1970)
        let newest = Int64(now.addingTimeInterval(172_800).timeIntervalSince1970)
        let retained = eventsByKey.values
            .filter { $0.stop > oldest && $0.start < newest }
            .sorted { $0.start < $1.start }

        payload.eventsByServer[serverIdentifier] = retained
        if let fileURL,
           let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return retained
    }

    static func retainedCachedEvents(
        _ cachedEvents: [TVHeadendEPGEvent],
        freshEvents: [TVHeadendEPGEvent],
        now: Date
    ) -> [TVHeadendEPGEvent] {
        let freshEventIDs = Set(freshEvents.compactMap(\.eventID))
        let freshBroadcastKeys = Set(freshEvents.map(broadcastKey(for:)))
        let nowTimestamp = Int64(now.timeIntervalSince1970)

        return cachedEvents.filter { cached in
            // A successful fetch is authoritative for current and future
            // events. Retain an absent event only after it has ended, when
            // TVHeadend normally removes it from the live EPG response.
            guard cached.stop <= nowTimestamp else { return false }
            if let eventID = cached.eventID, freshEventIDs.contains(eventID) {
                return false
            }
            return !freshBroadcastKeys.contains(broadcastKey(for: cached))
        }
    }

    private func key(for event: TVHeadendEPGEvent) -> String {
        if let eventID = event.eventID { return "event-\(eventID)" }
        return "\(event.channelUUID ?? "unknown")-\(event.start)"
    }

    /// Identifies the same broadcast slot independent of TVHeadend's event
    /// id. Start times for the same broadcast have been observed to drift
    /// by a few seconds between grabber runs, so this rounds to the
    /// nearest minute.
    private static func broadcastKey(for event: TVHeadendEPGEvent) -> String {
        let roundedStart = Int64((Double(event.start) / 60).rounded()) * 60
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "\(event.channelUUID ?? "unknown")-\(title)-\(roundedStart)"
    }
}
