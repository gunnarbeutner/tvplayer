import Foundation
import Darwin

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
    let resolvedAddresses: [String]
    let guideResolvedAddresses: [String]

    init?(
        fields: [String: Data],
        hostName: String,
        port: Int,
        resolvedAddresses: [String] = [],
        guideCacheURL: URL? = nil,
        guideResolvedAddresses: [String] = []
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
        self.resolvedAddresses = resolvedAddresses
        self.guideResolvedAddresses = guideResolvedAddresses
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
    let resolvedAddresses: [String]

    init?(
        fields: [String: Data],
        hostName: String,
        port: Int,
        resolvedAddresses: [String] = []
    ) {
        guard let record = DNSServiceTXTRecord(fields: fields),
              record.value("txtvers") == "1",
              let discoveryID = record.value("id"), !discoveryID.isEmpty,
              record.value("format") == "tvplayer-json",
              let url = record.endpointURL(hostName: hostName, port: port)
        else { return nil }

        self.discoveryID = discoveryID
        self.url = url
        self.resolvedAddresses = resolvedAddresses
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
    let resolvedAddresses: [String]

    init(
        name: String,
        serviceIdentity: String,
        fields: [String: Data],
        hostName: String,
        port: Int,
        discoveryID: String,
        resolvedAddresses: [String] = []
    ) {
        self.name = name
        self.serviceIdentity = serviceIdentity
        self.fields = fields
        self.hostName = hostName
        self.port = port
        self.discoveryID = discoveryID
        self.resolvedAddresses = resolvedAddresses
    }
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
        let guideAddresses = guideRecords.values
            .filter { $0.endpoint.discoveryID == record.discoveryID }
            .sorted { $0.serviceIdentity < $1.serviceIdentity }
            .first?
            .endpoint.resolvedAddresses ?? []
        guard let settings = DiscoveredTVHeadendSettings(
            fields: record.fields,
            hostName: record.hostName,
            port: record.port,
            resolvedAddresses: record.resolvedAddresses,
            guideCacheURL: guideURL,
            guideResolvedAddresses: guideAddresses
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
        let resolvedAddresses = Self.numericAddresses(from: service.addresses ?? [])
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
                discoveryID: discoveryID,
                resolvedAddresses: resolvedAddresses
            )))

        case DiscoveredTVHeadendSettings.guideServiceType.lowercased():
            guard let endpoint = DiscoveredGuideCacheEndpoint(
                fields: fields,
                hostName: hostName,
                port: service.port,
                resolvedAddresses: resolvedAddresses
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

    static func numericAddresses(from socketAddresses: [Data]) -> [String] {
        usableNumericAddresses(socketAddresses.compactMap { data in
            data.withUnsafeBytes { buffer -> String? in
                guard let baseAddress = buffer.baseAddress,
                      buffer.count >= MemoryLayout<sockaddr>.size
                else { return nil }
                let address = baseAddress.assumingMemoryBound(to: sockaddr.self)
                guard address.pointee.sa_family == sa_family_t(AF_INET)
                        || address.pointee.sa_family == sa_family_t(AF_INET6)
                else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(
                    address,
                    socklen_t(buffer.count),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 else { return nil }
                return String(
                    decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
            }
        })
    }

    static func usableNumericAddresses(_ addresses: [String]) -> [String] {
        var seen: Set<String> = []
        return addresses.filter { address in
            let value = address.lowercased()
            guard !value.isEmpty else { return false }
            if value.contains(".") {
                let octets = value.split(separator: ".").compactMap { Int($0) }
                guard octets.count == 4,
                      octets.allSatisfy({ (0...255).contains($0) }),
                      octets[0] != 0,
                      octets[0] != 127,
                      !(octets[0] == 169 && octets[1] == 254),
                      octets[0] < 224
                else { return false }
            } else {
                var parsed = in6_addr()
                guard value.withCString({ inet_pton(AF_INET6, $0, &parsed) }) == 1 else {
                    return false
                }
                let octets = withUnsafeBytes(of: parsed) { Array($0) }
                guard !octets.allSatisfy({ $0 == 0 }),
                      !(octets.dropLast().allSatisfy({ $0 == 0 }) && octets.last == 1),
                      octets.first != 0xff,
                      !(octets[0] == 0xfe && octets[1] & 0xc0 == 0x80)
                else { return false }
            }
            return seen.insert(value).inserted
        }
    }
}
