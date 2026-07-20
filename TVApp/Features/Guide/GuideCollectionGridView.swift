import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import OSLog

private let guidePerformanceLog = OSLog(
    subsystem: "de.beutner.TVPlayer",
    category: "GuidePerformance"
)

let guideFocusLogger = Logger(
    subsystem: "de.beutner.TVPlayer",
    category: "GuideFocus"
)

enum GuideGridMetrics {
    static let channelWidth: CGFloat = 280
    static let headerHeight: CGFloat = 58
    static let rowHeight: CGFloat = 94
    static let cardInset: CGFloat = 5
    static let rowInset: CGFloat = 5
    static let cardHeight = rowHeight - (rowInset * 2)
    static let focusTargetWidth: CGFloat = 120
}

enum GuideCollectionNavigationDirection: Equatable {
    case up
    case down
    case left
    case right

#if canImport(UIKit)
    init?(focusHeading: UIFocusHeading) {
        if focusHeading.contains(.up) {
            self = .up
        } else if focusHeading.contains(.down) {
            self = .down
        } else if focusHeading.contains(.left) {
            self = .left
        } else if focusHeading.contains(.right) {
            self = .right
        } else {
            return nil
        }
    }
#endif
}

enum GuideFocusNavigation {
    /// Directional input must start from confirmed focus. A pending target has
    /// not moved onscreen yet, so treating it as the origin makes a repeated
    /// key press skip over the row the user is still looking at.
    static func inputOrigin(
        confirmedProgramID: GuideProgram.ID?,
        pendingProgramID _: GuideProgram.ID?,
        eventProgramID: GuideProgram.ID
    ) -> GuideProgram.ID {
        confirmedProgramID ?? eventProgramID
    }
}

/// Immutable, indexed input for the collection view. Expensive date
/// formatting and geometry are computed once per guide revision rather than
/// while cells are scrolling on the main thread.
struct GuideGridSnapshot: Sendable {
    struct TimelineMark: Sendable, Equatable {
        let date: Date
        let title: String
        let x: CGFloat
    }

    struct Item: Sendable, Identifiable {
        let id: GuideProgram.ID
        let program: GuideProgram
        let rowIndex: Int
        let itemIndex: Int
        let frame: CGRect
        let timeText: String
        let accessibilityTimeText: String
    }

    struct Location: Sendable, Equatable {
        let row: Int
        let item: Int
    }

    let revision: Int
    let channels: [GuideChannel]
    let timeline: GuideTimeline
    let rows: [[Item]]
    let marks: [TimelineMark]
    let locationByProgramID: [GuideProgram.ID: Location]
    let contentSize: CGSize

    init(
        channels: [GuideChannel],
        timeline: GuideTimeline,
        revision: Int
    ) {
        self.revision = revision
        self.channels = channels
        self.timeline = timeline

        var locations: [GuideProgram.ID: Location] = [:]
        var builtRows: [[Item]] = []
        builtRows.reserveCapacity(channels.count)

        for (rowIndex, channel) in channels.enumerated() {
            let visiblePrograms = channel.programs
                .filter { $0.end > timeline.start && $0.start < timeline.end }
                .sorted {
                    if $0.start == $1.start { return $0.end < $1.end }
                    return $0.start < $1.start
                }

            var row: [Item] = []
            row.reserveCapacity(visiblePrograms.count)
            for (itemIndex, program) in visiblePrograms.enumerated() {
                let visibleStart = max(program.start, timeline.start)
                let visibleEnd = min(program.end, timeline.end)
                let interval = DateInterval(start: visibleStart, end: visibleEnd)
                let width = max(
                    28,
                    timeline.width(for: interval) - GuideGridMetrics.cardInset
                )
                let frame = CGRect(
                    x: GuideGridMetrics.channelWidth + timeline.xOffset(for: visibleStart) + 2,
                    y: GuideGridMetrics.headerHeight
                        + CGFloat(rowIndex) * GuideGridMetrics.rowHeight
                        + GuideGridMetrics.rowInset,
                    width: width,
                    height: GuideGridMetrics.cardHeight
                )
                let item = Item(
                    id: program.id,
                    program: program,
                    rowIndex: rowIndex,
                    itemIndex: itemIndex,
                    frame: frame,
                    timeText: "\(program.start.formatted(date: .omitted, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened))",
                    accessibilityTimeText: "\(program.start.formatted(date: .omitted, time: .shortened)) to \(program.end.formatted(date: .omitted, time: .shortened))"
                )
                row.append(item)
                locations[program.id] = Location(row: rowIndex, item: itemIndex)
            }
            builtRows.append(row)
        }

        rows = builtRows
        locationByProgramID = locations
        marks = timeline.halfHourMarks.map { mark in
            TimelineMark(
                date: mark,
                title: mark.formatted(date: .omitted, time: .shortened),
                x: timeline.xOffset(for: mark)
            )
        }
        contentSize = CGSize(
            width: GuideGridMetrics.channelWidth + timeline.width,
            height: GuideGridMetrics.headerHeight
                + CGFloat(channels.count) * GuideGridMetrics.rowHeight
        )
    }

    func item(at indexPath: IndexPath) -> Item? {
        guard rows.indices.contains(indexPath.section),
              rows[indexPath.section].indices.contains(indexPath.item)
        else { return nil }
        return rows[indexPath.section][indexPath.item]
    }

    func indexPath(for programID: GuideProgram.ID) -> IndexPath? {
        guard let location = locationByProgramID[programID] else { return nil }
        return IndexPath(item: location.item, section: location.row)
    }

    func items(inRow row: Int, intersecting horizontalRange: ClosedRange<CGFloat>) -> ArraySlice<Item> {
        guard rows.indices.contains(row), !rows[row].isEmpty else { return [] }
        let items = rows[row]
        let first = items.firstIndex { $0.frame.maxX >= horizontalRange.lowerBound }
            ?? items.endIndex
        guard first < items.endIndex else { return [] }
        let end = items[first...].firstIndex { $0.frame.minX > horizontalRange.upperBound }
            ?? items.endIndex
        return items[first..<end]
    }

    func destinationProgramID(
        from programID: GuideProgram.ID,
        direction: GuideCollectionNavigationDirection,
        at now: Date
    ) -> GuideProgram.ID? {
        guard let origin = locationByProgramID[programID],
              let current = rows[origin.row][safe: origin.item]
        else { return nil }

        switch direction {
        case .left:
            return rows[origin.row][safe: origin.item - 1]?.id
        case .right:
            return rows[origin.row][safe: origin.item + 1]?.id
        case .up, .down:
            break
        }

        let referenceDate = current.program.isAiring(at: now)
            ? now
            : current.program.start.addingTimeInterval(current.program.duration / 2)
        let step = direction == .up ? -1 : 1
        var rowIndex = origin.row + step

        while rows.indices.contains(rowIndex) {
            if let destination = closestItem(in: rows[rowIndex], to: referenceDate) {
                return destination.id
            }
            rowIndex += step
        }
        return nil
    }

