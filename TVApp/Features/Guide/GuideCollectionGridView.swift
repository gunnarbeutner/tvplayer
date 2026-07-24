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
    static let headerContentHeight: CGFloat = 34
    static let headerContentY = (headerHeight - headerContentHeight) / 2
    static let timelineMarkLeadingInset: CGFloat = 10
    static let timelineTickY: CGFloat = 43
    static let timelineTickHeight: CGFloat = 14
    static let nowIndicatorWidth: CGFloat = 3
    static let nowIndicatorCapDiameter: CGFloat = 13
    static let rowHeight: CGFloat = 94
    static let cardInset: CGFloat = 5
    static let rowInset: CGFloat = 5
    static let cardHeight = rowHeight - (rowInset * 2)
    static let focusTargetWidth: CGFloat = 120

    static func nowIndicatorX(in timeline: GuideTimeline, at date: Date) -> CGFloat? {
        guard timeline.start <= date, date <= timeline.end else { return nil }
        return timeline.xOffset(for: date)
    }
}

enum GuideFocusScrollPosition {
    /// SwiftUI can update the representable before UIKit has assigned its
    /// final bounds. Treating that zero/tiny viewport as real would scroll the
    /// first row down, only for the next focus retry to move it back to zero.
    static func targetOffset(
        itemFrame: CGRect,
        currentOffset: CGPoint,
        viewportSize: CGSize,
        contentSize: CGSize
    ) -> CGPoint? {
        guard hasStableViewport(viewportSize) else { return nil }

        var target = currentOffset
        let visibleTop = target.y + GuideGridMetrics.headerHeight
        let visibleBottom = target.y + viewportSize.height
        if itemFrame.minY < visibleTop {
            target.y = max(
                0,
                itemFrame.minY - GuideGridMetrics.headerHeight - GuideGridMetrics.rowInset
            )
        } else if itemFrame.maxY > visibleBottom {
            target.y = min(
                max(0, contentSize.height - viewportSize.height),
                itemFrame.maxY - viewportSize.height + GuideGridMetrics.rowInset
            )
        }

        let pinnedTrailingEdge = target.x + GuideGridMetrics.channelWidth + 8
        if itemFrame.minX < pinnedTrailingEdge {
            target.x = max(0, itemFrame.minX - GuideGridMetrics.channelWidth - 8)
        }

        let focusTargetWidth = min(itemFrame.width, GuideGridMetrics.focusTargetWidth)
        let focusTargetTrailingEdge = itemFrame.minX + focusTargetWidth + 8
        let visibleTrailingEdge = target.x + viewportSize.width
        if focusTargetTrailingEdge > visibleTrailingEdge {
            target.x = min(
                max(0, contentSize.width - viewportSize.width),
                focusTargetTrailingEdge - viewportSize.width
            )
        }
        return target
    }

    static func channelHeaderTargetOffset(
        section: Int,
        currentOffset: CGPoint,
        viewportSize: CGSize,
        contentSize: CGSize
    ) -> CGPoint? {
        guard hasStableViewport(viewportSize) else { return nil }

        let headerFrame = CGRect(
            x: currentOffset.x,
            y: GuideGridMetrics.headerHeight
                + CGFloat(section) * GuideGridMetrics.rowHeight
                + GuideGridMetrics.rowInset,
            width: GuideGridMetrics.channelWidth,
            height: GuideGridMetrics.cardHeight
        )
        var target = currentOffset
        let visibleTop = target.y + GuideGridMetrics.headerHeight
        let visibleBottom = target.y + viewportSize.height
        if headerFrame.minY < visibleTop {
            target.y = max(
                0,
                headerFrame.minY - GuideGridMetrics.headerHeight - GuideGridMetrics.rowInset
            )
        } else if headerFrame.maxY > visibleBottom {
            target.y = min(
                max(0, contentSize.height - viewportSize.height),
                headerFrame.maxY - viewportSize.height + GuideGridMetrics.rowInset
            )
        }
        return target
    }

    static func hasStableViewport(_ viewportSize: CGSize) -> Bool {
        viewportSize.width > 0
            && viewportSize.height >= GuideGridMetrics.headerHeight + GuideGridMetrics.rowHeight
    }
}

enum GuideFocusPresentation {
    static func selectionProgramID(
        requested: GuideProgram.ID?,
        pending: GuideProgram.ID?,
        preferred: GuideProgram.ID?,
        isChannelFocusActive: Bool = false
    ) -> GuideProgram.ID? {
        guard !isChannelFocusActive else { return nil }
        return pending ?? requested ?? preferred
    }

    static func showsPendingFocus(
        programID: GuideProgram.ID,
        pendingProgramID: GuideProgram.ID?,
        currentlyFocusedProgramID: GuideProgram.ID?
    ) -> Bool {
        currentlyFocusedProgramID == nil && programID == pendingProgramID
    }

    static func presentsProgramFocus(
        isUIKitFocused: Bool,
        showsPendingFocus: Bool,
        isChannelFocusActive: Bool
    ) -> Bool {
        !isChannelFocusActive && (isUIKitFocused || showsPendingFocus)
    }

    static func allowsProgramFocus(
        programID: GuideProgram.ID,
        pendingProgramID: GuideProgram.ID?,
        isGuideEnabled: Bool
    ) -> Bool {
        guard isGuideEnabled else { return false }
        if let pendingProgramID {
            return pendingProgramID == programID
        }
        return true
    }

    static func shouldCommitChannelFocus(
        pendingProgramID: GuideProgram.ID?
    ) -> Bool {
        pendingProgramID == nil
    }

    static func shouldCommitProgramFocus(
        channelSnapshotRestoreID: GuideChannel.ID?
    ) -> Bool {
        channelSnapshotRestoreID == nil
    }

