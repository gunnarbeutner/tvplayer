import Foundation
import SwiftUI

enum SampleGuideData {
    private struct ChannelSeed {
        let id: String
        let name: String
        let monogram: String
        let tint: Color
        let titles: [String]
    }

    private static let seeds: [ChannelSeed] = [
        .init(id: "ard", name: "Das Erste", monogram: "ARD", tint: .orange, titles: ["Tagesschau", "Sportschau: Tour de France", "Bericht aus Berlin", "Kreta"]),
        .init(id: "zdf", name: "ZDF", monogram: "ZDF", tint: .gray, titles: ["Duell der Gartenprofis", "planet e.", "Die Rosenheim-Cops", "Terra Xplore", "Der Alte"]),
        .init(id: "rtl", name: "RTL", monogram: "RTL", tint: .blue, titles: ["Formel 1: Grand Prix", "Exclusiv Weekend", "RTL Aktuell", "Klima Update"]),
        .init(id: "sat1", name: "SAT.1", monogram: "SA", tint: .indigo, titles: ["Mordtdecai", "Top Gun", "Das große Backen", "SAT.1 Nachrichten"]),
        .init(id: "prosieben", name: "ProSieben", monogram: "P7", tint: .red, titles: ["Ein sehr gutes Quiz", "taff weekend", "Galileo Stories", "Newstime"]),
        .init(id: "vox", name: "VOX", monogram: "VO", tint: .pink, titles: ["Criminal Intent", "Die Tuning Profis", "auto mobil", "Ab ins Beet!"]),
        .init(id: "kabel1", name: "Kabel Eins", monogram: "K1", tint: .red.opacity(0.8), titles: ["Mein Lokal, Dein Lokal", "K1 Magazin", "Achtung Abzocke", "Abenteuer Leben"]),
        .init(id: "rtl2", name: "RTLZWEI", monogram: "R2", tint: .yellow, titles: ["Die Schnäppchenhäuser", "Bella Italia", "GRIP", "News"]),
        .init(id: "superrtl", name: "SUPER RTL", monogram: "S", tint: .purple, titles: ["PAW Patrol", "Neue Geschichten", "Willkommen bei den Louds", "Voll zu spät!"]),
        .init(id: "kika", name: "KiKA", monogram: "K", tint: .yellow.opacity(0.8), titles: ["Törtel", "Anna und die wilden Tiere", "Die Sendung mit der Maus", "logo!"]),
        .init(id: "3sat", name: "3sat", monogram: "3S", tint: .purple.opacity(0.8), titles: ["Eisige Welten", "Faszination Erde", "Island im Winter", "Kulturzeit"]),
        .init(id: "arte", name: "arte", monogram: "AR", tint: .orange.opacity(0.8), titles: ["Stadt Land Kunst", "Zu Tisch", "ARTE Journal", "Der Dokumentarfilm"]),
    ]

    static func channels(for timeline: GuideTimeline) -> [GuideChannel] {
        let durationPatterns = [
            [60, 45, 45, 60, 90],
            [45, 30, 45, 60, 55],
            [75, 60, 45, 90],
            [60, 75, 60, 45],
            [45, 60, 30, 65, 45],
        ]

        return seeds.enumerated().map { index, seed in
            let pattern = durationPatterns[index % durationPatterns.count]
            var cursor = timeline.start.addingTimeInterval(TimeInterval(-(index % 3) * 300))
            var programs: [GuideProgram] = []
            var programIndex = 0

            while cursor < timeline.end {
                let durationMinutes = pattern[programIndex % pattern.count]
                let end = cursor.addingTimeInterval(TimeInterval(durationMinutes * 60))
                let title = seed.titles[programIndex % seed.titles.count]
                let identifier = "\(seed.id)-\(Int(cursor.timeIntervalSince1970))"

                programs.append(
                    GuideProgram(
                        id: identifier,
                        channelID: seed.id,
                        title: title,
                        subtitle: programIndex.isMultiple(of: 3) ? "Heute im Programm" : nil,
                        overview: "\(title) auf \(seed.name). Ausführliche Programminformationen erscheinen hier, ohne dass schmale Einträge im Guide unlesbar werden.",
                        start: cursor,
                        end: end
                    )
                )

                cursor = end
                programIndex += 1
            }

            return GuideChannel(
                id: seed.id,
                number: index + 1,
                name: seed.name,
                monogram: seed.monogram,
                tint: seed.tint,
                iconURL: nil,
                programs: programs
            )
        }
    }
}
