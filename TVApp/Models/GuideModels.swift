import Foundation
import SwiftUI

struct GuideChannel: Identifiable {
    let id: String
    let number: Int
    let name: String
    let monogram: String
    let tint: Color
    let iconURL: URL?
    let programs: [GuideProgram]
}

struct GuideProgram: Identifiable, Hashable {
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

    init(
        id: String,
        providerEventID: Int64? = nil,
        seriesLink: String? = nil,
        channelID: String,
        title: String,
        subtitle: String?,
        overview: String,
        start: Date,
        end: Date
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
