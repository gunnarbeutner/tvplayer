import Foundation

struct DiscoveredTVHeadendSettings: Equatable {
    static let serviceType = "_tvplayer._tcp."

    let baseURL: URL
    let username: String
    let password: String
    let streamProfile: String
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
        let guideText = value("guide") ?? ""
        let guideCacheURL = guideText.isEmpty ? nil : Self.httpURL(from: guideText)
        if !guideText.isEmpty, guideCacheURL == nil { return nil }
        let xmltvText = value("xmltv") ?? ""
        let xmltvURL = xmltvText.isEmpty ? nil : Self.httpURL(from: xmltvText)
        if !xmltvText.isEmpty, xmltvURL == nil { return nil }

        self.baseURL = baseURL
        self.username = username
        self.password = password
        streamProfile = profile.isEmpty ? "pass" : profile
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

@MainActor
final class TVHeadendDiscovery: NSObject,
    @preconcurrency NetServiceBrowserDelegate,
    @preconcurrency NetServiceDelegate
{
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private let discovered: (DiscoveredTVHeadendSettings) -> Void
    private var isRunning = false

    init(discovered: @escaping (DiscoveredTVHeadendSettings) -> Void) {
        self.discovered = discovered
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
        services.forEach { $0.stop() }
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
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard isRunning,
              let txtRecordData = sender.txtRecordData(),
              let settings = DiscoveredTVHeadendSettings(txtRecordData: txtRecordData)
        else { return }
        discovered(settings)
    }
}
