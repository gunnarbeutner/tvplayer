import Foundation

struct DiscoveredTVHeadendSettings: Equatable {
    static let serviceType = "_tvplayer._tcp."
    static let guideServiceType = "_tvplayer-guide._tcp."

    let discoveryID: String?
    let baseURL: URL
    let username: String
    let password: String
    let streamProfile: String
    let htspPort: Int
    let guideCacheURL: URL?
    let xmltvURL: URL?

    init?(
        fields: [String: Data],
        hostName: String,
        port: Int,
        guideCacheURL: URL? = nil
    ) {
        guard let record = DNSServiceTXTRecord(fields: fields),
              record.value("txtvers") == "1",
              let discoveryID = record.value("id"), !discoveryID.isEmpty,
              let baseURL = record.endpointURL(hostName: hostName, port: port)
        else { return nil }
        let username = record.value("username") ?? ""
        let password = record.rawValue("password") ?? ""
        guard username.isEmpty == password.isEmpty else { return nil }

        let profile = record.value("profile") ?? "pass"
        let htspPort: Int
        if let portText = record.value("htsp_port") {
            guard let parsedPort = Int(portText), (1...65_535).contains(parsedPort) else {
                return nil
            }
            htspPort = parsedPort
        } else {
            htspPort = 9982
        }

        self.discoveryID = discoveryID
        self.baseURL = baseURL
        self.username = username
        self.password = password
        streamProfile = profile.isEmpty ? "pass" : profile
        self.htspPort = htspPort
        self.guideCacheURL = guideCacheURL
        xmltvURL = nil
    }

    init?(txtRecordData: Data, hostName: String, port: Int, guideCacheURL: URL? = nil) {
        self.init(
            fields: NetService.dictionary(fromTXTRecord: txtRecordData),
            hostName: hostName,
            port: port,
            guideCacheURL: guideCacheURL
        )
    }
}

struct DiscoveredGuideCacheEndpoint: Equatable {
    let discoveryID: String
    let url: URL

    init?(fields: [String: Data], hostName: String, port: Int) {
        guard let record = DNSServiceTXTRecord(fields: fields),
              record.value("txtvers") == "1",
              let discoveryID = record.value("id"), !discoveryID.isEmpty,
              record.value("format") == "tvplayer-json",
              let url = record.endpointURL(hostName: hostName, port: port)
        else { return nil }

        self.discoveryID = discoveryID
        self.url = url
    }

    init?(txtRecordData: Data, hostName: String, port: Int) {
        self.init(
            fields: NetService.dictionary(fromTXTRecord: txtRecordData),
            hostName: hostName,
            port: port
        )
    }
}

private struct DNSServiceTXTRecord {
    private let fields: [String: Data]

    init?(fields: [String: Data]) {
        var normalized: [String: Data] = [:]
        for (key, value) in fields {
            let key = key.lowercased()
            guard normalized[key] == nil else { return nil }
            normalized[key] = value
        }
        self.fields = normalized
    }