    static func programFocusRestoreTarget(
        programID: GuideProgram.ID?,
        isRestoreRequest: Bool,
        hasChannelFocus: Bool
    ) -> GuideProgram.ID? {
        guard isRestoreRequest, !hasChannelFocus else { return nil }
        return programID
    }
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
    /// The cell receiving the press is the only synchronous source of truth.
    /// UIKit's visible-cell focus flags and our pending target can both be in
    /// transition while that press is being delivered.
    static func inputOrigin(
        confirmedProgramID _: GuideProgram.ID?,
        pendingProgramID _: GuideProgram.ID?,
        eventProgramID: GuideProgram.ID
    ) -> GuideProgram.ID {
        eventProgramID
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
    let channelPreferencesRevision: Int
    let preferredProgramID: GuideProgram.ID?
    let playingProgramID: GuideProgram.ID?
    let focusScope: Namespace.ID
    @Binding var focusedProgramID: GuideProgram.ID?
    let recenterRequest: UUID
    let focusRestoreRequest: UUID
    let recordingsRevision: Int
    let configuration: TVHeadendConfiguration
    let isFavorite: (GuideChannel.ID) -> Bool
    let onToggleFavorite: (GuideChannel.ID) -> Void
    let recordingState: (GuideProgram) -> TVRecordingState?
    let onActivate: (GuideProgram) -> Void
    let onPlay: (GuideProgram) -> Void
    let onReady: () -> Void
    let onFocusAcquired: () -> Void
    let onExitToNavigator: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GuideCollectionRepresentable(
            channels: channels,
            timeline: timeline,
            now: now,
            guideRevision: guideRevision,
            channelPreferencesRevision: channelPreferencesRevision,
            preferredProgramID: preferredProgramID,
            playingProgramID: playingProgramID,
            focusedProgramID: $focusedProgramID,
            recenterRequest: recenterRequest,
            focusRestoreRequest: focusRestoreRequest,
            recordingsRevision: recordingsRevision,
            configuration: configuration,
            isFavorite: isFavorite,
            onToggleFavorite: onToggleFavorite,
            recordingState: recordingState,
            onActivate: onActivate,
            onPlay: onPlay,
            onFirstSnapshotApplied: onReady,
            onFocusAcquired: onFocusAcquired,
            onExitToNavigator: onExitToNavigator,
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
    let channelPreferencesRevision: Int
    let preferredProgramID: GuideProgram.ID?
    let playingProgramID: GuideProgram.ID?
    @Binding var focusedProgramID: GuideProgram.ID?
    let recenterRequest: UUID
    let focusRestoreRequest: UUID
    let recordingsRevision: Int
    let configuration: TVHeadendConfiguration
    let isFavorite: (GuideChannel.ID) -> Bool
    let onToggleFavorite: (GuideChannel.ID) -> Void
    let recordingState: (GuideProgram) -> TVRecordingState?
    let onActivate: (GuideProgram) -> Void
    let onPlay: (GuideProgram) -> Void
    let onFirstSnapshotApplied: () -> Void
    let onFocusAcquired: () -> Void
    let onExitToNavigator: () -> Void
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
            channelPreferencesRevision: channelPreferencesRevision,
            preferredProgramID: preferredProgramID,
            playingProgramID: playingProgramID,
            focusedProgramID: focusedProgramID,
            recenterRequest: recenterRequest,
            focusRestoreRequest: focusRestoreRequest,
            recordingsRevision: recordingsRevision,
            configuration: configuration,
            isFavorite: isFavorite,
            onToggleFavorite: onToggleFavorite,
            recordingState: recordingState,
            onFocused: {
                focusedProgramID = $0
                onFocusAcquired()
            },
            onActivate: onActivate,
            onPlay: onPlay,
            onFirstSnapshotApplied: onFirstSnapshotApplied,
            onExitToNavigator: onExitToNavigator,
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
            let indicatorX = GuideGridMetrics.nowIndicatorX(in: snapshot.timeline, at: now)
            attributes.frame = CGRect(
                x: GuideGridMetrics.channelWidth
                    + (indicatorX ?? 0)
                    - GuideGridMetrics.nowIndicatorWidth / 2,
                y: offset.y + GuideGridMetrics.headerHeight,
                width: indicatorX == nil ? 0 : GuideGridMetrics.nowIndicatorWidth,
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
    private var focusVisibilityCorrectionTask: Task<Void, Never>?
    private var focusRequestAwaitingStableLayout: (
        programID: GuideProgram.ID,
        retriesRemaining: Int,
        directly: Bool
    )?
    private var channelFocusRetryTask: Task<Void, Never>?
    private var requestedGuideRevision: Int?
    private var requestedChannelPreferencesRevision: Int?
    private var appliedRecordingsRevision: Int?
    private var appliedRecenterRequest: UUID?
    private var appliedFocusRestoreRequest: UUID?
    private var requestedFocusedProgramID: GuideProgram.ID?
    private var preferredProgramID: GuideProgram.ID?
    private var playingProgramID: GuideProgram.ID?
    private var pendingFocusProgramID: GuideProgram.ID?
    private var pendingChannelProgramID: GuideProgram.ID?
    private var focusedChannelID: GuideChannel.ID?
    private var focusedChannelReturnProgramID: GuideProgram.ID?
    private var channelIDAwaitingSnapshotFocus: GuideChannel.ID?
    private var channelReturnProgramIDAwaitingSnapshotFocus: GuideProgram.ID?
    private var navigationSignpostID: OSSignpostID?
#if os(tvOS)
    private var pageCommandObserver: NSObjectProtocol?
#endif
    private var currentNow = Date()
    private var currentConfiguration: TVHeadendConfiguration?
    private var isGuideEnabled = true

    private var recordingState: (GuideProgram) -> TVRecordingState? = { _ in nil }
    private var isFavorite: (GuideChannel.ID) -> Bool = { _ in false }
    private var onToggleFavorite: (GuideChannel.ID) -> Void = { _ in }
    private var onFocused: (GuideProgram.ID) -> Void = { _ in }
    private var onActivate: (GuideProgram) -> Void = { _ in }
    private var onPlay: (GuideProgram) -> Void = { _ in }
    private var onFirstSnapshotApplied: () -> Void = {}
    private var onExitToNavigator: () -> Void = {}
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

#if os(tvOS)
        let playPauseRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handlePlayPausePress(_:))
        )
        playPauseRecognizer.allowedPressTypes = [
            NSNumber(value: UIPress.PressType.playPause.rawValue)
        ]
        addGestureRecognizer(playPauseRecognizer)

        pageCommandObserver = NotificationCenter.default.addObserver(
            forName: .tvGuidePageCommand,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?["direction"] as? Int,
                  let direction = TVPageDirection(rawValue: raw)
            else { return }
            Task { @MainActor in self?.page(direction) }
        }
#endif
    }

#if os(tvOS)
    @objc private func handlePlayPausePress(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              isGuideEnabled,
              let snapshot = guideSnapshot,
              let programID = currentlyFocusedProgramID,
              let indexPath = snapshot.indexPath(for: programID),
              let item = snapshot.item(at: indexPath)
        else { return }

        onPlay(item.program)
    }
#endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard GuideFocusScrollPosition.hasStableViewport(bounds.size),
              let request = focusRequestAwaitingStableLayout
        else { return }