    func isAtBoundary(
        programID: GuideProgram.ID,
        direction: GuideCollectionNavigationDirection
    ) -> Bool {
        guard !rows.isEmpty,
              let location = locationByProgramID[programID]
        else { return false }
        return switch direction {
        case .up:
            location.row == rows.startIndex
        case .down:
            location.row == rows.index(before: rows.endIndex)
        case .left:
            location.item == rows[location.row].startIndex
        case .right:
            location.item == rows[location.row].index(before: rows[location.row].endIndex)
        }
    }

    private func closestItem(in items: [Item], to date: Date) -> Item? {
        if let intersecting = items.first(where: {
            $0.program.start <= date && date < $0.program.end
        }) {
            return intersecting
        }
        return items.min { lhs, rhs in
            let lhsDistance = Self.distance(from: date, to: lhs.program)
            let rhsDistance = Self.distance(from: date, to: rhs.program)
            if lhsDistance == rhsDistance { return lhs.program.start < rhs.program.start }
            return lhsDistance < rhsDistance
        }
    }

    private static func distance(from date: Date, to program: GuideProgram) -> TimeInterval {
        if date < program.start { return program.start.timeIntervalSince(date) }
        if date >= program.end { return date.timeIntervalSince(program.end) }
        return 0
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Maintains the existing SwiftUI contract while moving the hot render and
/// scroll path into a reusable UIKit collection view.
#if canImport(UIKit)
struct GuideGridView: View {
    let channels: [GuideChannel]
    let timeline: GuideTimeline
    let now: Date
    let guideRevision: Int
    let preferredProgramID: GuideProgram.ID?
    let focusScope: Namespace.ID
    @Binding var focusedProgramID: GuideProgram.ID?
    let recenterRequest: UUID
    let focusRestoreRequest: UUID
    let recordingsRevision: Int
    let configuration: TVHeadendConfiguration
    let recordingState: (GuideProgram) -> TVRecordingState?
    let onActivate: (GuideProgram) -> Void
    let onPlay: (GuideProgram) -> Void
    let onReady: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GuideCollectionRepresentable(
            channels: channels,
            timeline: timeline,
            now: now,
            guideRevision: guideRevision,
            preferredProgramID: preferredProgramID,
            focusedProgramID: $focusedProgramID,
            recenterRequest: recenterRequest,
            focusRestoreRequest: focusRestoreRequest,
            recordingsRevision: recordingsRevision,
            configuration: configuration,
            recordingState: recordingState,
            onActivate: onActivate,
            onPlay: onPlay,
            onFirstSnapshotApplied: onReady,
            isEnabled: isEnabled
        )
        .televisionFocusScope(focusScope)
    }
}

private struct GuideCollectionRepresentable: UIViewRepresentable {
    let channels: [GuideChannel]
    let timeline: GuideTimeline
    let now: Date
    let guideRevision: Int
    let preferredProgramID: GuideProgram.ID?
    @Binding var focusedProgramID: GuideProgram.ID?
    let recenterRequest: UUID
    let focusRestoreRequest: UUID
    let recordingsRevision: Int
    let configuration: TVHeadendConfiguration
    let recordingState: (GuideProgram) -> TVRecordingState?
    let onActivate: (GuideProgram) -> Void
    let onPlay: (GuideProgram) -> Void
    let onFirstSnapshotApplied: () -> Void
    let isEnabled: Bool

    func makeUIView(context: Context) -> GuideCollectionView {
        GuideCollectionView()
    }

    func updateUIView(_ view: GuideCollectionView, context: Context) {
        view.update(
            channels: channels,
            timeline: timeline,
            now: now,
            guideRevision: guideRevision,
            preferredProgramID: preferredProgramID,
            focusedProgramID: focusedProgramID,
            recenterRequest: recenterRequest,
            focusRestoreRequest: focusRestoreRequest,
            recordingsRevision: recordingsRevision,
            configuration: configuration,
            recordingState: recordingState,
            onFocused: { focusedProgramID = $0 },
            onActivate: onActivate,
            onPlay: onPlay,
            onFirstSnapshotApplied: onFirstSnapshotApplied,
            isEnabled: isEnabled
        )
    }

    static func dismantleUIView(_ view: GuideCollectionView, coordinator: ()) {
        view.cancelPendingWork()
    }
}

private enum GuideCollectionElementKind {
    static let rowBackground = "GuideRowBackground"
    static let channelColumnBackground = "GuideChannelColumnBackground"
    static let channelHeader = "GuideChannelHeader"
    static let timelineHeader = "GuideTimelineHeader"
    static let cornerHeader = "GuideCornerHeader"
    static let nowIndicator = "GuideNowIndicator"
}

private final class GuideTimelineLayoutAttributes: UICollectionViewLayoutAttributes {
    nonisolated(unsafe) var horizontalOffset: CGFloat = 0

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! GuideTimelineLayoutAttributes
        copy.horizontalOffset = horizontalOffset
        return copy
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? GuideTimelineLayoutAttributes,
              other.horizontalOffset == horizontalOffset
        else { return false }
        return super.isEqual(object)
    }
}

/// A two-dimensional layout that computes only the rows and programmes around
/// the viewport. The total number of mounted views is therefore independent
/// of the channel and programme counts.
private final class GuideCollectionLayout: UICollectionViewLayout {
    var snapshot: GuideGridSnapshot? {
        didSet { invalidateLayout() }
    }
    var now = Date() {
        didSet { invalidateLayout() }
    }

    override class var layoutAttributesClass: AnyClass {
        GuideTimelineLayoutAttributes.self
    }

