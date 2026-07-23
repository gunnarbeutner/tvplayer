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
    let seasonCount: String?
    let episodeNumber: String?
    let episodeCount: String?
    let episodeOnscreen: String?
    let partNumber: String?
    let partCount: String?
    let firstAired: Int64?
    let genres: [Int]
    let categories: [String]
    let summary: String?
    let extraText: String?
    let ageRating: String?
    let ratingLabel: String?
    let ratingLabelIcon: String?
    let ratingCountry: String?
    let ratingAuthority: String?
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
        seasonCount: String? = nil,
        episodeNumber: String? = nil,
        episodeCount: String? = nil,
        episodeOnscreen: String? = nil,
        partNumber: String? = nil,
        partCount: String? = nil,
        firstAired: Int64? = nil,
        genres: [Int] = [],
        categories: [String] = [],
        summary: String? = nil,
        extraText: String? = nil,
        ageRating: String? = nil,
        ratingLabel: String? = nil,
        ratingLabelIcon: String? = nil,
        ratingCountry: String? = nil,
        ratingAuthority: String? = nil,
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
        self.seasonCount = seasonCount
        self.episodeNumber = episodeNumber
        self.episodeCount = episodeCount
        self.episodeOnscreen = episodeOnscreen
        self.partNumber = partNumber
        self.partCount = partCount
        self.firstAired = firstAired
        self.genres = genres
        self.categories = categories
        self.summary = summary
        self.extraText = extraText
        self.ageRating = ageRating
        self.ratingLabel = ratingLabel
        self.ratingLabelIcon = ratingLabelIcon
        self.ratingCountry = ratingCountry
        self.ratingAuthority = ratingAuthority
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

        let seasonDescription = Self.numberDescription(
            label: "Season",
            number: seasonNumber,
            count: seasonCount
        )
        let episodeDescription = Self.numberDescription(
            label: "Episode",
            number: episodeNumber,
            count: episodeCount
        )
        if let seasonDescription, let episodeDescription {
            labels.append("\(seasonDescription) · \(episodeDescription)")
        } else if let seasonDescription {
            labels.append(seasonDescription)
        } else if let episodeDescription {
            labels.append(episodeDescription)
        }
        if let part = Self.numberDescription(label: "Part", number: partNumber, count: partCount) {
            labels.append(part)
        }
        labels.append(contentsOf: contentLabels.prefix(3))
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

    var displayFacts: [String] {
        var facts: [String] = []
        if let firstAired, firstAired > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(firstAired))
            facts.append("First aired \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        if let episodeOnscreen = Self.nonEmpty(episodeOnscreen),
           !Self.isRedundantEpisodeOnscreen(
               episodeOnscreen,
               seasonNumber: seasonNumber,
               episodeNumber: episodeNumber
           ) {
            facts.append("Broadcast episode \(episodeOnscreen)")
        }
        let provenance = [Self.nonEmpty(ratingAuthority), Self.nonEmpty(ratingCountry)]
            .compactMap(\.self)
            .joined(separator: " · ")
        if !provenance.isEmpty {
            facts.append("Rating source \(provenance)")
        }
        return facts
    }

    func supplementaryDescriptions(excluding overview: String) -> [String] {
        let normalizedOverview = Self.normalized(overview)
        var seen = Set([normalizedOverview])
        return [summary, extraText].compactMap(Self.nonEmpty).filter {
            seen.insert(Self.normalized($0)).inserted
        }
    }

    private var contentLabels: [String] {
        var result: [String] = []
        var seen = Set<String>()
        for label in categories + genres.compactMap(Self.genreName) {
            let normalized = Self.normalized(label)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(label)
        }
        return result
    }

    private static func numberDescription(
        label: String,
        number: String?,
        count: String?
    ) -> String? {
        guard let number = nonEmpty(number) else { return nil }
        if let count = nonEmpty(count), count != number {
            return "\(label) \(number) of \(count)"
        }
        return "\(label) \(number)"
    }

    private static func isRedundantEpisodeOnscreen(
        _ value: String,
        seasonNumber: String?,
        episodeNumber: String?
    ) -> Bool {
        guard let season = canonicalEpisodeComponent(seasonNumber),
              let episode = canonicalEpisodeComponent(episodeNumber)
        else { return false }
        let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
        guard let representedEpisode =
            canonicalEpisodePair(
                normalized,
                seasonPrefix: "season",
                episodeSeparator: "episode"
            )
            ?? canonicalEpisodePair(
                normalized,
                seasonPrefix: "s",
                episodeSeparator: "e"
            )
        else { return false }
        return representedEpisode.season == season
            && representedEpisode.episode == episode
    }

    private static func canonicalEpisodePair(
        _ value: String,
        seasonPrefix: String,
        episodeSeparator: String
    ) -> (season: String, episode: String)? {
        guard value.hasPrefix(seasonPrefix) else { return nil }
        let remainder = value.dropFirst(seasonPrefix.count)
        guard let separatorRange = remainder.range(of: episodeSeparator),
              separatorRange.lowerBound != remainder.startIndex,
              separatorRange.upperBound != remainder.endIndex,
              let season = canonicalEpisodeComponent(
                  String(remainder[..<separatorRange.lowerBound])
              ),
              let episode = canonicalEpisodeComponent(
                  String(remainder[separatorRange.upperBound...])
              )
        else { return nil }
        return (season, episode)
    }

    private static func canonicalEpisodeComponent(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        if let number = Int(value) { return String(number) }
        let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized.isEmpty ? nil : normalized
    }

    private static func genreName(_ value: Int) -> String? {
        let group = value > 0x0f ? value >> 4 : value
        return switch group {
        case 0x1: "Movie / Drama"
        case 0x2: "News / Current affairs"
        case 0x3: "Show / Game show"
        case 0x4: "Sports"
        case 0x5: "Children / Youth"
        case 0x6: "Music / Dance"
        case 0x7: "Arts / Culture"
        case 0x8: "Social / Political"
        case 0x9: "Education / Science"
        case 0xa: "Leisure / Hobbies"
        case 0xb: "Special interest"
        default: nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ).trimmingCharacters(in: .whitespacesAndNewlines)
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
    private static let halfHour: TimeInterval = 1_800
    private static let futureDuration: TimeInterval = 24 * 3_600

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

    /// The usable edge can be earlier than the requested edge when a guide
    /// source has not populated the whole window yet. Never claim coverage
    /// beyond either the last returned programme or this timeline.
    func availableCoverageEnd(in channels: [GuideChannel]) -> Date? {
        guard let programmeEnd = channels.lazy
            .flatMap(\.programs)
            .map(\.end)
            .max(),
              programmeEnd > start
        else { return nil }
        return min(end, programmeEnd)
    }

    static func surrounding(_ date: Date, calendar: Calendar = .current) -> GuideTimeline {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = ((components.minute ?? 0) / 30) * 30
        var roundedComponents = components
        roundedComponents.minute = minute
        roundedComponents.second = 0

        let rounded = calendar.date(from: roundedComponents) ?? date
        let start = calendar.date(byAdding: .hour, value: -1, to: rounded) ?? rounded
        let minimumEnd = date.addingTimeInterval(Self.futureDuration)
        let halfHoursToEnd = ceil(
            minimumEnd.timeIntervalSince(rounded) / Self.halfHour
        )
        let end = rounded.addingTimeInterval(halfHoursToEnd * Self.halfHour)
        return GuideTimeline(start: start, end: end)
    }

    var halfHourMarks: [Date] {
        var dates: [Date] = []
        var date = start
        while date <= end {
            dates.append(date)
            date = date.addingTimeInterval(Self.halfHour)
        }
        return dates
    }
}