        focusRequestAwaitingStableLayout = nil
        requestFocus(
            on: request.programID,
            retriesRemaining: request.retriesRemaining,
            directly: request.directly
        )
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let pendingChannelProgramID,
           let section = guideSnapshot?.indexPath(for: pendingChannelProgramID)?.section,
           let header = supplementaryView(
                forElementKind: GuideCollectionElementKind.channelHeader,
                at: IndexPath(item: 0, section: section)
           ) {
            return [header]
        }
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
        channelPreferencesRevision: Int,
        preferredProgramID: GuideProgram.ID?,
        playingProgramID: GuideProgram.ID?,
        focusedProgramID: GuideProgram.ID?,
        recenterRequest: UUID,
        focusRestoreRequest: UUID,
        recordingsRevision: Int,
        configuration: TVHeadendConfiguration,
        isFavorite: @escaping (GuideChannel.ID) -> Bool,
        onToggleFavorite: @escaping (GuideChannel.ID) -> Void,
        recordingState: @escaping (GuideProgram) -> TVRecordingState?,
        onFocused: @escaping (GuideProgram.ID) -> Void,
        onActivate: @escaping (GuideProgram) -> Void,
        onPlay: @escaping (GuideProgram) -> Void,
        onFirstSnapshotApplied: @escaping () -> Void,
        onExitToNavigator: @escaping () -> Void,
        isEnabled: Bool
    ) {
        self.preferredProgramID = preferredProgramID
        let playingProgramChanged = self.playingProgramID != playingProgramID
        self.playingProgramID = playingProgramID
        let previousRequestedFocusedProgramID = requestedFocusedProgramID
        requestedFocusedProgramID = focusedProgramID
        currentConfiguration = configuration
        self.isFavorite = isFavorite
        self.onToggleFavorite = onToggleFavorite
        self.recordingState = recordingState
        self.onFocused = onFocused
        self.onActivate = onActivate
        self.onPlay = onPlay
        self.onFirstSnapshotApplied = onFirstSnapshotApplied
        self.onExitToNavigator = onExitToNavigator
        isGuideEnabled = isEnabled
#if DEBUG && os(tvOS)
        TVGuideAutomationFocusRecorder.shared.updateGuide(
            channelIDs: channels.map(\.id),
            favoriteChannelIDs: Set(
                channels.lazy.filter { isFavorite($0.id) }.map(\.id)
            )
        )
#endif

        if previousRequestedFocusedProgramID != focusedProgramID {
            reconfigureVisibleProgrammeCells()
        }
        if playingProgramChanged {
            reconfigureVisibleProgrammeCells()
        }

        if currentNow != now {
            currentNow = now
            guideLayout.now = now
            reconfigureVisibleProgrammeCells()
        }

        if requestedGuideRevision != guideRevision
            || requestedChannelPreferencesRevision != channelPreferencesRevision {
            requestedGuideRevision = guideRevision
            requestedChannelPreferencesRevision = channelPreferencesRevision
            buildSnapshot(
                channels: channels,
                timeline: timeline,
                revision: guideRevision,
                channelPreferencesRevision: channelPreferencesRevision
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

        if let focusRestoreTarget = GuideFocusPresentation.programFocusRestoreTarget(
            programID: focusedProgramID,
            isRestoreRequest: isRestoreRequest,
            hasChannelFocus: hasChannelFocus
        ) {
            // Focus currently belongs to the disappearing player layer or to
            // the TabView's bar. Target the exact programme cell through the
            // window focus system so the tab bar cannot retain focus simply
            // because it sits outside this collection view's subtree.
            requestFocus(
                on: focusRestoreTarget,
                retriesRemaining: 8,
                directly: true
            )
        } else if !hasChannelFocus,
                  let focusedProgramID,
                  focusedProgramID != previousRequestedFocusedProgramID,
                  focusedProgramID != currentlyFocusedProgramID,
                  guideSnapshot?.indexPath(for: focusedProgramID) != nil {
            requestFocus(on: focusedProgramID, retriesRemaining: 4)
        }
    }

    func cancelPendingWork() {
        snapshotBuildTask?.cancel()
        focusRetryTask?.cancel()
        focusVisibilityCorrectionTask?.cancel()
        channelFocusRetryTask?.cancel()
        focusRequestAwaitingStableLayout = nil
#if os(tvOS)
        if let pageCommandObserver {
            NotificationCenter.default.removeObserver(pageCommandObserver)
            self.pageCommandObserver = nil
        }
#endif
    }

#if os(tvOS)
    private func page(_ direction: TVPageDirection) {
        guard isGuideEnabled, let snapshot = guideSnapshot else { return }
        let originID = currentlyFocusedProgramID
            ?? requestedFocusedProgramID
            ?? preferredProgramID
        guard let originID,
              let origin = snapshot.locationByProgramID[originID]
        else { return }

        let visibleRows = max(
            1,
            Int((bounds.height - GuideGridMetrics.headerHeight) / GuideGridMetrics.rowHeight)
        )
        let targetRow = min(
            max(0, origin.row + direction.rawValue * visibleRows),
            snapshot.rows.count - 1
        )
        let originProgram = snapshot.rows[origin.row][origin.item].program
        let reference = originProgram.isAiring(at: currentNow)
            ? currentNow
            : originProgram.start.addingTimeInterval(originProgram.duration / 2)
        guard let target = snapshot.rows[targetRow].min(by: {
            Self.distance(from: reference, to: $0.program)
                < Self.distance(from: reference, to: $1.program)
        }) else { return }
        requestFocus(on: target.id, retriesRemaining: 6, directly: true)
    }

    private static func distance(from date: Date, to program: GuideProgram) -> TimeInterval {
        if date < program.start { return program.start.timeIntervalSince(date) }
        if date >= program.end { return date.timeIntervalSince(program.end) }
        return 0
    }
#endif

    private func buildSnapshot(
        channels: [GuideChannel],
        timeline: GuideTimeline,
        revision: Int,
        channelPreferencesRevision: Int
    ) {
        snapshotBuildTask?.cancel()
        os_signpost(.begin, log: guidePerformanceLog, name: "GuideSnapshotBuild", "revision=%d", revision)

        // Persisted guide data is loaded before SwiftUI creates this view. Build
        // the first layout snapshot in this update pass so the collection view
        // is complete for its first rendered frame. Later refreshes remain
        // detached to keep an already interactive guide responsive.
        if guideSnapshot == nil {
            let snapshot = GuideGridSnapshot(
                channels: channels,
                timeline: timeline,
                revision: revision
            )
            guard requestedGuideRevision == revision,
                  requestedChannelPreferencesRevision == channelPreferencesRevision
            else { return }
            os_signpost(.end, log: guidePerformanceLog, name: "GuideSnapshotBuild", "revision=%d", revision)
            apply(snapshot)
            return
        }

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
                  self.requestedGuideRevision == revision,
                  self.requestedChannelPreferencesRevision == channelPreferencesRevision
            else { return }
            os_signpost(.end, log: guidePerformanceLog, name: "GuideSnapshotBuild", "revision=%d", revision)
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: GuideGridSnapshot) {
        os_signpost(.begin, log: guidePerformanceLog, name: "GuideSnapshotApply", "rows=%d", snapshot.rows.count)
        let channelFocusToRestore = channelIDAwaitingSnapshotFocus ?? focusedChannelID
        let returnProgramID = channelReturnProgramIDAwaitingSnapshotFocus
            ?? focusedChannelReturnProgramID
        guideSnapshot = snapshot
        guideLayout.snapshot = snapshot
        guideLayout.now = currentNow
#if DEBUG && os(tvOS)
        TVGuideAutomationFocusRecorder.shared.updateFocusOrder(
            channelIDs: zip(snapshot.channels, snapshot.rows).compactMap {
                $0.1.isEmpty ? nil : $0.0.id
            }
        )
#endif
        UIView.performWithoutAnimation {
            reloadData()
            layoutIfNeeded()
            // A focused collection-view cell can survive reloadData() at the
            // same index path. Refresh every retained cell explicitly so its
            // programme ID and callbacks match the newly applied snapshot.
            reconfigureVisibleProgrammeCells()
        }
        os_signpost(.end, log: guidePerformanceLog, name: "GuideSnapshotApply", "rows=%d", snapshot.rows.count)

        if !hasReportedFirstSnapshot {
            hasReportedFirstSnapshot = true
            onFirstSnapshotApplied()
        }

        if let channelFocusToRestore,
           let returnProgramID,
           snapshot.channels.contains(where: { $0.id == channelFocusToRestore }) {
            requestFocusOnChannel(
                channelFocusToRestore,
                returningTo: returnProgramID
            )
            return
        }

        let focusID = requestedFocusedProgramID ?? preferredProgramID
        if let focusID, snapshot.indexPath(for: focusID) != nil {
            requestFocus(on: focusID, retriesRemaining: 4)
        }
    }

    private var currentlyFocusedProgramID: GuideProgram.ID? {
        visibleCells.lazy
            .compactMap { $0 as? GuideProgrammeCollectionCell }
            .first(where: \.isFocused)?
            .programID
    }

    private var currentlyFocusedChannelID: GuideChannel.ID? {
        visibleSupplementaryViews(ofKind: GuideCollectionElementKind.channelHeader)
            .lazy
            .compactMap { $0 as? GuideChannelHeaderReusableView }
            .first(where: \.isFocused)?
            .representedChannelID
    }

    private var hasChannelFocus: Bool {
        pendingChannelProgramID != nil
            || focusedChannelID != nil
            || currentlyFocusedChannelID != nil
            || channelIDAwaitingSnapshotFocus != nil
    }

    private var suppressesProgramFocus: Bool {
        hasChannelFocus && pendingFocusProgramID == nil
    }

    private func currentProgramID(for channelID: GuideChannel.ID) -> GuideProgram.ID? {
        guard let snapshot = guideSnapshot,
              let section = snapshot.channels.firstIndex(where: { $0.id == channelID })
        else { return nil }

        return snapshot.rows[section]
            .first(where: { $0.program.isAiring(at: currentNow) })?
            .id
    }

    private func scrollToLeadingEdge(animated: Bool) {
        let target = CGPoint(x: 0, y: max(0, contentOffset.y))
        setContentOffset(target, animated: animated)
    }

    private func requestFocus(
        on programID: GuideProgram.ID,
        retriesRemaining: Int,
        directly: Bool = false
    ) {
        channelFocusRetryTask?.cancel()
        channelFocusRetryTask = nil
        guard let snapshot = guideSnapshot,
              let indexPath = snapshot.indexPath(for: programID),
              let item = snapshot.item(at: indexPath)
        else { return }
        if currentlyFocusedProgramID == programID {
            pendingFocusProgramID = nil
            focusRequestAwaitingStableLayout = nil
            updateFocusAvailability()
            return
        }

        pendingFocusProgramID = programID
        pendingChannelProgramID = nil
        focusedChannelID = nil
        focusedChannelReturnProgramID = nil
        updateFocusAvailability()
        // Explicit focus requests need stable presentation geometry. The
        // custom layout realizes cells beyond the viewport, so a destination
        // can exist while its reveal animation is still moving it. tvOS may
        // ignore that focus request or leave the grid without a focused item.
        guard let targetOffset = GuideFocusScrollPosition.targetOffset(
            itemFrame: item.frame,
            currentOffset: contentOffset,
            viewportSize: bounds.size,
            contentSize: contentSize
        ) else {
            // UIKit will lay out the collection before its first visible
            // frame. Resume there instead of waiting for a timer, so the
            // correct focus appearance is present in that frame too.
            focusRetryTask?.cancel()
            focusRetryTask = nil
            let previousRequest = focusRequestAwaitingStableLayout
            focusRequestAwaitingStableLayout = (
                programID: programID,
                retriesRemaining: max(
                    retriesRemaining,
                    previousRequest?.programID == programID
                        ? previousRequest?.retriesRemaining ?? 0
                        : 0
                ),
                directly: directly || (
                    previousRequest?.programID == programID
                        ? previousRequest?.directly ?? false
                        : false
                )
            )
            setNeedsLayout()
            return
        }
        if targetOffset != contentOffset {
            setContentOffset(targetOffset, animated: false)
        }
        focusRequestAwaitingStableLayout = nil
        layoutIfNeeded()
        if directly,
           let targetCell = cellForItem(at: indexPath),
           let focusSystem = UIFocusSystem.focusSystem(for: targetCell) {
            // A direct UIFocusSystem request can be ignored when a custom
            // collection layout has just materialized or repositioned the
            // target. First invalidate this focus environment so its exact
            // pending cell is consulted through preferredFocusEnvironments.
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            if !targetCell.isFocused {
                focusSystem.requestFocusUpdate(to: targetCell)
                focusSystem.updateFocusIfNeeded()
            }
        } else {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }

        guard currentlyFocusedProgramID != programID else { return }
        scheduleFocusRetry(
            on: programID,
            retriesRemaining: retriesRemaining,
            directly: directly
        )
    }

    private func scheduleFocusRetry(
        on programID: GuideProgram.ID,
        retriesRemaining: Int,
        directly: Bool
    ) {
        guard retriesRemaining > 0 else {
            if pendingFocusProgramID == programID {
                pendingFocusProgramID = nil
                focusRequestAwaitingStableLayout = nil
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
                    retriesRemaining: retriesRemaining - 1,
                    directly: directly
                )
            } catch {
                // A newer focus request superseded this retry.
            }
        }
    }

    private func reveal(item: GuideGridSnapshot.Item, animated: Bool) -> Bool {
        guard let target = GuideFocusScrollPosition.targetOffset(
            itemFrame: item.frame,
            currentOffset: contentOffset,
            viewportSize: bounds.size,
            contentSize: contentSize
        ) else { return false }
        if target != contentOffset {
            setContentOffset(target, animated: animated)
        }
        return true
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
            if direction == .left {
                requestFocusOnChannel(for: origin)
                return .consumed
            }
            if direction == .up,
               snapshot.isAtBoundary(programID: origin, direction: .up) {
                // Never let tvOS choose a tab geometrically. Cards far to the
                // right have no tab directly above them, and native focus can
                // either fail or briefly land on a neighbouring section.
                onExitToNavigator()
            }
            return .consumed
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
        // UIKit's own geometric focus resolution is unreliable once a card
        // spans an irregular width (e.g. a long programme): its candidate can
        // land on the wrong neighbour. Always resolve the destination from
        // the indexed snapshot instead of delegating to a native focus move.
        requestFocus(
            on: destination,
            retriesRemaining: 8,
            directly: true
        )
        return .consumed
    }

    private func requestFocusOnChannel(for programID: GuideProgram.ID) {
        guard let snapshot = guideSnapshot,
              let programIndexPath = snapshot.indexPath(for: programID),
              let channel = snapshot.channels[safe: programIndexPath.section]
        else { return }
        requestFocusOnChannel(channel.id, returningTo: programID)
    }

    private func requestFocusOnChannel(
        _ channelID: GuideChannel.ID,
        returningTo programID: GuideProgram.ID,
        retriesRemaining: Int = 16
    ) {
        focusVisibilityCorrectionTask?.cancel()
        guard let section = guideSnapshot?.channels.firstIndex(where: { $0.id == channelID })
        else { return }
        let headerIndexPath = IndexPath(item: 0, section: section)
        guard revealChannelHeader(at: section) else {
            scheduleChannelFocusRetry(
                channelID,
                returningTo: programID,
                retriesRemaining: retriesRemaining
            )
            return
        }
        layoutIfNeeded()
        guard let header = supplementaryView(
            forElementKind: GuideCollectionElementKind.channelHeader,
            at: headerIndexPath
        ) as? GuideChannelHeaderReusableView,
              let focusSystem = UIFocusSystem.focusSystem(for: header)
        else {
            scheduleChannelFocusRetry(
                channelID,
                returningTo: programID,
                retriesRemaining: retriesRemaining
            )
            return
        }

        pendingFocusProgramID = nil
        focusRequestAwaitingStableLayout = nil
        pendingChannelProgramID = programID
        focusedChannelID = channelID
        focusedChannelReturnProgramID = programID
        header.returnProgramID = programID
        updateFocusAvailability()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        focusSystem.requestFocusUpdate(to: header)
        focusSystem.updateFocusIfNeeded()
        guard !header.isFocused else {
            channelFocusRetryTask?.cancel()
            channelFocusRetryTask = nil
            return
        }
        scheduleChannelFocusRetry(
            channelID,
            returningTo: programID,
            retriesRemaining: retriesRemaining
        )
    }

    private func revealChannelHeader(at section: Int) -> Bool {
        guard let target = GuideFocusScrollPosition.channelHeaderTargetOffset(
            section: section,
            currentOffset: contentOffset,
            viewportSize: bounds.size,
            contentSize: contentSize
        ) else { return false }
        if target != contentOffset {
            setContentOffset(target, animated: false)
        }
        return true
    }

    private func scheduleChannelFocusRetry(
        _ channelID: GuideChannel.ID,
        returningTo programID: GuideProgram.ID,
        retriesRemaining: Int
    ) {
        guard retriesRemaining > 0 else {
            if channelIDAwaitingSnapshotFocus == channelID {
                channelIDAwaitingSnapshotFocus = nil
                channelReturnProgramIDAwaitingSnapshotFocus = nil
#if DEBUG && os(tvOS)
                TVGuideAutomationFocusRecorder.shared.endChannelRestoration()
#endif
            }
            channelFocusRetryTask = nil
            return
        }
        channelFocusRetryTask?.cancel()
        channelFocusRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                self?.requestFocusOnChannel(
                    channelID,
                    returningTo: programID,
                    retriesRemaining: retriesRemaining - 1
                )
            } catch {
                // A programme focus request superseded this retry.
            }
        }
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

        let origin = programID
        guard let destination = snapshot.destinationProgramID(
            from: origin,
            direction: direction,
            at: currentNow
        ) else {
            if direction == .left {
                let originChannelID = snapshot.indexPath(for: origin)
                    .flatMap { snapshot.channels[safe: $0.section]?.id }
                if let header = context.nextFocusedItem as? GuideChannelHeaderReusableView,
                   header.representedChannelID == originChannelID {
                    header.returnProgramID = origin
                    return true
                }
                Task { @MainActor [weak self] in
                    self?.requestFocusOnChannel(for: origin)
                }
                return false
            }
            if direction == .up,
               snapshot.isAtBoundary(programID: origin, direction: .up) {
                Task { @MainActor [weak self] in
                    self?.onExitToNavigator()
                }
            }
            return false
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
            self.requestFocus(
                on: destination,
                retriesRemaining: 8,
                directly: true
            )
        }
        return false
    }

    private func allowsFocus(on programID: GuideProgram.ID) -> Bool {
        GuideFocusPresentation.allowsProgramFocus(
            programID: programID,
            pendingProgramID: pendingFocusProgramID,
            isGuideEnabled: isGuideEnabled
        )
    }

    private func didFocus(programID: GuideProgram.ID) {
        guard GuideFocusPresentation.shouldCommitProgramFocus(
            channelSnapshotRestoreID: channelIDAwaitingSnapshotFocus
        ) else {
            updateFocusAvailability()
            return
        }
        channelFocusRetryTask?.cancel()
        channelFocusRetryTask = nil
        pendingChannelProgramID = nil
        focusedChannelID = nil
        focusedChannelReturnProgramID = nil
        let previousProgramID = requestedFocusedProgramID
        requestedFocusedProgramID = programID
        pendingFocusProgramID = nil
        focusRequestAwaitingStableLayout = nil
        updateFocusAvailability()
        if previousProgramID != programID {
            // didFocus updates the collection's selection before SwiftUI
            // publishes the same value back through the binding. Repaint now
            // so the previous header programme does not retain its subtle
            // selection border alongside the newly focused card.
            reconfigureVisibleProgrammeCells()
        }
        focusRetryTask?.cancel()
        focusRetryTask = nil
        if let navigationSignpostID {
            os_signpost(.end, log: guidePerformanceLog, name: "GuideInputToFocus", signpostID: navigationSignpostID)
            self.navigationSignpostID = nil
        }
        os_signpost(.event, log: guidePerformanceLog, name: "GuideFocusDidUpdate", "id=%{public}s", programID)
        onFocused(programID)
        scheduleFocusVisibilityCorrection(on: programID)

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

    private func scheduleFocusVisibilityCorrection(on programID: GuideProgram.ID) {
        focusVisibilityCorrectionTask?.cancel()
        focusVisibilityCorrectionTask = Task { @MainActor [weak self] in
            do {
                // Directional repeats keep replacing this task. Once input
                // and focus updates go quiet, finish at the exact offset for
                // the final card instead of trusting the last interrupted
                // UIScrollView animation to catch up.
                try await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled,
                      let self,
                      self.requestedFocusedProgramID == programID,
                      self.pendingFocusProgramID == nil,
                      let snapshot = self.guideSnapshot,
                      let indexPath = snapshot.indexPath(for: programID),
                      let item = snapshot.item(at: indexPath)
                else { return }
                _ = self.reveal(item: item, animated: false)
            } catch {
                // A newer focus update superseded this correction.
            }
        }
    }

    private func updateFocusAvailability() {
        let currentProgramID = currentlyFocusedProgramID
        let selectionProgramID = GuideFocusPresentation.selectionProgramID(
            requested: requestedFocusedProgramID,
            pending: pendingFocusProgramID,
            preferred: preferredProgramID,
            isChannelFocusActive: suppressesProgramFocus
        )
        for case let cell as GuideProgrammeCollectionCell in visibleCells {
            cell.updateFocusState(
                isFocusAllowed: allowsFocus(on: cell.programID),
                isHeaderSelection: cell.programID == selectionProgramID,
                showsPendingFocusAppearance: GuideFocusPresentation.showsPendingFocus(
                    programID: cell.programID,
                    pendingProgramID: pendingFocusProgramID,
                    currentlyFocusedProgramID: currentProgramID
                ),
                isChannelFocusActive: suppressesProgramFocus
            )
        }
        if !isGuideEnabled, currentlyFocusedProgramID != nil {
            setNeedsFocusUpdate()
        }
    }

    private func configure(_ cell: GuideProgrammeCollectionCell, with item: GuideGridSnapshot.Item) {
        let currentProgramID = currentlyFocusedProgramID
        let selectionProgramID = GuideFocusPresentation.selectionProgramID(
            requested: requestedFocusedProgramID,
            pending: pendingFocusProgramID,
            preferred: preferredProgramID,
            isChannelFocusActive: suppressesProgramFocus
        )
        cell.configure(
            item: item,
            now: currentNow,
            recordingState: recordingState(item.program),
            isPlaying: item.id == playingProgramID,
            isHeaderSelection: item.id == selectionProgramID,
            showsPendingFocusAppearance: GuideFocusPresentation.showsPendingFocus(
                programID: item.id,
                pendingProgramID: pendingFocusProgramID,
                currentlyFocusedProgramID: currentProgramID
            ),
            isChannelFocusActive: suppressesProgramFocus,
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
        // UICollectionView may retain its last selected programme while focus is
        // on a supplementary channel header. Do not let a Select press intended
        // for that header activate the stale programme selection.
        guard !hasChannelFocus else {
            collectionView.deselectItem(at: indexPath, animated: false)
            return
        }
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
                view.configure(
                    channel: channel,
                    configuration: currentConfiguration,
                    isFavorite: isFavorite(channel.id),
                    onActivate: { [weak self] returnProgramID in
                        guard let self else { return }
                        self.channelIDAwaitingSnapshotFocus = channel.id
                        self.channelReturnProgramIDAwaitingSnapshotFocus = returnProgramID
                        self.updateFocusAvailability()
#if DEBUG && os(tvOS)
                        TVGuideAutomationFocusRecorder.shared.beginChannelRestoration(
                            channelID: channel.id
                        )
#endif
                        self.onToggleFavorite(channel.id)
                    },
                    onFocused: { [weak self, weak view] returnProgramID in
                        guard let self else { return }
                        // UIKit can reaffirm the currently focused header while
                        // an explicit move back into the programme grid is in
                        // flight. Do not let that transient callback cancel the
                        // programme request and trap focus in this column.
                        guard GuideFocusPresentation.shouldCommitChannelFocus(
                            pendingProgramID: self.pendingFocusProgramID
                        ) else {
                            return
                        }
                        // A favourite toggle rebuilds and reorders the guide
                        // snapshot. Its focus restoration is only needed until
                        // a channel header actually acquires focus. Keeping the
                        // request (and its retry task) alive beyond that point
                        // can override the user's next Up/Down move and snap
                        // focus back to the channel they just toggled.
                        self.channelFocusRetryTask?.cancel()
                        self.channelFocusRetryTask = nil
                        self.focusRetryTask?.cancel()
                        self.focusRetryTask = nil
                        self.channelIDAwaitingSnapshotFocus = nil
                        self.channelReturnProgramIDAwaitingSnapshotFocus = nil
#if DEBUG && os(tvOS)
                        TVGuideAutomationFocusRecorder.shared.endChannelRestoration()
#endif
                        self.pendingFocusProgramID = nil
                        self.focusRequestAwaitingStableLayout = nil
                        self.pendingChannelProgramID = nil
                        self.focusedChannelID = channel.id
                        let selectedProgramID = self.currentProgramID(for: channel.id)
                            ?? returnProgramID
                        view?.returnProgramID = selectedProgramID
                        self.focusedChannelReturnProgramID = selectedProgramID

                        if let selectedProgramID {
                            self.requestedFocusedProgramID = selectedProgramID
                            self.reconfigureVisibleProgrammeCells()
                            self.onFocused(selectedProgramID)
                        }
                    },
                    onMoveRight: { [weak self] programID in
                        self?.requestFocus(
                            on: programID,
                            retriesRemaining: 8,
                            directly: true
                        )
                    },
                    onMoveUp: indexPath.section == 0
                        ? { [weak self] in self?.onExitToNavigator() }
                        : nil
                )
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
    private var item: GuideGridSnapshot.Item?
    private var now = Date()
    private var recordingState: TVRecordingState?
    private var isPlaying = false
    private var isHeaderSelection = false
    private var showsPendingFocusAppearance = false
    private var isChannelFocusActive = false
    private var leadingOcclusion: CGFloat = 0
    private var consumedDirectionalPressTypes: Set<Int> = []
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
#if DEBUG && os(tvOS)
        if let item {
            TVGuideAutomationFocusRecorder.shared.removeProgram(id: item.id)
        }
#endif
        item = nil
        titleLabel.text = nil
        timeLabel.text = nil
        recordingImageView.image = nil
        isPlaying = false
        isHeaderSelection = false
        showsPendingFocusAppearance = false
        isChannelFocusActive = false
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
        isPlaying: Bool,
        isHeaderSelection: Bool,
        showsPendingFocusAppearance: Bool,
        isChannelFocusActive: Bool,
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
        self.isPlaying = isPlaying
        self.isHeaderSelection = isHeaderSelection
        self.showsPendingFocusAppearance = showsPendingFocusAppearance
        self.isChannelFocusActive = isChannelFocusActive
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

    func updateFocusState(
        isFocusAllowed: Bool,
        isHeaderSelection: Bool,
        showsPendingFocusAppearance: Bool,
        isChannelFocusActive: Bool
    ) {
        let appearanceChanged = self.isHeaderSelection != isHeaderSelection
            || self.showsPendingFocusAppearance != showsPendingFocusAppearance
            || self.isChannelFocusActive != isChannelFocusActive
        self.isFocusAllowed = isFocusAllowed
        self.isHeaderSelection = isHeaderSelection
        self.showsPendingFocusAppearance = showsPendingFocusAppearance
        self.isChannelFocusActive = isChannelFocusActive
        if appearanceChanged { updateAppearance(animated: false) }
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
        if let direction = presses.lazy.compactMap(navigationDirection(for:)).first {
            let result = onDirectionalPress(direction)
            if result == .consumed {
                consumedDirectionalPressTypes.formUnion(presses.map { $0.type.rawValue })
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let endedTypes = Set(presses.map { $0.type.rawValue })
        if !consumedDirectionalPressTypes.isDisjoint(with: endedTypes) {
            consumedDirectionalPressTypes.subtract(endedTypes)
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
        consumedDirectionalPressTypes.subtract(presses.map { $0.type.rawValue })
        super.pressesCancelled(presses, with: event)
    }

    private func navigationDirection(for press: UIPress) -> GuideCollectionNavigationDirection? {
        switch press.type {
        case .upArrow: return .up
        case .downArrow: return .down
        case .leftArrow: return .left
        case .rightArrow: return .right
        default: break
        }

        switch press.key?.keyCode {
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardLeftArrow: return .left
        case .keyboardRightArrow: return .right
        default: return nil
        }
    }

    private func updateAppearance(animated: Bool) {
        guard let item else { return }
        let phase = item.program.phase(at: now)
        let presentsFocus = GuideFocusPresentation.presentsProgramFocus(
            isUIKitFocused: isFocused,
            showsPendingFocus: showsPendingFocusAppearance,
            isChannelFocusActive: isChannelFocusActive
        )
        let background: UIColor
        if presentsFocus, isPlaying {
            background = UIColor(AppTheme.focusedPlaying)
        } else if presentsFocus {
            background = UIColor(AppTheme.focused)
        } else if isPlaying {
            background = UIColor(AppTheme.playing)
        } else {
            background = switch phase {
            case .past: UIColor(AppTheme.past)
            case .current: UIColor(AppTheme.current)
            case .future: UIColor(AppTheme.surface)
            }
        }
        contentView.backgroundColor = background
        let borderColor: Color
        let borderWidth: CGFloat
        if presentsFocus {
            borderColor = AppTheme.focusBorder
            borderWidth = 4
        } else if isHeaderSelection {
            borderColor = AppTheme.accent.opacity(0.55)
            borderWidth = 2
        } else {
            borderColor = Color.white.opacity(0.16)
            borderWidth = 1
        }
        contentView.layer.borderColor = UIColor(borderColor).cgColor
        contentView.layer.borderWidth = borderWidth
        timeLabel.textColor = presentsFocus ? .white : UIColor(AppTheme.secondaryText)
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
#if DEBUG && os(tvOS)
        TVGuideAutomationFocusRecorder.shared.updateProgram(
            id: item.id,
            channelID: item.program.channelID,
            isFocused: isFocused,
            presentsMarker: presentsFocus
        )
#endif
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
            let label = UILabel(frame: CGRect(
                x: mark.x + GuideGridMetrics.timelineMarkLeadingInset,
                y: GuideGridMetrics.headerContentY,
                width: 170,
                height: GuideGridMetrics.headerContentHeight
            ))
            label.text = mark.title
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
            content.addSubview(label)

            let tick = UIView(frame: CGRect(
                x: mark.x + GuideGridMetrics.timelineMarkLeadingInset,
                y: GuideGridMetrics.timelineTickY,
                width: 1,
                height: GuideGridMetrics.timelineTickHeight
            ))
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
        let diameter = GuideGridMetrics.nowIndicatorCapDiameter
        let cap = UIView(frame: CGRect(
            x: (GuideGridMetrics.nowIndicatorWidth - diameter) / 2,
            y: -diameter / 2,
            width: diameter,
            height: diameter
        ))
        cap.backgroundColor = .red
        cap.layer.cornerRadius = diameter / 2
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
    private let favoriteImageView = UIImageView(image: UIImage(systemName: "star.fill"))
    private var logoTask: Task<Void, Never>?
    fileprivate var representedChannelID: GuideChannel.ID?
    fileprivate var returnProgramID: GuideProgram.ID?
    private var onActivate: (GuideProgram.ID?) -> Void = { _ in }
    private var onFocused: (GuideProgram.ID?) -> Void = { _ in }
    private var onMoveRight: (GuideProgram.ID) -> Void = { _ in }
    private var onMoveUp: (() -> Void)?

    override var canBecomeFocused: Bool { true }

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

        favoriteImageView.contentMode = .scaleAspectFit
        favoriteImageView.tintColor = UIColor(AppTheme.accent)
        addSubview(favoriteImageView)

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
#if DEBUG && os(tvOS)
        if let representedChannelID {
            TVGuideAutomationFocusRecorder.shared.removeChannel(
                id: representedChannelID
            )
        }
#endif
        representedChannelID = nil
        returnProgramID = nil
        onMoveUp = nil
        logoView.image = nil
    }

    func configure(
        channel: GuideChannel,
        configuration: TVHeadendConfiguration?,
        isFavorite: Bool,
        onActivate: @escaping (GuideProgram.ID?) -> Void,
        onFocused: @escaping (GuideProgram.ID?) -> Void,
        onMoveRight: @escaping (GuideProgram.ID) -> Void,
        onMoveUp: (() -> Void)?
    ) {
        representedChannelID = channel.id
#if DEBUG && os(tvOS)
        TVGuideAutomationFocusRecorder.shared.updateChannel(
            id: channel.id,
            isFocused: isFocused
        )
#endif
        self.onActivate = onActivate
        self.onFocused = onFocused
        self.onMoveRight = onMoveRight
        self.onMoveUp = onMoveUp
        nameLabel.text = channel.name
        monogramLabel.text = channel.monogram
        favoriteImageView.isHidden = !isFavorite
        accessibilityLabel = isFavorite ? "\(channel.name), favourite" : channel.name
        accessibilityHint = isFavorite
            ? "Press Select to remove this channel from favourites"
            : "Press Select to add this channel to favourites"
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
        let favoriteWidth: CGFloat = favoriteImageView.isHidden ? 0 : 24
        favoriteImageView.frame = CGRect(
            x: bounds.width - 38,
            y: (bounds.height - 22) / 2,
            width: 22,
            height: 22
        )
        nameLabel.frame = CGRect(
            x: 74,
            y: 6,
            width: max(0, bounds.width - 88 - favoriteWidth),
            height: bounds.height - 12
        )
        viewWithTag(1)?.frame = CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        viewWithTag(2)?.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.didUpdateFocus(in: context, with: coordinator)
#if DEBUG && os(tvOS)
        if let representedChannelID {
            TVGuideAutomationFocusRecorder.shared.updateChannel(
                id: representedChannelID,
                isFocused: isFocused
            )
        }
#endif
        if isFocused { onFocused(returnProgramID) }
        coordinator.addCoordinatedAnimations { [self] in
            backgroundColor = isFocused ? UIColor(AppTheme.focused) : UIColor(AppTheme.chrome)
            layer.borderColor = isFocused
                ? UIColor(AppTheme.focusBorder).cgColor
                : UIColor.clear.cgColor
            layer.borderWidth = isFocused ? 4 : 0
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let movesUp = presses.contains { press in
            press.type == .upArrow || press.key?.keyCode == .keyboardUpArrow
        }
        if movesUp, let onMoveUp {
            onMoveUp()
            return
        }
        let movesRight = presses.contains { press in
            press.type == .rightArrow || press.key?.keyCode == .keyboardRightArrow
        }
        if movesRight, let returnProgramID {
            onMoveRight(returnProgramID)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            onActivate(returnProgramID)
            return
        }
        if onMoveUp != nil,
           presses.contains(where: { $0.type == .upArrow || $0.key?.keyCode == .keyboardUpArrow }) {
            return
        }
        if presses.contains(where: { $0.type == .rightArrow || $0.key?.keyCode == .keyboardRightArrow }) {
            return
        }
        super.pressesEnded(presses, with: event)
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
    let channelPreferencesRevision: Int
    let preferredProgramID: GuideProgram.ID?
    let playingProgramID: GuideProgram.ID?
    let focusScope: Namespace.ID
    @Binding var focusedProgramID: GuideProgram.ID?
    let recenterRequest: UUID
    let focusRestoreRequest: UUID
    let recordingsRevision: Int
    let configuration: TVHeadendConfiguration
    let isFavorite: (GuideChannel.ID) -> Bool
    let onToggleFavorite: (GuideChannel.ID) -> Void
    let recordingState: (GuideProgram) -> TVRecordingState?
    let onActivate: (GuideProgram) -> Void
    let onPlay: (GuideProgram) -> Void
    let onReady: () -> Void
    let onFocusAcquired: () -> Void
    let onExitToNavigator: () -> Void
    @FocusState private var keyboardFocusedProgramID: GuideProgram.ID?

    private var snapshot: GuideGridSnapshot {
        GuideGridSnapshot(
            channels: channels,
            timeline: timeline,
            revision: guideRevision
        )
    }

    var body: some View {
        let snapshot = snapshot
        let nowIndicatorX = GuideGridMetrics.nowIndicatorX(in: timeline, at: now)

        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { row, channel in
                        HStack(spacing: 0) {
                            channelLabel(channel)
                                .guidePinnedToLeadingEdge()
                                .zIndex(1)

                            ZStack(alignment: .topLeading) {
                                ForEach(snapshot.rows[row]) { item in
                                    Button {
                                        focusedProgramID = item.id
                                        onActivate(item.program)
                                    } label: {
                                        GuideProgramCard(
                                            program: item.program,
                                            now: now,
                                            isFocused: keyboardFocusedProgramID == item.id,
                                            isPlaying: playingProgramID == item.id,
                                            recordingState: recordingState(item.program),
                                            leadingContentInset: 0
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .focused($keyboardFocusedProgramID, equals: item.id)
                                    .frame(
                                        width: item.frame.width,
                                        height: item.frame.height
                                    )
                                    .offset(
                                        x: item.frame.minX - GuideGridMetrics.channelWidth,
                                        y: item.frame.minY
                                            - GuideGridMetrics.headerHeight
                                            - CGFloat(row) * GuideGridMetrics.rowHeight
                                    )
                                    .contextMenu {
                                        Button("Programme Details", systemImage: "info.circle") {
                                            onActivate(item.program)
                                        }
                                        Button("Watch", systemImage: "play.fill") {
                                            onPlay(item.program)
                                        }
                                    }
                                }

                                if let nowIndicatorX {
                                    Rectangle()
                                        .fill(.red)
                                        .frame(
                                            width: GuideGridMetrics.nowIndicatorWidth,
                                            height: GuideGridMetrics.rowHeight
                                        )
                                        .offset(
                                            x: nowIndicatorX
                                                - GuideGridMetrics.nowIndicatorWidth / 2
                                        )
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                        .zIndex(2)
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
                            .frame(
                                width: GuideGridMetrics.channelWidth,
                                height: GuideGridMetrics.headerContentHeight,
                                alignment: .leading
                            )
                            .frame(height: GuideGridMetrics.headerHeight)
                            .background(AppTheme.chrome)
                            .guidePinnedToLeadingEdge()
                            .zIndex(1)

                        ZStack(alignment: .topLeading) {
                            ForEach(snapshot.marks, id: \.date) { mark in
                                Text(mark.title)
                                    .font(.headline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .frame(
                                        width: 170,
                                        height: GuideGridMetrics.headerContentHeight,
                                        alignment: .leading
                                    )
                                    .offset(
                                        x: mark.x + GuideGridMetrics.timelineMarkLeadingInset,
                                        y: GuideGridMetrics.headerContentY
                                    )

                                Rectangle()
                                    .fill(AppTheme.divider)
                                    .frame(width: 1, height: GuideGridMetrics.timelineTickHeight)
                                    .offset(
                                        x: mark.x + GuideGridMetrics.timelineMarkLeadingInset,
                                        y: GuideGridMetrics.timelineTickY
                                    )
                            }

                            if let nowIndicatorX {
                                Circle()
                                    .fill(.red)
                                    .frame(
                                        width: GuideGridMetrics.nowIndicatorCapDiameter,
                                        height: GuideGridMetrics.nowIndicatorCapDiameter
                                    )
                                    .offset(
                                        x: nowIndicatorX
                                            - GuideGridMetrics.nowIndicatorCapDiameter / 2,
                                        y: GuideGridMetrics.headerHeight
                                            - GuideGridMetrics.nowIndicatorCapDiameter / 2
                                    )
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                    .zIndex(2)
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
        .defaultFocus($keyboardFocusedProgramID, preferredProgramID)
        .onAppear {
            let initialProgramID = focusedProgramID ?? preferredProgramID
            focusedProgramID = initialProgramID
            keyboardFocusedProgramID = initialProgramID
            onReady()
        }
        .onChange(of: keyboardFocusedProgramID) { _, programID in
            guard let programID else { return }
            focusedProgramID = programID
            onFocusAcquired()
        }
        .onChange(of: focusedProgramID) { _, programID in
            guard let programID, programID != keyboardFocusedProgramID else { return }
            keyboardFocusedProgramID = programID
        }
        .onChange(of: focusRestoreRequest) { _, _ in
            let programID = preferredProgramID ?? focusedProgramID
            focusedProgramID = programID
            keyboardFocusedProgramID = programID
        }
        .onChange(of: recenterRequest) { _, _ in
            let programID = preferredProgramID ?? focusedProgramID
            focusedProgramID = programID
            keyboardFocusedProgramID = programID
        }
    }

    private func channelLabel(_ channel: GuideChannel) -> some View {
        Button {
            onToggleFavorite(channel.id)
        } label: {
            HStack(spacing: 12) {
                ChannelBadge(channel: channel, diameter: 52)
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(2)
                if isFavorite(channel.id) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityLabel("Favourite channel")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(width: GuideGridMetrics.channelWidth, height: GuideGridMetrics.rowHeight)
            .background(AppTheme.chrome)
        }
        .buttonStyle(.plain)
        .accessibilityHint(
            isFavorite(channel.id)
                ? "Remove this channel from favourites"
                : "Add this channel to favourites"
        )
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