    override var collectionViewContentSize: CGSize {
        guard let collectionView, let snapshot else { return .zero }
        return CGSize(
            width: max(collectionView.bounds.width, snapshot.contentSize.width),
            height: max(collectionView.bounds.height, snapshot.contentSize.height)
        )
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let collectionView, let snapshot, !snapshot.channels.isEmpty else { return [] }
        var attributes: [UICollectionViewLayoutAttributes] = []
        let horizontalOverscan = collectionView.bounds.width
        let verticalOverscan = GuideGridMetrics.rowHeight * 2
        let expanded = rect.insetBy(dx: -horizontalOverscan, dy: -verticalOverscan)

        let rawFirstRow = Int(floor(
            (expanded.minY - GuideGridMetrics.headerHeight) / GuideGridMetrics.rowHeight
        ))
        let rawLastRow = Int(floor(
            (expanded.maxY - GuideGridMetrics.headerHeight) / GuideGridMetrics.rowHeight
        ))
        let firstRow = max(0, rawFirstRow)
        let lastRow = min(snapshot.channels.count - 1, rawLastRow)

        if firstRow <= lastRow {
            let horizontalRange = expanded.minX...expanded.maxX
            for row in firstRow...lastRow {
                let background = supplementaryAttributes(
                    kind: GuideCollectionElementKind.rowBackground,
                    indexPath: IndexPath(item: 0, section: row),
                    snapshot: snapshot,
                    collectionView: collectionView
                )
                attributes.append(background)

                let channel = supplementaryAttributes(
                    kind: GuideCollectionElementKind.channelHeader,
                    indexPath: IndexPath(item: 0, section: row),
                    snapshot: snapshot,
                    collectionView: collectionView
                )
                attributes.append(channel)

                for item in snapshot.items(inRow: row, intersecting: horizontalRange) {
                    let itemAttributes = GuideTimelineLayoutAttributes(
                        forCellWith: IndexPath(item: item.itemIndex, section: row)
                    )
                    itemAttributes.frame = item.frame
                    itemAttributes.zIndex = 2
                    attributes.append(itemAttributes)
                }
            }
        }

        let singletonPath = IndexPath(item: 0, section: 0)
        attributes.append(supplementaryAttributes(
            kind: GuideCollectionElementKind.channelColumnBackground,
            indexPath: singletonPath,
            snapshot: snapshot,
            collectionView: collectionView
        ))
        attributes.append(supplementaryAttributes(
            kind: GuideCollectionElementKind.nowIndicator,
            indexPath: singletonPath,
            snapshot: snapshot,
            collectionView: collectionView
        ))
        attributes.append(supplementaryAttributes(
            kind: GuideCollectionElementKind.timelineHeader,
            indexPath: singletonPath,
            snapshot: snapshot,
            collectionView: collectionView
        ))
        attributes.append(supplementaryAttributes(
            kind: GuideCollectionElementKind.cornerHeader,
            indexPath: singletonPath,
            snapshot: snapshot,
            collectionView: collectionView
        ))
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let item = snapshot?.item(at: indexPath) else { return nil }
        let attributes = GuideTimelineLayoutAttributes(forCellWith: indexPath)
        attributes.frame = item.frame
        attributes.zIndex = 2
        return attributes
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String,
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let snapshot, let collectionView else { return nil }
        return supplementaryAttributes(
            kind: elementKind,
            indexPath: indexPath,
            snapshot: snapshot,
            collectionView: collectionView
        )
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let oldBounds = collectionView?.bounds else { return true }
        return oldBounds.origin != newBounds.origin || oldBounds.size != newBounds.size
    }

    private func supplementaryAttributes(
        kind: String,
        indexPath: IndexPath,
        snapshot: GuideGridSnapshot,
        collectionView: UICollectionView
    ) -> UICollectionViewLayoutAttributes {
        let attributes = GuideTimelineLayoutAttributes(
            forSupplementaryViewOfKind: kind,
            with: indexPath
        )
        let offset = collectionView.contentOffset
        let viewport = collectionView.bounds.size

        switch kind {
        case GuideCollectionElementKind.rowBackground:
            attributes.frame = CGRect(
                x: GuideGridMetrics.channelWidth,
                y: GuideGridMetrics.headerHeight
                    + CGFloat(indexPath.section) * GuideGridMetrics.rowHeight,
                width: snapshot.timeline.width,
                height: GuideGridMetrics.rowHeight
            )
            attributes.zIndex = -10
        case GuideCollectionElementKind.channelColumnBackground:
            attributes.frame = CGRect(
                x: offset.x,
                y: offset.y + GuideGridMetrics.headerHeight,
                width: GuideGridMetrics.channelWidth,
                height: max(0, viewport.height - GuideGridMetrics.headerHeight)
            )
            attributes.zIndex = 29
        case GuideCollectionElementKind.channelHeader:
            attributes.frame = CGRect(
                x: offset.x,
                y: GuideGridMetrics.headerHeight
                    + CGFloat(indexPath.section) * GuideGridMetrics.rowHeight
                    + GuideGridMetrics.rowInset,
                width: GuideGridMetrics.channelWidth,
                height: GuideGridMetrics.cardHeight
            )
            attributes.zIndex = 30
        case GuideCollectionElementKind.timelineHeader:
            attributes.frame = CGRect(
                x: offset.x + GuideGridMetrics.channelWidth,
                y: offset.y,
                width: max(0, viewport.width - GuideGridMetrics.channelWidth),
                height: GuideGridMetrics.headerHeight
            )
            attributes.horizontalOffset = offset.x
            attributes.zIndex = 31
        case GuideCollectionElementKind.cornerHeader:
            attributes.frame = CGRect(
                x: offset.x,
                y: offset.y,
                width: GuideGridMetrics.channelWidth,
                height: GuideGridMetrics.headerHeight
            )
            attributes.zIndex = 40
        case GuideCollectionElementKind.nowIndicator:
            let isVisible = snapshot.timeline.start <= now && now <= snapshot.timeline.end
            attributes.frame = CGRect(
                x: GuideGridMetrics.channelWidth + snapshot.timeline.xOffset(for: now) - 1.5,
                y: offset.y + GuideGridMetrics.headerHeight,
                width: isVisible ? 3 : 0,
                height: max(0, viewport.height - GuideGridMetrics.headerHeight)
            )
            attributes.zIndex = 20
        default:
            attributes.frame = .zero
        }
        return attributes
    }
}

private enum GuideDirectionalPressResult {
    case native
    case consumed
}

