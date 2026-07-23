import CryptoKit
import Darwin
import Dispatch
import Foundation

indirect enum HTSPValue: Equatable, Sendable {
    case int(Int64)
    case string(String)
    case data(Data)
    case map([String: HTSPValue])
    case list([HTSPValue])
    case bool(Bool)

    var intValue: Int64? {
        switch self {
        case let .int(value): value
        case let .bool(value): value ? 1 : 0
        default: nil
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var dataValue: Data? {
        if case let .data(value) = self { return value }
        return nil
    }

    var mapValue: [String: HTSPValue]? {
        if case let .map(value) = self { return value }
        return nil
    }

    var listValue: [HTSPValue]? {
        if case let .list(value) = self { return value }
        return nil
    }
}

enum HTSPCodecError: LocalizedError {
    case malformedMessage
    case unsupportedFieldType(UInt8)
    case fieldTooLarge

    var errorDescription: String? {
        switch self {
        case .malformedMessage: "TVHeadend returned a malformed HTSP message."
        case let .unsupportedFieldType(type): "TVHeadend returned unsupported HTSP field type \(type)."
        case .fieldTooLarge: "An HTSP message field is too large."
        }
    }
}

enum HTSPMessageCodec {
    private static let mapType: UInt8 = 1
    private static let intType: UInt8 = 2
    private static let stringType: UInt8 = 3
    private static let dataType: UInt8 = 4
    private static let listType: UInt8 = 5
    private static let boolType: UInt8 = 7

    static func encode(_ message: [String: HTSPValue]) throws -> Data {
        let payload = try encodeFields(message.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        guard payload.count <= Int(UInt32.max) else { throw HTSPCodecError.fieldTooLarge }
        var framed = Data()
        appendBigEndian(UInt32(payload.count), to: &framed)
        framed.append(payload)
        return framed
    }

    static func decodePayload(_ payload: Data) throws -> [String: HTSPValue] {
        let fields = try decodeFields(payload)
        var result: [String: HTSPValue] = [:]
        for (name, value) in fields {
            guard let name else { throw HTSPCodecError.malformedMessage }
            result[name] = value
        }
        return result
    }

    private static func encodeFields(_ fields: [(String?, HTSPValue)]) throws -> Data {
        var result = Data()
        for (name, value) in fields {
            let nameData = Data((name ?? "").utf8)
            guard nameData.count <= Int(UInt8.max) else { throw HTSPCodecError.fieldTooLarge }

            let type: UInt8
            let data: Data
            switch value {
            case let .int(number):
                type = intType
                var bitPattern = UInt64(bitPattern: number)
                var bytes: [UInt8] = []
                repeat {
                    bytes.append(UInt8(truncatingIfNeeded: bitPattern))
                    bitPattern >>= 8
                } while bitPattern != 0
                data = Data(bytes)
            case let .string(string):
                type = stringType
                data = Data(string.utf8)
            case let .data(bytes):
                type = dataType
                data = bytes
            case let .map(map):
                type = mapType
                data = try encodeFields(map.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
            case let .list(list):
                type = listType
                data = try encodeFields(list.map { (nil, $0) })
            case let .bool(flag):
                type = boolType
                data = Data([flag ? 1 : 0])
            }

            guard data.count <= Int(UInt32.max) else { throw HTSPCodecError.fieldTooLarge }
            result.append(type)
            result.append(UInt8(nameData.count))
            appendBigEndian(UInt32(data.count), to: &result)
            result.append(nameData)
            result.append(data)
        }
        return result
    }

    private static func decodeFields(_ data: Data) throws -> [(String?, HTSPValue)] {
        var offset = 0
        var fields: [(String?, HTSPValue)] = []
        while offset < data.count {
            guard data.count - offset >= 6 else { throw HTSPCodecError.malformedMessage }
            let type = data[offset]
            let nameLength = Int(data[offset + 1])
            let valueLength = Int(readBigEndianUInt32(data, at: offset + 2))
            offset += 6
            guard nameLength <= data.count - offset else { throw HTSPCodecError.malformedMessage }
            let nameData = data[offset..<(offset + nameLength)]
            offset += nameLength
            guard valueLength <= data.count - offset else { throw HTSPCodecError.malformedMessage }
            let valueData = Data(data[offset..<(offset + valueLength)])
            offset += valueLength

            let name: String?
            if nameLength == 0 {
                name = nil
            } else {
                guard let decoded = String(data: nameData, encoding: .utf8) else {
                    throw HTSPCodecError.malformedMessage
                }
                name = decoded
            }

            let value: HTSPValue
            switch type {
            case intType:
                guard valueData.count <= 8 else { throw HTSPCodecError.malformedMessage }
                var number: UInt64 = 0
                for (index, byte) in valueData.enumerated() {
                    number |= UInt64(byte) << UInt64(index * 8)
                }
                value = .int(Int64(bitPattern: number))
            case stringType:
                guard let string = String(data: valueData, encoding: .utf8) else {
                    throw HTSPCodecError.malformedMessage
                }
                value = .string(string)
            case dataType:
                value = .data(valueData)
            case mapType:
                let nested = try decodeFields(valueData)
                var map: [String: HTSPValue] = [:]
                for (nestedName, nestedValue) in nested {
                    guard let nestedName else { throw HTSPCodecError.malformedMessage }
                    map[nestedName] = nestedValue
                }
                value = .map(map)
            case listType:
                value = .list(try decodeFields(valueData).map(\.1))
            case boolType:
                value = .bool(valueData.first == 1)
            default:
                throw HTSPCodecError.unsupportedFieldType(type)
            }
            fields.append((name, value))
        }
        return fields
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    static func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }
}

enum HTSPError: LocalizedError, Sendable {
    case invalidHost
    case connectionFailed(String)
    case disconnected
    case readTimedOut
    case authenticationFailed
    case streamingUnavailable
    case timeshiftUnavailable
    case channelUnavailable
    case unsupportedStream
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost: "The TVHeadend server URL has no HTSP host."
        case let .connectionFailed(message): "HTSP connection failed: \(message)"
        case .disconnected: "The HTSP connection closed unexpectedly."
        case .readTimedOut: "The HTSP connection did not deliver a message in time."
        case .authenticationFailed: "TVHeadend rejected HTSP authentication."
        case .streamingUnavailable: "This account does not have HTSP streaming permission."
        case .timeshiftUnavailable: "TVHeadend did not enable timeshift for this stream."
        case .channelUnavailable: "TVHeadend could not map this channel to HTSP."
        case .unsupportedStream: "The HTSP stream has no supported video or audio track."
        case let .server(message): message
        }
    }
}

struct HTSPStreamInfo: Equatable, Sendable {
    let index: Int
    let type: String
    let language: String?
    let metadata: Data?

    static func decodeList(_ value: HTSPValue?) -> [HTSPStreamInfo] {
        value?.listValue?.compactMap { value in
            guard let stream = value.mapValue,
                  let index = stream["index"]?.intValue,
                  let type = stream["type"]?.stringValue
            else { return nil }
            return HTSPStreamInfo(
                index: Int(index),
                type: type,
                language: stream["language"]?.stringValue,
                metadata: stream["meta"]?.dataValue
            )
        } ?? []
    }
}

struct HTSPSourceInfo: Equatable, Sendable {
    let adapter: String?
    let mux: String?
    let network: String?
    let provider: String?
    let service: String?
    let satellitePosition: String?

    static func decode(_ value: HTSPValue?) -> HTSPSourceInfo? {
        guard let source = value?.mapValue else { return nil }
        let info = HTSPSourceInfo(
            adapter: source["adapter"]?.stringValue,
            mux: source["mux"]?.stringValue,
            network: source["network"]?.stringValue,
            provider: source["provider"]?.stringValue,
            service: source["service"]?.stringValue,
            satellitePosition: source["satpos"]?.stringValue
        )
        return [
            info.adapter,
            info.mux,
            info.network,
            info.provider,
            info.service,
            info.satellitePosition,
        ].contains { $0?.isEmpty == false } ? info : nil
    }
}

struct HTSPSubscriptionStart: Equatable, Sendable {
    let timeshiftPeriod: Int64
    let streams: [HTSPStreamInfo]
    let sourceInfo: HTSPSourceInfo?
}

protocol HTSPConnectionTransport: AnyObject, Sendable {
    var capabilities: Set<String> { get }

    func setRawMessageObserver(_ observer: (@Sendable (Data) -> Void)?)
    func handshake(username: String, password: String) throws
    func subscribe(
        channelID: UInt32,
        profile: String,
        weight: UInt32
    ) throws -> HTSPSubscriptionStart
    func reserveSequence() -> Int64
    func sendRequest(
        method: String,
        sequence: Int64,
        fields: [String: HTSPValue],
        includesSubscriptionID: Bool
    ) throws
    func readMessage() throws -> [String: HTSPValue]
    func close()
}

extension HTSPConnectionTransport {
    func setRawMessageObserver(_ observer: (@Sendable (Data) -> Void)?) {}
}

typealias HTSPConnectionFactory = @Sendable () throws -> any HTSPConnectionTransport

actor HTSPConnectionPrewarmer {
    static let shared = HTSPConnectionPrewarmer()

    private struct Key: Hashable {
        let hosts: [String]
        let port: Int
        let username: String
        let password: String
    }

    private struct Entry {
        let id: UUID
        let connectionTask: Task<any HTSPConnectionTransport, Error>
        let expirationTask: Task<Void, Never>
    }

    private let lifetime: Duration
    private var entries: [Key: Entry] = [:]

    init(lifetime: Duration = .seconds(8)) {
        self.lifetime = lifetime
    }

    func preconnect(
        configuration: TVHeadendConfiguration,
        connectionFactory suppliedFactory: HTSPConnectionFactory? = nil
    ) {
        guard let key = key(for: configuration), entries[key] == nil else { return }
        let factory: HTSPConnectionFactory = suppliedFactory ?? {
            try HTSPConnection.openSynchronously(hosts: key.hosts, port: key.port)
        }
        let id = UUID()
        let connectionTask = Task.detached(priority: .userInitiated) {
            let connection = try factory()
            do {
                try connection.handshake(
                    username: configuration.username,
                    password: configuration.password
                )
                guard connection.capabilities.contains("timeshift") else {
                    throw HTSPError.timeshiftUnavailable
                }
                return connection
            } catch {
                connection.close()
                throw error
            }
        }
        let expirationLifetime = lifetime
        let expirationTask = Task { [weak self] in
            try? await Task.sleep(for: expirationLifetime)
            guard !Task.isCancelled else { return }
            await self?.expire(key: key, id: id)
        }
        entries[key] = Entry(
            id: id,
            connectionTask: connectionTask,
            expirationTask: expirationTask
        )
    }

    func takeConnection(
        configuration: TVHeadendConfiguration
    ) async -> (any HTSPConnectionTransport)? {
        guard let key = key(for: configuration), let entry = entries.removeValue(forKey: key)
        else { return nil }
        entry.expirationTask.cancel()
        return try? await entry.connectionTask.value
    }

    private func expire(key: Key, id: UUID) async {
        guard let entry = entries[key], entry.id == id else { return }
        entries[key] = nil
        if let connection = try? await entry.connectionTask.value {
            connection.close()
        }
    }

    private func key(for configuration: TVHeadendConfiguration) -> Key? {
        let hosts = configuration.htspConnectionHosts
        guard !hosts.isEmpty else { return nil }
        return Key(
            hosts: hosts,
            port: configuration.htspPort,
            username: configuration.username,
            password: configuration.password
        )
    }
}

final class HTSPConnection: HTSPConnectionTransport, @unchecked Sendable {
    static let protocolVersion: Int64 = 44
    static let localServerResponseTimeout: Duration = .seconds(5)

    private let fileDescriptor: Int32
    private let synchronousReadTimeoutNanoseconds: UInt64
    private let writeLock = NSLock()
    private let sequenceLock = NSLock()
    private let rawMessageObserverLock = NSLock()
    private var nextSequence: Int64 = 1
    private var rawMessageObserver: (@Sendable (Data) -> Void)?
    private(set) var capabilities: Set<String> = []
    private(set) var negotiatedVersion: Int64 = 0

    init(
        fileDescriptor: Int32,
        synchronousReadTimeout: Duration = localServerResponseTimeout
    ) {
        self.fileDescriptor = fileDescriptor
        synchronousReadTimeoutNanoseconds = Self.nanoseconds(for: synchronousReadTimeout)
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    static func probe(configuration: TVHeadendConfiguration) async throws {
        let hosts = configuration.htspConnectionHosts
        guard !hosts.isEmpty else { throw HTSPError.invalidHost }
        let connection = try await open(hosts: hosts, port: configuration.htspPort)
        try await Task.detached(priority: .userInitiated) {
            try connection.handshake(username: configuration.username, password: configuration.password)
            guard connection.capabilities.contains("timeshift") else {
                throw HTSPError.timeshiftUnavailable
            }
        }.value
    }

    static func open(hosts: [String], port: Int) async throws -> HTSPConnection {
        try await Task.detached(priority: .userInitiated) {
            try openSynchronously(hosts: hosts, port: port)
        }.value
    }

    static func openSynchronously(host: String, port: Int) throws -> HTSPConnection {
        HTSPConnection(fileDescriptor: try connectSocket(host: host, port: port))
    }

    static func openSynchronously(hosts: [String], port: Int) throws -> HTSPConnection {
        var lastError: Error = HTSPError.invalidHost
        for host in hosts {
            do {
                return try openSynchronously(host: host, port: port)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func handshake(username: String, password: String) throws {
        let hello = try request(
            method: "hello",
            fields: [
                "clientname": .string(Self.clientName),
                "clientversion": .string("1"),
                "htspversion": .int(Self.protocolVersion),
            ]
        )
        negotiatedVersion = min(
            Self.protocolVersion,
            hello["htspversion"]?.intValue ?? 0
        )
        capabilities = Set(
            hello["servercapability"]?.listValue?.compactMap(\.stringValue) ?? []
        )

        if let authenticationFields = try Self.authenticationFields(
            username: username,
            password: password,
            challenge: hello["challenge"]?.dataValue
        ) {
            let authentication = try request(
                method: "authenticate",
                fields: authenticationFields
            )
            if authentication["noaccess"]?.intValue == 1 {
                throw HTSPError.authenticationFailed
            }
        }
        do {
            _ = try request(method: "getSysTime")
        } catch HTSPError.authenticationFailed {
            throw HTSPError.streamingUnavailable
        }
    }

    func setRawMessageObserver(_ observer: (@Sendable (Data) -> Void)?) {
        rawMessageObserverLock.withLock {
            rawMessageObserver = observer
        }
    }

    static func authenticationFields(
        username: String,
        password: String,
        challenge: Data?
    ) throws -> [String: HTSPValue]? {
        let hasUsername = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasUsername == !password.isEmpty else {
            throw HTSPError.authenticationFailed
        }
        guard hasUsername else { return nil }
        guard let challenge else { throw HTSPCodecError.malformedMessage }

        var authenticationData = Data(password.utf8)
        authenticationData.append(challenge)
        return [
            "username": .string(username),
            "digest": .data(Data(Insecure.SHA1.hash(data: authenticationData))),
        ]
    }

    private static var clientName: String {
#if os(tvOS)
        "TV Player for Apple TV"
#elseif os(iOS)
        "TV Player for iPhone and iPad"
#elseif os(macOS)
        "TV Player for Mac"
#else
        "TV Player"
#endif
    }

    func subscribe(
        channelID: UInt32,
        profile: String,
        weight: UInt32
    ) throws -> HTSPSubscriptionStart {
        let deadline = makeSynchronousReadDeadline()
        let response = try request(
            method: "subscribe",
            fields: Self.subscriptionFields(
                channelID: channelID,
                profile: profile,
                weight: weight
            ),
            until: deadline
        )
        guard let period = response["timeshiftPeriod"]?.intValue, period > 0 else {
            throw HTSPError.timeshiftUnavailable
        }

        while true {
            let message = try readMessage(until: deadline)
            if let error = message["error"]?.stringValue { throw HTSPError.server(error) }
            if message["method"]?.stringValue == "subscriptionStop" {
                throw HTSPError.server(
                    message["status"]?.stringValue ?? "TVHeadend stopped the subscription."
                )
            }
            guard message["method"]?.stringValue == "subscriptionStart" else { continue }
            let streams = HTSPStreamInfo.decodeList(message["streams"])
            return HTSPSubscriptionStart(
                timeshiftPeriod: period,
                streams: streams,
                sourceInfo: HTSPSourceInfo.decode(message["sourceinfo"])
            )
        }
    }

    static func subscriptionFields(
        channelID: UInt32,
        profile: String,
        weight: UInt32
    ) -> [String: HTSPValue] {
        [
            "subscriptionId": .int(1),
            "channelId": .int(Int64(channelID)),
            "weight": .int(Int64(weight)),
            "timeshiftPeriod": .int(Int64(UInt32.max)),
            "normts": .int(1),
            "queueDepth": .int(10_000_000),
            "profile": .string(profile),
        ]
    }

    func request(method: String, fields: [String: HTSPValue] = [:]) throws -> [String: HTSPValue] {
        try request(
            method: method,
            fields: fields,
            until: makeSynchronousReadDeadline()
        )
    }

    private func request(
        method: String,
        fields: [String: HTSPValue],
        until deadline: UInt64
    ) throws -> [String: HTSPValue] {
        let sequence = reserveSequence()
        try sendRequest(method: method, sequence: sequence, fields: fields)

        while true {
            let response = try readMessage(until: deadline)
            guard response["seq"]?.intValue == sequence else { continue }
            try Self.validate(response: response)
            return response
        }
    }

    func reserveSequence() -> Int64 {
        sequenceLock.withLock {
            let sequence = nextSequence
            nextSequence += 1
            return sequence
        }
    }

    func sendRequest(
        method: String,
        sequence: Int64,
        fields: [String: HTSPValue] = [:],
        includesSubscriptionID: Bool = false
    ) throws {
        var message = fields
        message["method"] = .string(method)
        message["seq"] = .int(sequence)
        if includesSubscriptionID { message["subscriptionId"] = .int(1) }
        try send(message)
    }

    static func validate(response: [String: HTSPValue]) throws {
        if response["noaccess"]?.intValue == 1 { throw HTSPError.authenticationFailed }
        if let error = response["error"]?.stringValue { throw HTSPError.server(error) }
    }

    func sendControl(method: String, fields: [String: HTSPValue] = [:]) throws {
        var message = fields
        message["method"] = .string(method)
        message["subscriptionId"] = .int(1)
        try send(message)
    }

    func send(_ message: [String: HTSPValue]) throws {
        let data = try HTSPMessageCodec.encode(message)
        try writeLock.withLock {
            var offset = 0
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                while offset < data.count {
                    let result = Darwin.write(
                        fileDescriptor,
                        baseAddress.advanced(by: offset),
                        data.count - offset
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw HTSPError.connectionFailed(String(cString: strerror(errno)))
                    }
                    if result == 0 { throw HTSPError.disconnected }
                    offset += result
                }
            }
        }
    }

    func readMessage() throws -> [String: HTSPValue] {
        try readMessage(until: nil)
    }

    private func readMessage(until deadline: UInt64?) throws -> [String: HTSPValue] {
        let header = try readExactly(4, until: deadline)
        let length = Int(HTSPMessageCodec.readBigEndianUInt32(header, at: 0))
        guard length <= 64 * 1_024 * 1_024 else { throw HTSPCodecError.fieldTooLarge }
        let payload = try readExactly(length, until: deadline)
        let observer = rawMessageObserverLock.withLock { rawMessageObserver }
        if let observer {
            var frame = Data(capacity: header.count + payload.count)
            frame.append(header)
            frame.append(payload)
            observer(frame)
        }
        return try HTSPMessageCodec.decodePayload(payload)
    }

    func close() {
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }

    private func readExactly(_ count: Int, until deadline: UInt64?) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < count {
                if let deadline { try waitUntilReadable(deadline: deadline) }
                let result: Int
                if deadline != nil {
                    // poll() establishes readiness and MSG_DONTWAIT ensures a
                    // concurrent close/read cannot put us back into an
                    // unbounded blocking syscall before we re-check the
                    // absolute deadline.
                    result = Darwin.recv(
                        fileDescriptor,
                        baseAddress.advanced(by: offset),
                        count - offset,
                        MSG_DONTWAIT
                    )
                } else {
                    result = Darwin.read(
                        fileDescriptor,
                        baseAddress.advanced(by: offset),
                        count - offset
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    if deadline != nil, errno == EAGAIN || errno == EWOULDBLOCK {
                        continue
                    }
                    if offset == 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        throw HTSPError.readTimedOut
                    }
                    throw HTSPError.connectionFailed(String(cString: strerror(errno)))
                }
                if result == 0 { throw HTSPError.disconnected }
                offset += result
            }
        }
        return data
    }

    private func makeSynchronousReadDeadline() -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let addition = now.addingReportingOverflow(synchronousReadTimeoutNanoseconds)
        return addition.overflow ? UInt64.max : addition.partialValue
    }

    private func waitUntilReadable(deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw HTSPError.readTimedOut }
            let remainingNanoseconds = deadline - now
            let wholeMilliseconds = remainingNanoseconds / 1_000_000
            let roundedMilliseconds = wholeMilliseconds
                + (remainingNanoseconds.isMultiple(of: 1_000_000) ? 0 : 1)
            let timeout = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, timeout)
            if result > 0 { return }
            if result == 0 { throw HTSPError.readTimedOut }
            if errno == EINTR { continue }
            throw HTSPError.connectionFailed(String(cString: strerror(errno)))
        }
    }

    private static func nanoseconds(for duration: Duration) -> UInt64 {
        guard duration > .zero else { return 0 }
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let secondsProduct = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsProduct.overflow else { return UInt64.max }
        let sum = secondsProduct.partialValue.addingReportingOverflow(nanoseconds)
        return sum.overflow ? UInt64.max : sum.partialValue
    }

    private static func connectSocket(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw HTSPError.connectionFailed(String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(result) }

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        var lastError = ECONNREFUSED
        while let info = candidate?.pointee {
            let descriptor = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if descriptor >= 0 {
                var noSignal: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
                if Darwin.connect(descriptor, info.ai_addr, info.ai_addrlen) == 0 {
                    var timeout = timeval(tv_sec: 10, tv_usec: 0)
                    setsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_RCVTIMEO,
                        &timeout,
                        socklen_t(MemoryLayout.size(ofValue: timeout))
                    )
                    setsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_SNDTIMEO,
                        &timeout,
                        socklen_t(MemoryLayout.size(ofValue: timeout))
                    )
                    return descriptor
                }
                lastError = errno
                Darwin.close(descriptor)
            } else {
                lastError = errno
            }
            candidate = info.ai_next
        }
        throw HTSPError.connectionFailed(String(cString: strerror(lastError)))
    }
}
