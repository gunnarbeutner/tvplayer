import Foundation

struct XMLTVChannel: Sendable {
    let id: String
    let displayName: String
    let iconURL: String?
}

struct XMLTVProgramme: Sendable {
    let channelID: String
    let title: String
    let subtitle: String?
    let description: String?
    let imageURL: String?
    let start: Date
    let end: Date
}

struct XMLTVDocument: Sendable {
    let channels: [XMLTVChannel]
    let programmes: [XMLTVProgramme]
}

enum XMLTVParserError: LocalizedError {
    case invalidDocument(String)

    var errorDescription: String? {
        switch self {
        case let .invalidDocument(message):
            return "The XMLTV guide could not be read: \(message)"
        }
    }
}

enum XMLTVParser {
    static func parse(_ data: Data) throws -> XMLTVDocument {
        let delegate = XMLTVParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw XMLTVParserError.invalidDocument(parser.parserError?.localizedDescription ?? "Unknown XML error")
        }
        return XMLTVDocument(channels: delegate.channels, programmes: delegate.programmes)
    }
}

private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    private struct ChannelBuilder {
        let id: String
        var displayName = ""
        var iconURL: String?
    }

    private struct ProgrammeBuilder {
        let channelID: String
        let start: Date
        let end: Date
        var title = ""
        var subtitle: String?
        var description: String?
        var imageURL: String?
    }

    private(set) var channels: [XMLTVChannel] = []
    private(set) var programmes: [XMLTVProgramme] = []
    private var channel: ChannelBuilder?
    private var programme: ProgrammeBuilder?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""

        switch elementName {
        case "channel":
            if let id = attributeDict["id"] {
                channel = ChannelBuilder(id: id)
            }
        case "programme":
            guard let channelID = attributeDict["channel"],
                  let startValue = attributeDict["start"],
                  let stopValue = attributeDict["stop"],
                  let start = Self.date(from: startValue),
                  let end = Self.date(from: stopValue)
            else { return }
            programme = ProgrammeBuilder(channelID: channelID, start: start, end: end)
        case "icon":
            if programme != nil {
                programme?.imageURL = attributeDict["src"]
            } else if channel != nil {
                channel?.iconURL = attributeDict["src"]
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "display-name" where channel != nil:
            if channel?.displayName.isEmpty == true { channel?.displayName = value }
        case "title" where programme != nil:
            programme?.title = value
        case "sub-title" where programme != nil:
            programme?.subtitle = value
        case "desc" where programme != nil:
            programme?.description = value
        case "channel":
            if let channel {
                channels.append(XMLTVChannel(id: channel.id, displayName: channel.displayName, iconURL: channel.iconURL))
            }
            channel = nil
        case "programme":
            if let programme, !programme.title.isEmpty, programme.end > programme.start {
                programmes.append(
                    XMLTVProgramme(
                        channelID: programme.channelID,
                        title: programme.title,
                        subtitle: programme.subtitle,
                        description: programme.description,
                        imageURL: programme.imageURL,
                        start: programme.start,
                        end: programme.end
                    )
                )
            }
            programme = nil
        default:
            break
        }

        text = ""
    }

    private static func date(from value: String) -> Date? {
        let formats = ["yyyyMMddHHmmss Z", "yyyyMMddHHmmssZ", "yyyyMMddHHmmss"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