@MainActor
private final class GuideCollectionView: UICollectionView,
    UICollectionViewDataSource,
    UICollectionViewDelegate,
    UIScrollViewDelegate
{
    private static let cellReuseID = "GuideProgrammeCell"
    private static let rowReuseID = "GuideRowBackground"
    private static let channelColumnReuseID = "GuideChannelColumnBackground"
    private static let channelReuseID = "GuideChannelHeader"
    private static let timelineReuseID = "GuideTimelineHeader"
    private static let cornerReuseID = "GuideCornerHeader"
    private static let nowReuseID = "GuideNowIndicator"

    private let guideLayout: GuideCollectionLayout
    private var guideSnapshot: GuideGridSnapshot?
    private var snapshotBuildTask: Task<Void, Never>?
    private var focusRetryTask: Task<Void, Never>?
    private var requestedGuideRevision: Int?
    private var appliedRecordingsRevision: Int?
    private var appliedRecenterRequest: UUID?
    private var appliedFocusRestoreRequest: UUID?
    private var requestedFocusedProgramID: GuideProgram.ID?
    private var preferredProgramID: GuideProgram.ID?
    private var pendingFocusProgramID: GuideProgram.ID?
    private var navigationSignpostID: OSSignpostID?
    private var currentNow = Date()
    private var currentConfiguration: TVHeadendConfiguration?
    private var isGuideEnabled = true

    private var recordingState: (GuideProgram) -> TVRecordingState? = { _ in nil }
    private var onFocused: (GuideProgram.ID) -> Void = { _ in }
    private var onActivate: (GuideProgram) -> Void = { _ in }
    private var onPlay: (GuideProgram) -> Void = { _ in }
    private var onFirstSnapshotApplied: () -> Void = {}
    private var hasReportedFirstSnapshot = false

    init() {
        let layout = GuideCollectionLayout()
        guideLayout = layout
        super.init(frame: .zero, collectionViewLayout: layout)

        backgroundColor = UIColor(AppTheme.background)
        contentInsetAdjustmentBehavior = .never
        contentInset = .zero
        scrollIndicatorInsets = .zero
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        clipsToBounds = true
        remembersLastFocusedIndexPath = true
        dataSource = self
        delegate = self

        register(GuideProgrammeCollectionCell.self, forCellWithReuseIdentifier: Self.cellReuseID)
        register(
            GuideRowBackgroundReusableView.self,
            forSupplementaryViewOfKind: GuideCollectionElementKind.rowBackground,
            withReuseIdentifier: Self.rowReuseID
        )
        register(
            GuideChannelColumnBackgroundReusableView.self,
            forSupplementaryViewOfKind: GuideCollectionElementKind.channelColumnBackground,
            withReuseIdentifier: Self.channelColumnReuseID
        )
        register(
            GuideChannelHeaderReusableView.self,
            forSupplementaryViewOfKind: GuideCollectionElementKind.channelHeader,
            withReuseIdentifier: Self.channelReuseID
        )
        register(
            GuideTimelineHeaderReusableView.self,
            forSupplementaryViewOfKind: GuideCollectionElementKind.timelineHeader,
            withReuseIdentifier: Self.timelineReuseID
        )
        register(
            GuideCornerHeaderReusableView.self,
            forSupplementaryViewOfKind: GuideCollectionElementKind.cornerHeader,
            withReuseIdentifier: Self.cornerReuseID
        )
        register(
            GuideNowIndicatorReusableView.self,
            forSupplementaryViewOfKind: GuideCollectionElementKind.nowIndicator,
            withReuseIdentifier: Self.nowReuseID
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let pendingFocusProgramID,
           let indexPath = guideSnapshot?.indexPath(for: pendingFocusProgramID),
           let cell = cellForItem(at: indexPath) {
            return [cell]
        }
        return super.preferredFocusEnvironments
    }

    func update(
        channels: [GuideChannel],
        timeline: GuideTimeline,
        now: Date,
        guideRevision: Int,
        preferredProgramID: GuideProgram.ID?,
        focusedProgramID: GuideProgram.ID?,
        recenterRequest: UUID,
        focusRestoreRequest: UUID,
        recordingsRevision: Int,
        configuration: TVHeadendConfiguration,
        recordingState: @escaping (GuideProgram) -> TVRecordingState?,
        onFocused: @escaping (GuideProgram.ID) -> Void,
        onActivate: @escaping (GuideProgram) -> Void,
        onPlay: @escaping (GuideProgram) -> Void,
        onFirstSnapshotApplied: @escaping () -> Void,
        isEnabled: Bool
    ) {
        self.preferredProgramID = preferredProgramID
        requestedFocusedProgramID = focusedProgramID
        currentConfiguration = configuration
        self.recordingState = recordingState
        self.onFocused = onFocused
        self.onActivate = onActivate
        self.onPlay = onPlay
        self.onFirstSnapshotApplied = onFirstSnapshotApplied
        isGuideEnabled = isEnabled

        if currentNow != now {
            currentNow = now
            guideLayout.now = now
            reconfigureVisibleProgrammeCells()
        }

        if requestedGuideRevision != guideRevision {
            requestedGuideRevision = guideRevision
            buildSnapshot(
                channels: channels,
                timeline: timeline,
                revision: guideRevision
            )
        }

        if appliedRecordingsRevision != recordingsRevision {
            appliedRecordingsRevision = recordingsRevision
            reconfigureVisibleProgrammeCells()
        }

        if appliedRecenterRequest != recenterRequest {
            let isInitialRequest = appliedRecenterRequest == nil
            appliedRecenterRequest = recenterRequest
            scrollToLeadingEdge(animated: !isInitialRequest)
        }

        let isRestoreRequest = appliedFocusRestoreRequest != nil
            && appliedFocusRestoreRequest != focusRestoreRequest
        appliedFocusRestoreRequest = focusRestoreRequest
        updateFocusAvailability()

        if isRestoreRequest, let focusedProgramID {
            requestFocus(on: focusedProgramID, animated: false, retriesRemaining: 4)
        } else if let focusedProgramID,
                  focusedProgramID != currentlyFocusedProgramID,
                  guideSnapshot?.indexPath(for: focusedProgramID) != nil {
            requestFocus(on: focusedProgramID, animated: false, retriesRemaining: 4)
        }
    }

    func cancelPendingWork() {
        snapshotBuildTask?.cancel()
        focusRetryTask?.cancel()
    }

    private func buildSnapshot(
        channels: [GuideChannel],
        timeline: GuideTimeline,
        revision: Int
    ) {
        snapshotBuildTask?.cancel()
        os_signpost(.begin, log: guidePerformanceLog, name: "GuideSnapshotBuild", "revision=%d", revision)
        snapshotBuildTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                GuideGridSnapshot(
                    channels: channels,
                    timeline: timeline,
                    revision: revision
                )
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.requestedGuideRevision == revision
            else { return }
            os_signpost(.end, log: guidePerformanceLog, name: "GuideSnapshotBuild", "revision=%d", revision)
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: GuideGridSnapshot) {
        os_signpost(.begin, log: guidePerformanceLog, name: "GuideSnapshotApply", "rows=%d", snapshot.rows.count)
        guideSnapshot = snapshot
        guideLayout.snapshot = snapshot
        guideLayout.now = currentNow
        UIView.performWithoutAnimation {
            reloadData()
            layoutIfNeeded()
        }
        os_signpost(.end, log: guidePerformanceLog, name: "GuideSnapshotApply", "rows=%d", snapshot.rows.count)

        if !hasReportedFirstSnapshot {
            hasReportedFirstSnapshot = true
            onFirstSnapshotApplied()
        }

        let focusID = requestedFocusedProgramID ?? preferredProgramID
        if let focusID, snapshot.indexPath(for: focusID) != nil {
            requestFocus(on: focusID, animated: false, retriesRemaining: 4)
        }
    }

    private var currentlyFocusedProgramID: GuideProgram.ID? {
        visibleCells.lazy
            .compactMap { $0 as? GuideProgrammeCollectionCell }
            .first(where: \.isFocused)?
            .programID
    }

    private func scrollToLeadingEdge(animated: Bool) {
        let target = CGPoint(x: 0, y: max(0, contentOffset.y))
        setContentOffset(target, animated: animated)
    }

    private func requestFocus(
        on programID: GuideProgram.ID,
        animated: Bool,
        retriesRemaining: Int
    ) {
        guard let snapshot = guideSnapshot,
              let indexPath = snapshot.indexPath(for: programID),
              let item = snapshot.item(at: indexPath)
        else { return }
        if currentlyFocusedProgramID == programID {
            pendingFocusProgramID = nil
            return
        }

        pendingFocusProgramID = programID
        updateFocusAvailability()
        // Custom layouts only materialize items returned by the visible
        // attributes query. If the destination is outside that window, move
        // there synchronously before asking the focus system for its cell;
        // otherwise every retry can expire while the cell still does not
        // exist (most visibly when navigating horizontally).
        let destinationIsRealized = cellForItem(at: indexPath) != nil
        reveal(item: item, animated: animated && destinationIsRealized)
        layoutIfNeeded()
        if let targetCell = cellForItem(at: indexPath),
           let focusSystem = UIFocusSystem.focusSystem(for: targetCell) {
            focusSystem.requestFocusUpdate(to: targetCell)
            focusSystem.updateFocusIfNeeded()
        } else {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }

        guard currentlyFocusedProgramID != programID else { return }
        guard retriesRemaining > 0 else {
            if pendingFocusProgramID == programID {
                pendingFocusProgramID = nil
                updateFocusAvailability()
            }
            return
        }
        focusRetryTask?.cancel()
        focusRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(35))
                guard !Task.isCancelled else { return }
                self?.requestFocus(
                    on: programID,
                    animated: false,
                    retriesRemaining: retriesRemaining - 1
                )
            } catch {
                // A newer focus request superseded this retry.
            }
        }
    }

    private func reveal(item: GuideGridSnapshot.Item, animated: Bool) {
        var target = contentOffset
        let visibleTop = target.y + GuideGridMetrics.headerHeight
        let visibleBottom = target.y + bounds.height
        if item.frame.minY < visibleTop {
            target.y = max(0, item.frame.minY - GuideGridMetrics.headerHeight - GuideGridMetrics.rowInset)
        } else if item.frame.maxY > visibleBottom {
            target.y = min(
                max(0, contentSize.height - bounds.height),
                item.frame.maxY - bounds.height + GuideGridMetrics.rowInset
            )
        }

        let pinnedTrailingEdge = target.x + GuideGridMetrics.channelWidth + 8
        if item.frame.minX < pinnedTrailingEdge {
            target.x = max(0, item.frame.minX - GuideGridMetrics.channelWidth - 8)
        }

        let focusTargetWidth = min(item.frame.width, GuideGridMetrics.focusTargetWidth)
        let focusTargetTrailingEdge = item.frame.minX + focusTargetWidth + 8
        let visibleTrailingEdge = target.x + bounds.width
        if focusTargetTrailingEdge > visibleTrailingEdge {
            target.x = min(
                max(0, contentSize.width - bounds.width),
                focusTargetTrailingEdge - bounds.width
            )
        }
        if target != contentOffset {
            setContentOffset(target, animated: animated)
        }
    }

    private func handleDirectionalPress(
        from programID: GuideProgram.ID,
        direction: GuideCollectionNavigationDirection
    ) -> GuideDirectionalPressResult {
        if let navigationSignpostID {
            os_signpost(.end, log: guidePerformanceLog, name: "GuideInputToFocus", signpostID: navigationSignpostID)
            self.navigationSignpostID = nil
        }
        let origin = GuideFocusNavigation.inputOrigin(
            confirmedProgramID: currentlyFocusedProgramID,
            pendingProgramID: pendingFocusProgramID,
            eventProgramID: programID
        )
        guard let snapshot = guideSnapshot else { return .native }
        guard let destination = snapshot.destinationProgramID(
                from: origin,
                direction: direction,
                at: currentNow
              )
        else {
            // Up is the only legitimate way out of the guide, and only from
            // the actual first channel. Every other edge stays in the grid.
            return direction == .up
                && snapshot.isAtBoundary(programID: origin, direction: .up)
                ? .native
                : .consumed
        }

        let signpostID = OSSignpostID(log: guidePerformanceLog)
        navigationSignpostID = signpostID
        let directionName = switch direction {
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        }
        os_signpost(
            .begin,
            log: guidePerformanceLog,
            name: "GuideInputToFocus",
            signpostID: signpostID,
            "direction=%{public}s",
            directionName
        )

        // Consume every in-grid move and request its indexed destination
        // directly. Mixing native focus for mounted cells with programmatic
        // focus for unmounted cells left selection state dependent on the
        // virtualization window and focus-engine timing.
        requestFocus(on: destination, animated: true, retriesRemaining: 8)
        return .consumed
    }

    fileprivate func shouldAllowFocusUpdate(
        from programID: GuideProgram.ID,
        context: UIFocusUpdateContext
    ) -> Bool {
        if let pendingFocusProgramID {
            return (context.nextFocusedItem as? GuideProgrammeCollectionCell)?.programID
                == pendingFocusProgramID
        }

        guard let direction = GuideCollectionNavigationDirection(
            focusHeading: context.focusHeading
        ), let snapshot = guideSnapshot
        else { return true }

        let origin = currentlyFocusedProgramID ?? programID
        guard let destination = snapshot.destinationProgramID(
            from: origin,
            direction: direction,
            at: currentNow
        ) else {
            return direction == .up
                && snapshot.isAtBoundary(programID: origin, direction: .up)
        }

        if (context.nextFocusedItem as? GuideProgrammeCollectionCell)?.programID == destination {
            return true
        }

        // Remote swipes can enter focus resolution without delivering an
        // arrow press to the cell. Reject the geometric substitute and route
        // the same indexed move on the next run-loop turn.
        Task { @MainActor [weak self] in
            guard let self,
                  self.pendingFocusProgramID == nil,
                  self.currentlyFocusedProgramID == origin
            else { return }
            self.requestFocus(on: destination, animated: true, retriesRemaining: 8)
        }
        return false
    }

    private func allowsFocus(on programID: GuideProgram.ID) -> Bool {
        guard isGuideEnabled else { return false }
        guard let pendingFocusProgramID else { return true }
        return pendingFocusProgramID == programID
    }

    private func didFocus(programID: GuideProgram.ID) {
        pendingFocusProgramID = nil
        updateFocusAvailability()
        focusRetryTask?.cancel()
        focusRetryTask = nil
        if let navigationSignpostID {
            os_signpost(.end, log: guidePerformanceLog, name: "GuideInputToFocus", signpostID: navigationSignpostID)
            self.navigationSignpostID = nil
        }
        os_signpost(.event, log: guidePerformanceLog, name: "GuideFocusDidUpdate", "id=%{public}s", programID)
        onFocused(programID)

        guard let snapshot = guideSnapshot,
              let indexPath = snapshot.indexPath(for: programID),
              let item = snapshot.item(at: indexPath)
        else { return }
        let pinnedTrailingEdge = contentOffset.x + GuideGridMetrics.channelWidth + 8
        if item.frame.minX < pinnedTrailingEdge {
            let correctedX = max(0, item.frame.minX - GuideGridMetrics.channelWidth - 8)
            setContentOffset(CGPoint(x: correctedX, y: contentOffset.y), animated: true)
        }
    }

    private func updateFocusAvailability() {
        for case let cell as GuideProgrammeCollectionCell in visibleCells {
            cell.isFocusAllowed = allowsFocus(on: cell.programID)
        }
        if !isGuideEnabled, currentlyFocusedProgramID != nil {
            setNeedsFocusUpdate()
        }
    }

    private func configure(_ cell: GuideProgrammeCollectionCell, with item: GuideGridSnapshot.Item) {
        cell.configure(
            item: item,
            now: currentNow,
            recordingState: recordingState(item.program),
            isFocusAllowed: allowsFocus(on: item.id),
            leadingOcclusion: leadingOcclusion(for: item),
            onFocused: { [weak self] in self?.didFocus(programID: item.id) },
            onActivate: { [weak self] in self?.onActivate(item.program) },
            onPlay: { [weak self] in self?.onPlay(item.program) },
            onDirectionalPress: { [weak self] direction in
                self?.handleDirectionalPress(from: item.id, direction: direction) ?? .native
            }
        )
        cell.guideCollectionView = self
    }

    private func leadingOcclusion(for item: GuideGridSnapshot.Item) -> CGFloat {
        min(
            item.frame.width,
            max(0, contentOffset.x + GuideGridMetrics.channelWidth - item.frame.minX)
        )
    }

    private func reconfigureVisibleProgrammeCells() {
        guard let snapshot = guideSnapshot else { return }
        for case let cell as GuideProgrammeCollectionCell in visibleCells {
            guard let indexPath = indexPath(for: cell),
                  let item = snapshot.item(at: indexPath)
            else { continue }
            configure(cell, with: item)
        }
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        guideSnapshot?.rows.count ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let snapshot = guideSnapshot, snapshot.rows.indices.contains(section) else { return 0 }
        return snapshot.rows[section].count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = dequeueReusableCell(
            withReuseIdentifier: Self.cellReuseID,
            for: indexPath
        ) as! GuideProgrammeCollectionCell
        if let item = guideSnapshot?.item(at: indexPath) {
            configure(cell, with: item)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard isGuideEnabled, let item = guideSnapshot?.item(at: indexPath) else { return }
        requestedFocusedProgramID = item.id
        onFocused(item.id)
        onActivate(item.program)
        collectionView.deselectItem(at: indexPath, animated: true)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        switch kind {
        case GuideCollectionElementKind.rowBackground:
            let view = dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: Self.rowReuseID,
                for: indexPath
            ) as! GuideRowBackgroundReusableView
            if let snapshot = guideSnapshot {
                view.configure(
                    marks: snapshot.marks,
                    isAlternate: !indexPath.section.isMultiple(of: 2)
                )
            }
            return view
        case GuideCollectionElementKind.channelColumnBackground:
            return dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: Self.channelColumnReuseID,
                for: indexPath
            )
        case GuideCollectionElementKind.channelHeader:
            let view = dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: Self.channelReuseID,
                for: indexPath
            ) as! GuideChannelHeaderReusableView
            if let channel = guideSnapshot?.channels[safe: indexPath.section] {
                view.configure(channel: channel, configuration: currentConfiguration)
            }
            return view
        case GuideCollectionElementKind.timelineHeader:
            let view = dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: Self.timelineReuseID,
                for: indexPath
            ) as! GuideTimelineHeaderReusableView
            if let snapshot = guideSnapshot { view.configure(snapshot: snapshot) }
            return view
        case GuideCollectionElementKind.cornerHeader:
            return dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: Self.cornerReuseID,
                for: indexPath
            )
        case GuideCollectionElementKind.nowIndicator:
            return dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: Self.nowReuseID,
                for: indexPath
            )
        default:
            preconditionFailure("Unknown guide supplementary kind: \(kind)")
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let snapshot = guideSnapshot else { return }
        for case let cell as GuideProgrammeCollectionCell in visibleCells {
            guard let indexPath = indexPath(for: cell),
                  let item = snapshot.item(at: indexPath)
            else { continue }
            cell.updateLeadingOcclusion(leadingOcclusion(for: item))
        }
    }
}

