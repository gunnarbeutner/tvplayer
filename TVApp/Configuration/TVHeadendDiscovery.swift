import Foundation

struct DiscoveredTVHeadendSettings: Equatable {
    static let serviceType = "_tvplayer._tcp."

    let discoveryID: String?
    let baseURL: URL
    let username: String
    let password: String
    let streamProfile: String
    let htspPort: Int
    let guideCacheURL: URL?
    let xmltvURL: URL?

    init?(txtRecordData: Data) {
        self.init(fields: NetService.dictionary(fromTXTRecord: txtRecordData))
    }

    init?(fields: [String: Data]) {
        func rawValue(_ key: String) -> String? {
            guard let data = fields[key],
                  let string = String(data: data, encoding: .utf8)
            else { return nil }
            return string
        }
        func value(_ key: String) -> String? {
            rawValue(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let version = value("version"), version != "1" { return nil }

        guard let urlText = value("url"),
              let baseURL = Self.httpURL(from: urlText),
              let username = value("username"), !username.isEmpty,
              let password = rawValue("password"), !password.isEmpty
        else { return nil }

        let profile = value("profile") ?? "pass"
        let htspPort: Int
        if let portText = value("htsp_port") {
            guard let parsedPort = Int(portText), (1...65_535).contains(parsedPort) else { return nil }
            htspPort = parsedPort
        } else {
            htspPort = 9982
        }
        let guideText = value("guide") ?? ""
        let guideCacheURL = guideText.isEmpty ? nil : Self.httpURL(from: guideText)
        if !guideText.isEmpty, guideCacheURL == nil { return nil }
        let xmltvText = value("xmltv") ?? ""
        let xmltvURL = xmltvText.isEmpty ? nil : Self.httpURL(from: xmltvText)
        if !xmltvText.isEmpty, xmltvURL == nil { return nil }

        let advertisedID = value("id")
        discoveryID = advertisedID?.isEmpty == false ? advertisedID : nil
        self.baseURL = baseURL
        self.username = username
        self.password = password
        streamProfile = profile.isEmpty ? "pass" : profile
        self.htspPort = htspPort
        self.guideCacheURL = guideCacheURL
        self.xmltvURL = xmltvURL
    }

    private static func httpURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
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

@MainActor
final class TVHeadendDiscovery: NSObject,
    @preconcurrency NetServiceBrowserDelegate,
    @preconcurrency NetServiceDelegate
{
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private let eventHandler: (TVHeadendDiscoveryEvent) -> Void
    private var isRunning = false

    init(eventHandler: @escaping (TVHeadendDiscoveryEvent) -> Void) {
        self.eventHandler = eventHandler
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        browser.delegate = self
        browser.searchForServices(
            ofType: DiscoveredTVHeadendSettings.serviceType,
            inDomain: "local."
        )
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        browser.stop()
        services.forEach {
            $0.stopMonitoring()
            $0.stop()
        }
        services.removeAll()
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
        eventHandler(.removed(serviceIdentity: Self.identity(for: service)))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        sender.startMonitoring()
        emitUpsert(for: sender, txtRecordData: sender.txtRecordData())
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        emitUpsert(for: sender, txtRecordData: data)
    }

    private func emitUpsert(for service: NetService, txtRecordData: Data?) {
        guard isRunning,
              let txtRecordData,
              let settings = DiscoveredTVHeadendSettings(txtRecordData: txtRecordData)
        else { return }
        eventHandler(
            .upsert(
                DiscoveredTVHeadendService(
                    name: service.name,
                    serviceIdentity: Self.identity(for: service),
                    settings: settings
                )
            )
        )
    }

    private static func identity(for service: NetService) -> String {
        [service.domain, service.type, service.name]
            .joined(separator: "|")
            .lowercased()
    }
}
