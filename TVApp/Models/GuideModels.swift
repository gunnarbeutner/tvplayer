import Foundation
import SwiftUI

struct GuideChannel: Identifiable, Equatable, Sendable {
    let id: String
    let number: Int
    let name: String
    let monogram: String
    let tint: Color
    let iconURL: URL?
    let programs: [GuideProgram]
}

struct GuideProgramMetadata: Hashable, Codable, Sendable {
    let episodeURI: String?
    let seasonNumber: String?
    let episodeNumber: String?
    let partNumber: String?
    let genres: [Int]
    let categories: [String]
    let ageRating: String?
    let ratingLabel: String?
    let ratingLabelIcon: String?
    let starRating: String?
    let imageURL: String?
    let isHD: Bool
    let isWidescreen: Bool
    let isSubtitled: Bool
    let isNew: Bool
    let dvrUUID: String?
    let dvrState: String?

    init(
        episodeURI: String? = nil,
        seasonNumber: String? = nil,
        episodeNumber: String? = nil,
        partNumber: String? = nil,
        genres: [Int] = [],
        categories: [String] = [],
        ageRating: String? = nil,
        ratingLabel: String? = nil,
        ratingLabelIcon: String? = nil,
        starRating: String? = nil,
        imageURL: String? = nil,
        isHD: Bool = false,
        isWidescreen: Bool = false,
        isSubtitled: Bool = false,
        isNew: Bool = false,
        dvrUUID: String? = nil,
        dvrState: String? = nil
    ) {
        self.episodeURI = episodeURI
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.partNumber = partNumber
        self.genres = genres
        self.categories = categories
        self.ageRating = ageRating
        self.ratingLabel = ratingLabel
        self.ratingLabelIcon = ratingLabelIcon
        self.starRating = starRating
        self.imageURL = imageURL
        self.isHD = isHD
        self.isWidescreen = isWidescreen
        self.isSubtitled = isSubtitled
        self.isNew = isNew
        self.dvrUUID = dvrUUID
        self.dvrState = dvrState
    }

    static let empty = GuideProgramMetadata()

    var displayLabels: [String] {
        var labels: [String] = []

        if let season = seasonNumber, let episode = episodeNumber {
            labels.append("Season \(season) · Episode \(episode)")
        } else if let season = seasonNumber {
            labels.append("Season \(season)")
        } else if let episode = episodeNumber {
            labels.append("Episode \(episode)")
        }
        if let part = partNumber { labels.append("Part \(part)") }
        labels.append(contentsOf: categories.prefix(2))
        if isNew { labels.append("New") }
        if isHD { labels.append("HD") }
        if isWidescreen { labels.append("Widescreen") }
        if isSubtitled { labels.append("Subtitles") }
        if let rating = ratingLabel ?? ageRating { labels.append(rating) }
        if let starRating { labels.append("★ \(starRating)") }

        return labels
    }

    var displayDescription: String? {
        let labels = displayLabels
        return labels.isEmpty ? nil : labels.joined(separator: "  •  ")
    }
}

struct GuideProgram: Identifiable, Hashable, Codable, Sendable {
    enum Phase: Equatable {
        case past
        case current
        case future
    }

    let id: String
    /// The native TVheadend EPG event identifier. This is absent when an
    /// external XMLTV document supplied the programme.
    let providerEventID: Int64?
    let seriesLink: String?
    let channelID: String
    let title: String
    let subtitle: String?
    let overview: String
    let start: Date
    let end: Date
    let metadata: GuideProgramMetadata

    init(
        id: String,
        providerEventID: Int64? = nil,
        seriesLink: String? = nil,
        channelID: String,
        title: String,
        subtitle: String?,
        overview: String,
        start: Date,
        end: Date,
        metadata: GuideProgramMetadata = .empty
    ) {
        self.id = id
        self.providerEventID = providerEventID
        self.seriesLink = seriesLink
        self.channelID = channelID
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
        self.start = start
        self.end = end
        self.metadata = metadata
    }

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }

    func phase(at date: Date) -> Phase {
        if end <= date {
            return .past
        }
        if start <= date, date < end {
            return .current
        }
        return .future
    }

    func isAiring(at date: Date) -> Bool {
        phase(at: date) == .current
    }
}

enum GuideChannelAppearance {
    static func monogram(for name: String, fallback: String = "TV") -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." })
        let monogram = if words.count >= 2 {
            words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        } else {
            String(name.prefix(2)).uppercased()
        }
        return monogram.isEmpty ? fallback : monogram
    }

    static func tint(for identifier: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .teal, .cyan]
        let value = identifier.unicodeScalars.reduce(0) {
            ($0 &* 31 &+ Int($1.value)) & 0x7fffffff
        }
        return palette[value % palette.count]
    }
}

struct GuideTimeline: Equatable {
    static let pointsPerHour: CGFloat = 360

    let start: Date
    let end: Date

    var width: CGFloat {
        CGFloat(end.timeIntervalSince(start) / 3_600) * Self.pointsPerHour
    }

    func xOffset(for date: Date) -> CGFloat {
        let rawOffset = CGFloat(date.timeIntervalSince(start) / 3_600) * Self.pointsPerHour
        return min(max(0, rawOffset), width)
    }

    func width(for interval: DateInterval) -> CGFloat {
        CGFloat(interval.duration / 3_600) * Self.pointsPerHour
    }

    static func surrounding(_ date: Date, calendar: Calendar = .current) -> GuideTimeline {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = ((components.minute ?? 0) / 30) * 30
        var roundedComponents = components
        roundedComponents.minute = minute
        roundedComponents.second = 0

        let rounded = calendar.date(from: roundedComponents) ?? date
        let start = calendar.date(byAdding: .hour, value: -1, to: rounded) ?? rounded
        let end = calendar.date(byAdding: .hour, value: 6, to: start) ?? start.addingTimeInterval(21_600)
        return GuideTimeline(start: start, end: end)
    }

    var halfHourMarks: [Date] {
        var dates: [Date] = []
        var date = start
        while date <= end {
            dates.append(date)
            date = date.addingTimeInterval(1_800)
        }
        return dates
    }
}