    func rawValue(_ key: String) -> String? {
        guard let data = fields[key.lowercased()],
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    func value(_ key: String) -> String? {
        rawValue(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func endpointURL(hostName: String, port: Int) -> URL? {
        guard (1...65_535).contains(port),
              let scheme = value("scheme")?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let path = value("path") ?? "/"
        guard path.hasPrefix("/"),
              !path.contains("?"),
              !path.contains("#")
        else { return nil }

        var host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = path
        return components.url
    }
}

struct DiscoveredTVHeadendService: Equatable {
    let name: String
    let serviceIdentity: String
    let settings: DiscoveredTVHeadendSettings
}

enum TVHeadendDiscoveryEvent: Equatable {
    case upsert(DiscoveredTVHeadendService)
    case removed(serviceIdentity: String)
}

struct ResolvedTVHeadendDiscoveryRecord: Equatable {
    let name: String
    let serviceIdentity: String
    let fields: [String: Data]
    let hostName: String
    let port: Int
    let discoveryID: String
}

struct ResolvedGuideDiscoveryRecord: Equatable {
    let serviceIdentity: String
    let endpoint: DiscoveredGuideCacheEndpoint
}

struct TVHeadendDiscoveryRegistry {
    private var tvHeadendRecords: [String: ResolvedTVHeadendDiscoveryRecord] = [:]
    private var guideRecords: [String: ResolvedGuideDiscoveryRecord] = [:]

    mutating func upsert(
        _ record: ResolvedTVHeadendDiscoveryRecord
    ) -> [TVHeadendDiscoveryEvent] {
        tvHeadendRecords[record.serviceIdentity] = record
        return event(for: record).map { [$0] } ?? []
    }

    mutating func upsert(_ record: ResolvedGuideDiscoveryRecord) -> [TVHeadendDiscoveryEvent] {
        let previousDiscoveryID = guideRecords[record.serviceIdentity]?.endpoint.discoveryID
        guideRecords[record.serviceIdentity] = record

        var discoveryIDs = [record.endpoint.discoveryID]
        if let previousDiscoveryID, previousDiscoveryID != record.endpoint.discoveryID {
            discoveryIDs.append(previousDiscoveryID)
        }
        return discoveryIDs.flatMap(events(discoveryID:))
    }

    mutating func remove(serviceIdentity: String) -> [TVHeadendDiscoveryEvent] {
        var result: [TVHeadendDiscoveryEvent] = []
        if tvHeadendRecords.removeValue(forKey: serviceIdentity) != nil {
            result.append(.removed(serviceIdentity: serviceIdentity))
        }
        if let guide = guideRecords.removeValue(forKey: serviceIdentity) {
            result.append(contentsOf: events(discoveryID: guide.endpoint.discoveryID))
        }
        return result
    }

    private func events(discoveryID: String) -> [TVHeadendDiscoveryEvent] {
        tvHeadendRecords.values
            .filter { $0.discoveryID == discoveryID }
            .sorted { $0.serviceIdentity < $1.serviceIdentity }
            .compactMap(event(for:))
    }

    private func event(
        for record: ResolvedTVHeadendDiscoveryRecord
    ) -> TVHeadendDiscoveryEvent? {
        let guideURL = guideRecords.values
            .filter { $0.endpoint.discoveryID == record.discoveryID }
            .sorted { $0.serviceIdentity < $1.serviceIdentity }
            .first?
            .endpoint.url
        guard let settings = DiscoveredTVHeadendSettings(
            fields: record.fields,
            hostName: record.hostName,
            port: record.port,
            guideCacheURL: guideURL
        ) else { return nil }

        return .upsert(DiscoveredTVHeadendService(
            name: record.name,
            serviceIdentity: record.serviceIdentity,
            settings: settings
        ))
    }
}

@MainActor
final class TVHeadendDiscovery: NSObject,
    @preconcurrency NetServiceBrowserDelegate,
    @preconcurrency NetServiceDelegate
{
    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private var registry = TVHeadendDiscoveryRegistry()
    private let eventHandler: (TVHeadendDiscoveryEvent) -> Void
    private var isRunning = false

    init(eventHandler: @escaping (TVHeadendDiscoveryEvent) -> Void) {
        self.eventHandler = eventHandler
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        browsers = [
            DiscoveredTVHeadendSettings.serviceType,
            DiscoveredTVHeadendSettings.guideServiceType,
        ].map { serviceType in
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: serviceType, inDomain: "local.")
            return browser
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        services.forEach {
            $0.stopMonitoring()
            $0.stop()
        }
        services.removeAll()
        registry = TVHeadendDiscoveryRegistry()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard isRunning, !services.contains(where: { $0 === service }) else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        services.removeAll { $0 === service }
        service.stopMonitoring()
        service.stop()

        emit(registry.remove(serviceIdentity: Self.identity(for: service)))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        sender.startMonitoring()
        update(sender, txtRecordData: sender.txtRecordData())
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        update(sender, txtRecordData: data)
    }

    private func update(_ service: NetService, txtRecordData: Data?) {
        guard isRunning,
              let hostName = service.hostName,
              let txtRecordData
        else { return }

        let identity = Self.identity(for: service)
        let fields = NetService.dictionary(fromTXTRecord: txtRecordData)
        switch service.type.lowercased() {
        case DiscoveredTVHeadendSettings.serviceType.lowercased():
            guard let settings = DiscoveredTVHeadendSettings(
                fields: fields,
                hostName: hostName,
                port: service.port
            ), let discoveryID = settings.discoveryID else {
                emit(registry.remove(serviceIdentity: identity))
                return
            }
            emit(registry.upsert(ResolvedTVHeadendDiscoveryRecord(
                name: service.name,
                serviceIdentity: identity,
                fields: fields,
                hostName: hostName,
                port: service.port,
                discoveryID: discoveryID
            )))

        case DiscoveredTVHeadendSettings.guideServiceType.lowercased():
            guard let endpoint = DiscoveredGuideCacheEndpoint(
                fields: fields,
                hostName: hostName,
                port: service.port
            ) else {
                emit(registry.remove(serviceIdentity: identity))
                return
            }
            emit(registry.upsert(ResolvedGuideDiscoveryRecord(
                serviceIdentity: identity,
                endpoint: endpoint
            )))

        default:
            break
        }
    }

    private func emit(_ events: [TVHeadendDiscoveryEvent]) {
        events.forEach(eventHandler)
    }

    private static func identity(for service: NetService) -> String {
        [service.domain, service.type, service.name]
            .joined(separator: "|")
            .lowercased()
    }
}