@MainActor
private final class GuideProgrammeCollectionCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let recordingImageView = UIImageView()
    private let progressLayer = CALayer()
    private var item: GuideGridSnapshot.Item?
    private var now = Date()
    private var recordingState: TVRecordingState?
    private var leadingOcclusion: CGFloat = 0
    private var consumedDirectionalPress: UIPress.PressType?
    private var onFocused: () -> Void = {}
    private var onActivate: () -> Void = {}
    private var onPlay: () -> Void = {}
    private var onDirectionalPress: (GuideCollectionNavigationDirection) -> GuideDirectionalPressResult = { _ in .native }

    weak var guideCollectionView: GuideCollectionView?

    var programID: GuideProgram.ID { item?.id ?? "" }
    var isFocusAllowed = true

    override var canBecomeFocused: Bool { isFocusAllowed }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderWidth = 1

        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        timeLabel.lineBreakMode = .byTruncatingTail
        recordingImageView.contentMode = .scaleAspectFit

        contentView.layer.addSublayer(progressLayer)
        contentView.addSubview(recordingImageView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(timeLabel)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Select for programme details. Press Play to watch this channel live."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        item = nil
        titleLabel.text = nil
        timeLabel.text = nil
        recordingImageView.image = nil
        onFocused = {}
        onActivate = {}
        onPlay = {}
        onDirectionalPress = { _ in .native }
        guideCollectionView = nil
    }

    func configure(
        item: GuideGridSnapshot.Item,
        now: Date,
        recordingState: TVRecordingState?,
        isFocusAllowed: Bool,
        leadingOcclusion: CGFloat,
        onFocused: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onPlay: @escaping () -> Void,
        onDirectionalPress: @escaping (GuideCollectionNavigationDirection) -> GuideDirectionalPressResult
    ) {
        self.item = item
        self.now = now
        self.recordingState = recordingState
        self.isFocusAllowed = isFocusAllowed
        self.leadingOcclusion = leadingOcclusion
        self.onFocused = onFocused
        self.onActivate = onActivate
        self.onPlay = onPlay
        self.onDirectionalPress = onDirectionalPress
        titleLabel.text = item.program.title
        timeLabel.text = item.timeText
        accessibilityLabel = accessibilityLabel(for: item.program, timeText: item.accessibilityTimeText)
        updateAppearance(animated: false)
        setNeedsLayout()
    }

    func updateLeadingOcclusion(_ inset: CGFloat) {
        guard leadingOcclusion != inset else { return }
        leadingOcclusion = inset
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safeInset = min(max(0, leadingOcclusion), bounds.width)
        let availableWidth = max(0, bounds.width - safeInset)
        let horizontalPadding: CGFloat = 13
        let iconWidth: CGFloat = recordingState == nil ? 0 : 20
        let iconSpacing: CGFloat = recordingState == nil ? 0 : 7
        let titleX = safeInset + horizontalPadding + iconWidth + iconSpacing

        recordingImageView.frame = CGRect(
            x: safeInset + horizontalPadding,
            y: 12,
            width: iconWidth,
            height: 18
        )
        titleLabel.frame = CGRect(
            x: titleX,
            y: 8,
            width: max(0, availableWidth - (titleX - safeInset) - horizontalPadding),
            height: 26
        )
        timeLabel.frame = CGRect(
            x: safeInset + horizontalPadding,
            y: 41,
            width: max(0, availableWidth - horizontalPadding * 2),
            height: availableWidth >= 118 ? 20 : 0
        )
        progressLayer.frame = progressFrame()
        titleLabel.isHidden = availableWidth < 46
        timeLabel.isHidden = availableWidth < 118
    }

    override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Reflect real UIKit focus before publishing the selection to SwiftUI.
        // Deferring the visual update into a scroll coordinator can leave the
        // information panel several animation frames ahead of the highlight.
        updateAppearance(animated: true)
        if isFocused { onFocused() }
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard isFocused else { return super.shouldUpdateFocus(in: context) }
        guard guideCollectionView?.shouldAllowFocusUpdate(
            from: programID,
            context: context
        ) != false else { return false }
        return super.shouldUpdateFocus(in: context)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .upArrow }) {
            let result = onDirectionalPress(.up)
            if result == .consumed {
                consumedDirectionalPress = .upArrow
                return
            }
        } else if presses.contains(where: { $0.type == .downArrow }) {
            let result = onDirectionalPress(.down)
            if result == .consumed {
                consumedDirectionalPress = .downArrow
                return
            }
        } else if presses.contains(where: { $0.type == .leftArrow }) {
            let result = onDirectionalPress(.left)
            if result == .consumed {
                consumedDirectionalPress = .leftArrow
                return
            }
        } else if presses.contains(where: { $0.type == .rightArrow }) {
            let result = onDirectionalPress(.right)
            if result == .consumed {
                consumedDirectionalPress = .rightArrow
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let consumedDirectionalPress,
           presses.contains(where: { $0.type == consumedDirectionalPress }) {
            self.consumedDirectionalPress = nil
            return
        }
        if presses.contains(where: { $0.type == .select }) {
            onActivate()
        } else if presses.contains(where: { $0.type == .playPause }) {
            onPlay()
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        consumedDirectionalPress = nil
        super.pressesCancelled(presses, with: event)
    }

    private func updateAppearance(animated: Bool) {
        guard let item else { return }
        let phase = item.program.phase(at: now)
        let background: UIColor
        if isFocused {
            background = UIColor(AppTheme.focused)
        } else {
            background = switch phase {
            case .past: UIColor(AppTheme.past)
            case .current: UIColor(AppTheme.current)
            case .future: UIColor(AppTheme.surface)
            }
        }
        contentView.backgroundColor = background
        contentView.layer.borderColor = UIColor(
            isFocused ? AppTheme.focusBorder : Color.white.opacity(0.16)
        ).cgColor
        contentView.layer.borderWidth = isFocused ? 4 : 1
        timeLabel.textColor = isFocused ? .white : UIColor(AppTheme.secondaryText)
        progressLayer.backgroundColor = UIColor(AppTheme.accent).cgColor
        progressLayer.isHidden = phase != .current || isFocused

        switch recordingState {
        case .recording:
            recordingImageView.image = UIImage(systemName: "record.circle.fill")
            recordingImageView.tintColor = .red
        case .upcoming:
            recordingImageView.image = UIImage(systemName: "clock.fill")
            recordingImageView.tintColor = UIColor(AppTheme.accent)
        default:
            recordingImageView.image = nil
        }
        if animated { setNeedsLayout() }
    }

    private func progressFrame() -> CGRect {
        guard let program = item?.program, program.duration > 0 else { return .zero }
        let progress = min(max(0, now.timeIntervalSince(program.start) / program.duration), 1)
        return CGRect(x: 0, y: bounds.height - 5, width: bounds.width * progress, height: 5)
    }

    private func accessibilityLabel(for program: GuideProgram, timeText: String) -> String {
        let state = switch program.phase(at: now) {
        case .past: "Finished"
        case .current: "Currently airing"
        case .future: "Upcoming"
        }
        return "\(program.title), \(timeText), \(state)"
    }
}

@MainActor
private final class GuideChannelColumnBackgroundReusableView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(AppTheme.chrome)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class GuideRowBackgroundReusableView: UICollectionReusableView {
    private var lineLayers: [CALayer] = []

    func configure(marks: [GuideGridSnapshot.TimelineMark], isAlternate: Bool) {
        backgroundColor = UIColor(
            isAlternate ? AppTheme.chrome.opacity(0.42) : AppTheme.background
        )
        while lineLayers.count < marks.count {
            let line = CALayer()
            line.backgroundColor = UIColor(AppTheme.divider).cgColor
            layer.addSublayer(line)
            lineLayers.append(line)
        }
        for (index, line) in lineLayers.enumerated() {
            line.isHidden = index >= marks.count
            if marks.indices.contains(index) {
                line.frame = CGRect(
                    x: marks[index].x,
                    y: 0,
                    width: 1,
                    height: GuideGridMetrics.rowHeight
                )
            }
        }
    }
}

@MainActor
private final class GuideTimelineHeaderReusableView: UICollectionReusableView {
    private let content = UIView()
    private var revision: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(AppTheme.chrome)
        clipsToBounds = true
        addSubview(content)
        let divider = UIView()
        divider.backgroundColor = UIColor(AppTheme.divider)
        divider.tag = 999
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(snapshot: GuideGridSnapshot) {
        guard revision != snapshot.revision else { return }
        revision = snapshot.revision
        content.subviews.forEach { $0.removeFromSuperview() }
        content.frame = CGRect(
            x: 0,
            y: 0,
            width: snapshot.timeline.width,
            height: GuideGridMetrics.headerHeight
        )
        for mark in snapshot.marks {
            let label = UILabel(frame: CGRect(x: mark.x + 10, y: 7, width: 170, height: 27))
            label.text = mark.title
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
            content.addSubview(label)

            let tick = UIView(frame: CGRect(x: mark.x + 10, y: 36, width: 1, height: 13))
            tick.backgroundColor = UIColor(AppTheme.divider)
            content.addSubview(tick)
        }
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        guard let attributes = layoutAttributes as? GuideTimelineLayoutAttributes else { return }
        content.transform = CGAffineTransform(translationX: -attributes.horizontalOffset, y: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        viewWithTag(999)?.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}

@MainActor
private final class GuideCornerHeaderReusableView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(AppTheme.chrome)

        let image = UIImageView(image: UIImage(systemName: "clock"))
        image.tintColor = UIColor(AppTheme.accent)
        image.frame = CGRect(x: 82, y: 18, width: 22, height: 22)
        addSubview(image)

        let label = UILabel(frame: CGRect(x: 112, y: 12, width: 92, height: 34))
        label.text = "NOW"
        label.textColor = UIColor(AppTheme.accent)
        label.font = .systemFont(ofSize: 16, weight: .bold)
        addSubview(label)

        let divider = UIView(frame: CGRect(x: 0, y: GuideGridMetrics.headerHeight - 1, width: GuideGridMetrics.channelWidth, height: 1))
        divider.backgroundColor = UIColor(AppTheme.divider)
        addSubview(divider)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class GuideNowIndicatorReusableView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .red
        let cap = UIView(frame: CGRect(x: -5, y: -6, width: 13, height: 13))
        cap.backgroundColor = .red
        cap.layer.cornerRadius = 6.5
        addSubview(cap)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class GuideChannelHeaderReusableView: UICollectionReusableView {
    private let badgeView = UIView()
    private let logoView = UIImageView()
    private let monogramLabel = UILabel()
    private let nameLabel = UILabel()
    private var logoTask: Task<Void, Never>?
    private var representedChannelID: GuideChannel.ID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(AppTheme.chrome)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        clipsToBounds = true

        badgeView.clipsToBounds = true
        badgeView.layer.cornerRadius = 24
        badgeView.layer.borderWidth = 1
        badgeView.layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor
        addSubview(badgeView)

        logoView.contentMode = .scaleAspectFit
        badgeView.addSubview(logoView)
        monogramLabel.textAlignment = .center
        monogramLabel.textColor = .white
        monogramLabel.font = .systemFont(ofSize: 15, weight: .black)
        badgeView.addSubview(monogramLabel)

        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        nameLabel.numberOfLines = 3
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.65
        addSubview(nameLabel)

        let trailing = UIView()
        trailing.backgroundColor = UIColor(AppTheme.divider)
        trailing.tag = 1
        addSubview(trailing)
        let bottom = UIView()
        bottom.backgroundColor = UIColor(AppTheme.divider)
        bottom.tag = 2
        addSubview(bottom)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        logoTask?.cancel()
        representedChannelID = nil
        logoView.image = nil
    }

    func configure(channel: GuideChannel, configuration: TVHeadendConfiguration?) {
        representedChannelID = channel.id
        nameLabel.text = channel.name
        monogramLabel.text = channel.monogram
        accessibilityLabel = channel.name
        badgeView.backgroundColor = UIColor(channel.tint)
        logoView.image = nil
        monogramLabel.isHidden = false
        logoTask?.cancel()

        guard let url = channel.iconURL else { return }
        if let artwork = ChannelLogoImageCache.shared.memoryArtwork(for: url) {
            apply(artwork: artwork, channelID: channel.id)
            return
        }

        guard let configuration else { return }

        logoTask = Task { [weak self] in
            do {
                let artwork = try await ChannelLogoDataLoader.shared.artwork(
                    at: url,
                    configuration: configuration
                )
                guard !Task.isCancelled else { return }
                self?.apply(artwork: artwork, channelID: channel.id)
            } catch {
                // The monogram is the permanent fallback for a failed logo.
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        badgeView.frame = CGRect(x: 14, y: (bounds.height - 48) / 2, width: 48, height: 48)
        logoView.frame = badgeView.bounds.insetBy(dx: 6, dy: 6)
        monogramLabel.frame = badgeView.bounds
        nameLabel.frame = CGRect(x: 74, y: 6, width: max(0, bounds.width - 88), height: bounds.height - 12)
        viewWithTag(1)?.frame = CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        viewWithTag(2)?.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    private func apply(artwork: ChannelLogoArtwork, channelID: GuideChannel.ID) {
        guard representedChannelID == channelID else { return }
        logoView.image = artwork.image
        monogramLabel.isHidden = true
        switch artwork.backgroundTone {
        case .light:
            badgeView.backgroundColor = UIColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1)
        case .dark:
            badgeView.backgroundColor = UIColor(red: 0.055, green: 0.065, blue: 0.085, alpha: 1)
        case nil:
            break
        }
    }
}
#else
/// Native macOS guide surface. The shared snapshot keeps programme geometry
/// identical to the television grid, while SwiftUI provides standard pointer,
/// scrolling, keyboard-focus, and context-menu behavior.
struct GuideGridView: View {
    let channels: [GuideChannel]
    let timeline: GuideTimeline
    let now: Date
    let guideRevision: Int
    let preferredProgramID: GuideProgram.ID?
    let focusScope: Namespace.ID
    @Binding var focusedProgramID: GuideProgram.ID?
    let recenterRequest: UUID
    let focusRestoreRequest: UUID
    let recordingsRevision: Int
    let configuration: TVHeadendConfiguration
    let recordingState: (GuideProgram) -> TVRecordingState?
    let onActivate: (GuideProgram) -> Void
    let onPlay: (GuideProgram) -> Void
    let onReady: () -> Void

    private var visiblePrograms: [[GuideProgram]] {
        channels.map { channel in
            channel.programs.filter { $0.end > timeline.start && $0.start < timeline.end }
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { row, channel in
                        HStack(spacing: 0) {
                            channelLabel(channel)
                                .guidePinnedToLeadingEdge()
                                .zIndex(1)

                            ZStack(alignment: .topLeading) {
                                ForEach(visiblePrograms[row]) { program in
                                    let interval = DateInterval(
                                        start: max(program.start, timeline.start),
                                        end: min(program.end, timeline.end)
                                    )
                                    Button {
                                        focusedProgramID = program.id
                                        onActivate(program)
                                    } label: {
                                        GuideProgramCard(
                                            program: program,
                                            now: now,
                                            isFocused: focusedProgramID == program.id,
                                            recordingState: recordingState(program),
                                            leadingContentInset: 0
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(
                                        width: max(56, timeline.width(for: interval) - GuideGridMetrics.cardInset),
                                        height: GuideGridMetrics.cardHeight
                                    )
                                    .offset(x: timeline.xOffset(for: interval.start) + 2)
                                    .contextMenu {
                                        Button("Programme Details", systemImage: "info.circle") {
                                            onActivate(program)
                                        }
                                        Button("Watch", systemImage: "play.fill") {
                                            onPlay(program)
                                        }
                                    }
                                }
                            }
                            .frame(
                                width: timeline.width,
                                height: GuideGridMetrics.rowHeight,
                                alignment: .topLeading
                            )
                            .background(row.isMultiple(of: 2) ? AppTheme.background : AppTheme.surface.opacity(0.22))
                        }
                    }
                } header: {
                    HStack(spacing: 0) {
                        Label("Guide", systemImage: "clock")
                            .font(.headline)
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 18)
                            .frame(width: GuideGridMetrics.channelWidth, height: GuideGridMetrics.headerHeight, alignment: .leading)
                            .background(AppTheme.chrome)
                            .guidePinnedToLeadingEdge()
                            .zIndex(1)

                        ZStack(alignment: .topLeading) {
                            ForEach(timeline.halfHourMarks, id: \.self) { mark in
                                Text(mark.formatted(date: .omitted, time: .shortened))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .offset(x: timeline.xOffset(for: mark) + 10, y: 10)
                            }
                        }
                        .frame(
                            width: timeline.width,
                            height: GuideGridMetrics.headerHeight,
                            alignment: .topLeading
                        )
                        .background(AppTheme.chrome)
                    }
                }
            }
        }
        .background(AppTheme.background)
        .onAppear {
            if focusedProgramID == nil { focusedProgramID = preferredProgramID }
            onReady()
        }
        .onChange(of: focusRestoreRequest) { _, _ in
            focusedProgramID = preferredProgramID ?? focusedProgramID
        }
        .onChange(of: recenterRequest) { _, _ in
            focusedProgramID = preferredProgramID ?? focusedProgramID
        }
    }

    private func channelLabel(_ channel: GuideChannel) -> some View {
        HStack(spacing: 12) {
            ChannelBadge(channel: channel, diameter: 52)
            Text(channel.name)
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: GuideGridMetrics.channelWidth, height: GuideGridMetrics.rowHeight)
        .background(AppTheme.chrome)
    }
}

private extension View {
    /// Keeps the channel column fixed while the surrounding two-axis guide
    /// scroll view moves its timeline content horizontally.
    func guidePinnedToLeadingEdge() -> some View {
        visualEffect { content, geometry in
            content.offset(
                x: max(
                    0,
                    -geometry.frame(in: .scrollView(axis: .horizontal)).minX
                )
            )
        }
    }
}
#endif
