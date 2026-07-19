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
        var eventsByKey: [String: TVHeadendEPGEvent] = [:]
        for event in payload.eventsByServer[serverIdentifier, default: []] + freshEvents {
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

    private func key(for event: TVHeadendEPGEvent) -> String {
        if let eventID = event.eventID { return "event-\(eventID)" }
        return "\(event.channelUUID ?? "unknown")-\(event.start)"
    }
}
