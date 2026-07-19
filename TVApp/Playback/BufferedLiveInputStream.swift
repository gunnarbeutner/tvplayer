import Darwin
import Foundation
import OSLog

/// A continuously downloaded, disk-backed input stream for non-seekable live TV.
///
/// VLC's HTTP access does not reliably activate its timeshift spool when paused.
/// This stream separates upstream ingestion from VLC consumption: URLSession keeps
/// writing the MPEG-TS feed while VLC's reader is paused, then the blocking
/// `read` implementation supplies every buffered byte when playback resumes.
final class BufferedLiveInputStream: InputStream, URLSessionDataDelegate, @unchecked Sendable {
    private struct OffsetSample {
        let offset: Int64
        let date: Date
    }

    /// Roughly 40 minutes at 6.8 Mbit/s. Keep this divisible by the 188-byte
    /// MPEG-TS packet size so wrap-around preserves packet alignment.
    private static let maximumBufferBytes: Int64 = (2 * 1_024 * 1_024 * 1_024 / 188) * 188
    private let sourceURL: URL
    private let bufferURL: URL
    private let condition = NSCondition()
    private let logger = Logger(subsystem: "de.beutner.TVPlayer", category: "LiveBuffer")

    private var fileDescriptor: Int32
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var currentStatus: Stream.Status = .notOpen
    private var currentError: Error?
    private var writeOffset: Int64 = 0
    private var readOffset: Int64 = 0
    private var retentionFloor: Int64 = 0
    private var offsetSamples: [OffsetSample] = []
    private var reachedEnd = false
    private var stopped = false
    private(set) var startedAt = Date()

    init(sourceURL: URL) throws {
        self.sourceURL = sourceURL

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TVPlayerLiveBuffer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Buffers normally disappear in `close()`. Remove leftovers from a crash
        // before creating the one stream the app can play at a time.
        if let staleBuffers = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for staleBuffer in staleBuffers where staleBuffer.pathExtension == "ts" {
                try? FileManager.default.removeItem(at: staleBuffer)
            }
        }

        bufferURL = directory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("ts")
        fileDescriptor = Darwin.open(bufferURL.path, O_CREAT | O_TRUNC | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        super.init(data: Data())
    }

    override var streamStatus: Stream.Status {
        condition.withLock { currentStatus }
    }

    override var streamError: Error? {
        condition.withLock { currentError }
    }

    override var hasBytesAvailable: Bool {
        condition.withLock { readOffset < writeOffset }
    }

    var bufferedByteCount: Int64 {
        condition.withLock { max(0, writeOffset - readOffset) }
    }

    var retainedByteCount: Int64 {
        condition.withLock { max(0, writeOffset - oldestAvailableOffset) }
    }

    var retainedStartDate: Date {
        condition.withLock {
            estimatedDate(for: oldestAvailableOffset) ?? startedAt
        }
    }

    var bytesReceived: Int64 {
        condition.withLock { writeOffset }
    }

    var bytesConsumed: Int64 {
        condition.withLock { readOffset }
    }

    /// Moves VLC's next read to the point in the retained transport stream that
    /// arrived at `date`. Unlike VLC's media-time seeking, this maps directly to
    /// the byte offsets owned by our rolling live buffer.
    ///
    /// Returns the arrival date represented by the selected byte offset. The
    /// caller uses it to keep the timeline aligned with the seek that was
    /// actually possible after clamping to the retained window.
    func seek(to date: Date) -> Date? {
        condition.withLock {
            pruneOffsetSamples()
            guard let first = offsetSamples.first, let last = offsetSamples.last else {
                return nil
            }

            let clampedDate = min(max(date, first.date), last.date)
            let upperIndex = offsetSamples.partitioningIndex { $0.date >= clampedDate }
            let lower: OffsetSample
            let upper: OffsetSample
            if upperIndex == 0 {
                lower = first
                upper = first
            } else if upperIndex == offsetSamples.count {
                lower = last
                upper = last
            } else {
                lower = offsetSamples[upperIndex - 1]
                upper = offsetSamples[upperIndex]
            }

            let dateSpan = upper.date.timeIntervalSince(lower.date)
            let fraction = dateSpan > 0
                ? clampedDate.timeIntervalSince(lower.date) / dateSpan
                : 0
            let interpolatedOffset = lower.offset
                + Int64(Double(upper.offset - lower.offset) * fraction)
            let packetAlignedOffset = interpolatedOffset - (interpolatedOffset % 188)
            readOffset = min(max(packetAlignedOffset, oldestAvailableOffset), writeOffset)
            condition.broadcast()

            let selectedDate = estimatedDate(for: readOffset) ?? clampedDate
            logger.info(
                "Moved live-buffer read position to \(selectedDate.formatted(date: .omitted, time: .standard), privacy: .public) at byte \(self.readOffset, privacy: .public)"
            )
            return selectedDate
        }
    }

    /// Drops prewarm data before VLC has started consuming it. A short tail is
    /// retained so the MPEG-TS demuxer can find tables and a nearby keyframe.
    func moveToLiveEdge(retainingBytes: Int64 = 512 * 1_024) {
        condition.withLock {
            guard readOffset == 0, writeOffset > retainingBytes else { return }
            let target = writeOffset - retainingBytes
            readOffset = target - (target % 188)
            retentionFloor = readOffset
        }
    }

    override func open() {
        condition.lock()
        guard currentStatus == .notOpen else {
            condition.unlock()
            return
        }
        currentStatus = .opening
        condition.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = true

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let task = session.dataTask(with: request)
        condition.withLock {
            self.session = session
            self.task = task
            startedAt = Date()
            offsetSamples = [OffsetSample(offset: writeOffset, date: startedAt)]
            currentStatus = .open
        }
        logger.info("Starting disk-backed live buffer from \(self.sourceURL.host ?? "unknown host", privacy: .public)")
        task.resume()
    }

    override func close() {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }

        stopped = true
        currentStatus = .closed
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        condition.broadcast()

        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        condition.unlock()

        try? FileManager.default.removeItem(at: bufferURL)
        logger.info("Stopped disk-backed live buffer")
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0 else { return 0 }

        condition.lock()
        while !stopped, currentError == nil, !reachedEnd, readOffset >= writeOffset {
            condition.wait()
        }

        if stopped {
            condition.unlock()
            return -1
        }
        if currentError != nil {
            currentStatus = .error
            condition.unlock()
            return -1
        }
        if readOffset >= writeOffset, reachedEnd {
            currentStatus = .atEnd
            condition.unlock()
            return 0
        }

        let physicalOffset = readOffset % Self.maximumBufferBytes
        let bytesBeforeWrap = Self.maximumBufferBytes - physicalOffset
        let count = min(len, Int(writeOffset - readOffset), Int(bytesBeforeWrap))
        let result = Darwin.pread(fileDescriptor, buffer, count, off_t(physicalOffset))
        if result > 0 {
            readOffset += Int64(result)
        } else if result < 0 {
            currentError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            currentStatus = .error
        }
        condition.unlock()
        return result
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? {
        if key == .fileCurrentOffsetKey {
            return condition.withLock { NSNumber(value: readOffset) }
        }
        return super.property(forKey: key)
    }

    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        guard key == .fileCurrentOffsetKey else {
            return super.setProperty(property, forKey: key)
        }
        guard let offset = (property as? NSNumber)?.int64Value else { return false }

        return condition.withLock {
            guard !stopped, offset <= writeOffset else { return false }
            readOffset = max(oldestAvailableOffset, offset)
            condition.broadcast()
            return true
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let response = response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            fail(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        condition.lock()
        guard !stopped, currentError == nil, fileDescriptor >= 0 else {
            condition.unlock()
            return
        }

        let bytesWritten = data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            var total = 0
            while total < bytes.count {
                let logicalOffset = writeOffset + Int64(total)
                let physicalOffset = logicalOffset % Self.maximumBufferBytes
                let bytesBeforeWrap = Int(Self.maximumBufferBytes - physicalOffset)
                let requestedCount = min(bytes.count - total, bytesBeforeWrap)
                let result = Darwin.pwrite(
                    fileDescriptor,
                    baseAddress.advanced(by: total),
                    requestedCount,
                    off_t(physicalOffset)
                )
                if result <= 0 { return result < 0 ? -1 : total }
                total += result
            }
            return total
        }

        if bytesWritten == data.count {
            writeOffset += Int64(bytesWritten)
            let receivedAt = Date()
            if offsetSamples.last.map({ receivedAt.timeIntervalSince($0.date) >= 0.25 }) ?? true {
                offsetSamples.append(OffsetSample(offset: writeOffset, date: receivedAt))
            } else if !offsetSamples.isEmpty {
                offsetSamples[offsetSamples.count - 1] = OffsetSample(offset: writeOffset, date: receivedAt)
            }
            if readOffset < oldestAvailableOffset {
                let firstWholePacket = ((oldestAvailableOffset + 187) / 188) * 188
                readOffset = min(firstWholePacket, writeOffset)
                logger.warning("Live playback fell beyond the rolling buffer and advanced to its oldest retained packet")
            }
            pruneOffsetSamples()
            condition.broadcast()
        } else {
            currentError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            currentStatus = .error
            condition.broadcast()
        }
        condition.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        condition.lock()
        if let error, !stopped, (error as? URLError)?.code != .cancelled {
            currentError = error
            currentStatus = .error
        } else if !stopped {
            reachedEnd = true
        }
        condition.broadcast()
        condition.unlock()
    }

    private func fail(_ error: Error) {
        condition.withLock {
            guard !stopped else { return }
            currentError = error
            currentStatus = .error
            condition.broadcast()
        }
    }

    private var oldestAvailableOffset: Int64 {
        max(retentionFloor, max(writeOffset - Self.maximumBufferBytes, 0))
    }

    private func pruneOffsetSamples() {
        let oldestOffset = oldestAvailableOffset
        guard offsetSamples.count > 2 else { return }
        let firstRetained = offsetSamples.partitioningIndex { $0.offset >= oldestOffset }
        // Keep one sample immediately before the floor for interpolation.
        let removalCount = max(0, firstRetained - 1)
        if removalCount > 0 {
            offsetSamples.removeFirst(removalCount)
        }
    }

    private func estimatedDate(for offset: Int64) -> Date? {
        guard let first = offsetSamples.first, let last = offsetSamples.last else { return nil }
        if offset <= first.offset { return first.date }
        if offset >= last.offset { return last.date }

        let upperIndex = offsetSamples.partitioningIndex { $0.offset >= offset }
        guard upperIndex > 0, upperIndex < offsetSamples.count else { return nil }
        let lower = offsetSamples[upperIndex - 1]
        let upper = offsetSamples[upperIndex]
        let byteSpan = upper.offset - lower.offset
        guard byteSpan > 0 else { return lower.date }
        let fraction = Double(offset - lower.offset) / Double(byteSpan)
        return lower.date.addingTimeInterval(upper.date.timeIntervalSince(lower.date) * fraction)
    }

    deinit {
        close()
    }
}

private extension Array {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var lowerBound = 0
        var upperBound = count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if predicate(self[middle]) {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return lowerBound
    }
}

private extension NSCondition {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
