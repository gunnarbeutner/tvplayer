import SwiftUI
import UIKit
import OSLog

let guideFocusLogger = Logger(subsystem: "de.beutner.TVPlayer", category: "GuideFocus")

enum GuideGridMetrics {
    static let channelWidth: CGFloat = 280
    static let headerHeight: CGFloat = 58
    static let rowHeight: CGFloat = 94
    static let cardInset: CGFloat = 5
    static let rowInset: CGFloat = 5
    static let cardHeight = rowHeight - (rowInset * 2)
}

enum GuideGridChromeLayout {
    static func timelineContentOffset(for contentOffset: CGPoint) -> CGSize {
        CGSize(
            width: -contentOffset.x,
            height: 0
        )
    }

    static func channelHeadersOffset(for contentOffset: CGPoint) -> CGSize {
        CGSize(
            width: 0,
            height: GuideGridMetrics.headerHeight - contentOffset.y
        )
    }

    static func correctedHorizontalOffset(
        currentOffset: CGFloat,
        programmeOffset: CGFloat,
        leadingPadding: CGFloat = 8
    ) -> CGFloat? {
        let programmeLeadingEdge = GuideGridMetrics.channelWidth
            + programmeOffset
            - currentOffset
        let minimumVisibleEdge = GuideGridMetrics.channelWidth + leadingPadding
        guard programmeLeadingEdge < minimumVisibleEdge else { return nil }
        let correctedOffset = max(0, programmeOffset - leadingPadding)
        // A no-op correction must not issue a scroll command: scrolling a
        // two-axis ScrollView to an x offset also resets its y offset, which
        // would fling the focused row out of the viewport.
        guard correctedOffset != currentOffset else { return nil }
        return correctedOffset
    }

    static func isTimelineMarkVisible(markOffset: CGFloat, contentOffset: CGFloat) -> Bool {
        markOffset >= contentOffset
    }
}

enum GuideGridNavigationDirection: Equatable {
    case up
    case down
}

enum GuideGridNavigation {
    static func destinationProgram(
        in channels: [GuideChannel],
        timeline: GuideTimeline,
        from programID: GuideProgram.ID,
        direction: GuideGridNavigationDirection,
        at now: Date
    ) -> GuideProgram? {
        guard let channelIndex = channels.firstIndex(where: { channel in
            channel.programs.contains(where: { $0.id == programID })
        }),
        let currentProgram = channels[channelIndex].programs.first(where: { $0.id == programID })
        else { return nil }

        let referenceDate = currentProgram.isAiring(at: now)
            ? now
            : currentProgram.start.addingTimeInterval(currentProgram.duration / 2)

        let step = direction == .up ? -1 : 1
        var destinationIndex = channelIndex + step
        while channels.indices.contains(destinationIndex) {
            let programs = visiblePrograms(in: channels[destinationIndex], timeline: timeline)
            if let destination = closestProgram(in: programs, to: referenceDate) {
                return destination
            }
            destinationIndex += step
        }

        return nil
    }

    static func isAtBoundary(
        in channels: [GuideChannel],
        from programID: GuideProgram.ID,
        direction: GuideGridNavigationDirection
    ) -> Bool {
        guard let channelIndex = channels.firstIndex(where: { channel in
            channel.programs.contains(where: { $0.id == programID })
        }) else { return false }
        return direction == .up
            ? channelIndex == channels.startIndex
            : channelIndex == channels.index(before: channels.endIndex)
    }

    private static func closestProgram(
        in programs: [GuideProgram],
        to referenceDate: Date
    ) -> GuideProgram? {
        if let intersecting = programs.first(where: {
            $0.start <= referenceDate && referenceDate < $0.end
        }) {
            return intersecting
        }

        return programs.min { lhs, rhs in
            let lhsDistance = distance(from: referenceDate, to: lhs)
            let rhsDistance = distance(from: referenceDate, to: rhs)
            if lhsDistance == rhsDistance { return lhs.start < rhs.start }
            return lhsDistance < rhsDistance
        }
    }

    private static func visiblePrograms(
        in channel: GuideChannel,
        timeline: GuideTimeline
    ) -> [GuideProgram] {
        channel.programs
            .filter { $0.end > timeline.start && $0.start < timeline.end }
            .sorted {
                if $0.start == $1.start { return $0.end < $1.end }
                return $0.start < $1.start
            }
    }

    private static func distance(from date: Date, to program: GuideProgram) -> TimeInterval {
        if date < program.start { return program.start.timeIntervalSince(date) }
        if date >= program.end { return date.timeIntervalSince(program.end) }
        return 0
    }
}

enum GuideProgramFocusLayout {
    static let maximumTargetWidth: CGFloat = 120

    static func targetFrame(
        cardWidth: CGFloat,
        programmeOffset: CGFloat,
        program: GuideProgram,
        timeline: GuideTimeline,
        now: Date
    ) -> CGRect {
        let width = min(cardWidth, maximumTargetWidth)
        let desiredCenter: CGFloat

        if program.isAiring(at: now) {
            desiredCenter = timeline.xOffset(for: now) - programmeOffset
        } else {
            desiredCenter = width / 2
        }

        let center = min(
            max(width / 2, desiredCenter),
            max(width / 2, cardWidth - (width / 2))
        )
        return CGRect(
            x: center - (width / 2),
            y: 0,
            width: width,
            height: GuideGridMetrics.cardHeight
        )
    }
}

struct GuideGridView: View {
    let channels: [GuideChannel]
    let timeline: GuideTimeline
    let now: Date
    let preferredProgramID: GuideProgram.ID?
    let focusScope: Namespace.ID
    @Binding var focusedProgramID: GuideProgram.ID?
    let recenterRequest: UUID
    let focusRestoreRequest: UUID
    let recordingsFingerprint: Int
    let recordingState: (GuideProgram) -> TVRecordingState?
    let onActivate: (GuideProgram) -> Void
    let onPlay: (GuideProgram) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var contentOffset: CGPoint = .zero
    @State private var scrollPosition = ScrollPosition(x: 0)
    @StateObject private var focusTargets = GuideFocusTargetRegistry()
    @StateObject private var occlusion = GuideOcclusionCoordinator()

    private var contentWidth: CGFloat {
        GuideGridMetrics.channelWidth + timeline.width
    }

    private var contentHeight: CGFloat {
        GuideGridMetrics.headerHeight + CGFloat(channels.count) * GuideGridMetrics.rowHeight
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                guideBackground
                programmeCards
                nowIndicator
            }
            .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        }
        .scrollPosition($scrollPosition)
        // A scoped preferred target overrides the focus engine's geometric
        // choice when moving down into the guide from the tab bar.
        .focusScope(focusScope)
        .onScrollGeometryChange(for: CGRect.self) { geometry in
            // ScrollGeometry reports the leading resting position as the
            // negative safe-area inset on tvOS. Normalize it so zero always
            // means the true top-leading content edge.
            CGRect(
                x: geometry.contentOffset.x + geometry.contentInsets.leading,
                y: geometry.contentOffset.y + geometry.contentInsets.top,
                width: geometry.containerSize.width,
                height: geometry.containerSize.height
            )
        } action: { _, newGeometry in
            contentOffset = newGeometry.origin
            occlusion.update(offset: newGeometry.origin, viewportHeight: newGeometry.height)
        }
        .overlay(alignment: .topLeading) {
            // The grid itself owns scrolling while these headers remain outside
            // its focusable bounds. ScrollGeometry is the authoritative offset;
            // a GeometryReader preference can remain frozen during tvOS focus
            // scrolling even while the content visibly moves.
            ZStack(alignment: .topLeading) {
                channelColumnBackground
                timelineHeader
                channelHeaders
                cornerHeader
            }
        }
        .clipped()
        .background(AppTheme.background)
        .onAppear { scrollToInitialPosition(animated: false) }
        .onChange(of: recenterRequest) { _, _ in scrollToInitialPosition(animated: true) }
        .onChange(of: focusedProgramID) { _, newID in
            guard let newID else { return }
            establishFocus(on: newID)
        }
        .onChange(of: focusRestoreRequest) { _, _ in
            // Setting the binding back to the same programme after the player
            // dismisses does not fire its onChange, yet UIKit focus has moved
            // to whatever survived the player's removal. Re-request focus on
            // the stored programme explicitly.
            guard let programID = focusedProgramID else { return }
            establishFocus(on: programID)
        }
    }

    private var guideBackground: some View {
        ZStack(alignment: .topLeading) {
            ForEach(timeline.halfHourMarks, id: \.self) { mark in
                Rectangle()
                    .fill(AppTheme.divider)
                    .frame(width: 1, height: contentHeight - GuideGridMetrics.headerHeight)
                    .offset(
                        x: GuideGridMetrics.channelWidth + timeline.xOffset(for: mark),
                        y: GuideGridMetrics.headerHeight
                    )
            }
        }
        .accessibilityHidden(true)
    }

    private var programmeCards: some View {
        GuideProgrammeRows(
            channels: channels,
            timeline: timeline,
            now: now,
            recordingsFingerprint: recordingsFingerprint,
            isFocusEnabled: isEnabled,
            focusTargets: focusTargets,
            occlusion: occlusion,
            recordingState: recordingState,
            accessibilityLabel: { self.accessibilityLabel(for: $0, channel: $1) },
            onFocused: { focusedProgramID = $0 },
            onActivate: onActivate,
            onPlay: onPlay,
            onMove: { moveFocus(from: $0, direction: $1) },
            shouldConsumeExternalFocus: { shouldConsumeExternalFocus(from: $0, direction: $1) }
        )
        .offset(x: GuideGridMetrics.channelWidth, y: GuideGridMetrics.headerHeight)
    }

    @ViewBuilder
    private var nowIndicator: some View {
        if timeline.start <= now, now <= timeline.end {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 3, height: contentHeight - GuideGridMetrics.headerHeight)

                Circle()
                    .fill(Color.red)
                    .frame(width: 13, height: 13)
                    .offset(y: -6)
            }
            .offset(
                x: GuideGridMetrics.channelWidth + timeline.xOffset(for: now),
                y: GuideGridMetrics.headerHeight
            )
            .zIndex(12)
            .accessibilityHidden(true)
        }
    }

    private var timelineHeader: some View {
        GuideTimelineHeaderBar(timeline: timeline, contentOffsetX: contentOffset.x)
            .zIndex(30)
            .allowsHitTesting(false)
    }

    private var channelColumnBackground: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(AppTheme.chrome)
                .frame(
                    width: GuideGridMetrics.channelWidth,
                    height: max(0, geometry.size.height - GuideGridMetrics.headerHeight)
                )
                .offset(y: GuideGridMetrics.headerHeight)
        }
        .zIndex(29)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var channelHeaders: some View {
        GuideChannelHeadersColumn(channels: channels, contentOffsetY: contentOffset.y)
            .zIndex(31)
            .allowsHitTesting(false)
    }

    private var cornerHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
            Text("NOW")
                .font(.caption.weight(.bold))
                .tracking(1.4)
        }
        .foregroundStyle(AppTheme.accent)
        .frame(width: GuideGridMetrics.channelWidth, height: GuideGridMetrics.headerHeight)
        .background(AppTheme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
        .zIndex(40)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func isVisible(_ program: GuideProgram) -> Bool {
        program.end > timeline.start && program.start < timeline.end
    }

    private func accessibilityLabel(for program: GuideProgram, channel: GuideChannel) -> String {
        let state: String
        switch program.phase(at: now) {
        case .past: state = "Finished"
        case .current: state = "Currently airing"
        case .future: state = "Upcoming"
        }

        return "\(program.title), \(channel.name), \(program.start.formatted(date: .omitted, time: .shortened)) to \(program.end.formatted(date: .omitted, time: .shortened)), \(state)"
    }

    private func scrollToInitialPosition(animated: Bool) {
        Task { @MainActor in
            await Task.yield()
            if animated {
                withAnimation(.easeInOut(duration: 0.35)) {
                    scrollPosition.scrollTo(x: 0)
                }
            } else {
                scrollPosition.scrollTo(x: 0)
            }
        }
    }

    private func establishFocus(on programID: GuideProgram.ID) {
        Task { @MainActor in
            // A directional press is still being dispatched when the
            // binding changes. Wait until that transaction completes,
            // then establish UIKit focus and reveal the confirmed row.
            await Task.yield()
            guard focusedProgramID == programID else { return }
            focusTargets.requestFocus(on: programID)
            await Task.yield()
            guard focusedProgramID == programID else { return }
            keepFocusedProgrammeClearOfChannelColumn(programID)
        }
    }

    private func keepFocusedProgrammeClearOfChannelColumn(_ programID: GuideProgram.ID) {
        guard let program = channels.lazy.flatMap(\.programs).first(where: { $0.id == programID }) else {
            return
        }
        let visibleStart = max(program.start, timeline.start)
        let programmeOffset = timeline.xOffset(for: visibleStart)

        Task { @MainActor in
            await Task.yield()
            guard focusedProgramID == programID,
                  let correctedOffset = GuideGridChromeLayout.correctedHorizontalOffset(
                      currentOffset: contentOffset.x,
                      programmeOffset: programmeOffset
                  )
            else { return }

            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(x: correctedOffset)
            }
        }
    }

    private func moveFocus(
        from programID: GuideProgram.ID,
        direction: GuideGridNavigationDirection
    ) -> Bool {
        // UIKit focus can still be animating toward the preceding target when
        // another press arrives. Navigate from the logical pending target so
        // every physical press advances exactly one row.
        let originID = focusTargets.navigationOrigin(fallback: programID)
        guard let destination = GuideGridNavigation.destinationProgram(
            in: channels,
            timeline: timeline,
            from: originID,
            direction: direction,
            at: Date()
        ) else {
            // Down never leaves the guide. Up may hand focus to the tab bar,
            // but only from the actual first channel. Missing guide data in
            // an intermediate row is not a boundary.
            if direction == .down {
                return true
            }
            return !GuideGridNavigation.isAtBoundary(
                in: channels,
                from: originID,
                direction: .up
            )
        }

        // Constrain the focus engine to the deterministic destination, then
        // let the physical press perform the native tvOS focus transition.
        // Native movement supplies smooth scrolling and built-in key repeat.
        focusTargets.prepareFocus(on: destination.id)
        return true
    }

    private func shouldConsumeExternalFocus(
        from programID: GuideProgram.ID,
        direction: GuideGridNavigationDirection
    ) -> Bool {
        if direction == .down { return true }
        return !GuideGridNavigation.isAtBoundary(
            in: channels,
            from: programID,
            direction: .up
        )
    }

}

/// The card grid is deliberately non-lazy so every focus target stays
/// mounted, which makes it expensive to re-evaluate. Scroll offsets change on
/// every animation frame, so this subtree opts into Equatable diffing keyed
/// on the values the cards actually render and is fully independent of the
/// scroll offset: scrolling on either axis skips the entire forest. The
/// per-frame occlusion insets reach the few affected cards through
/// `GuideOcclusionCoordinator` instead of view inputs.
private struct GuideProgrammeRows: View, Equatable {
    let channels: [GuideChannel]
    let timeline: GuideTimeline
    let now: Date
    let recordingsFingerprint: Int
    let isFocusEnabled: Bool
    let focusTargets: GuideFocusTargetRegistry
    let occlusion: GuideOcclusionCoordinator
    let recordingState: (GuideProgram) -> TVRecordingState?
    let accessibilityLabel: (GuideProgram, GuideChannel) -> String
    let onFocused: (GuideProgram.ID) -> Void
    let onActivate: (GuideProgram) -> Void
    let onPlay: (GuideProgram) -> Void
    let onMove: (GuideProgram.ID, GuideGridNavigationDirection) -> Bool
    let shouldConsumeExternalFocus: (GuideProgram.ID, GuideGridNavigationDirection) -> Bool

    nonisolated static func == (lhs: GuideProgrammeRows, rhs: GuideProgrammeRows) -> Bool {
        lhs.isFocusEnabled == rhs.isFocusEnabled
            && lhs.now == rhs.now
            && lhs.recordingsFingerprint == rhs.recordingsFingerprint
            && lhs.timeline == rhs.timeline
            && lhs.channels == rhs.channels
    }

    var body: some View {
        // Keep every programme focus target mounted. Lazy rows can be
        // recycled during a focus-driven scroll, which makes tvOS discard the
        // requested destination and choose an unrelated visible fallback.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(channels.enumerated()), id: \.element.id) { channelIndex, channel in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(
                            channelIndex.isMultiple(of: 2)
                                ? AppTheme.background
                                : AppTheme.chrome.opacity(0.42)
                        )

                    ForEach(channel.programs.filter(isVisible)) { program in
                        let visibleStart = max(program.start, timeline.start)
                        let visibleEnd = min(program.end, timeline.end)
                        let interval = DateInterval(start: visibleStart, end: visibleEnd)
                        let cardWidth = max(28, timeline.width(for: interval) - GuideGridMetrics.cardInset)
                        let programmeOffset = timeline.xOffset(for: visibleStart) + 2
                        let focusFrame = GuideProgramFocusLayout.targetFrame(
                            cardWidth: cardWidth,
                            programmeOffset: programmeOffset,
                            program: program,
                            timeline: timeline,
                            now: now
                        )

                        GuideProgrammeFocusCell(
                            program: program,
                            now: now,
                            recordingState: recordingState(program),
                            rowIndex: channelIndex,
                            programmeOffset: programmeOffset,
                            cardWidth: cardWidth,
                            focusFrame: focusFrame,
                            registry: focusTargets,
                            occlusion: occlusion,
                            accessibilityLabel: accessibilityLabel(program, channel),
                            onFocused: { onFocused(program.id) },
                            onActivate: { onActivate(program) },
                            onPlay: { onPlay(program) },
                            onMove: { direction in onMove(program.id, direction) },
                            shouldConsumeExternalFocus: { direction in
                                shouldConsumeExternalFocus(program.id, direction)
                            }
                        )
                        .frame(width: cardWidth, height: GuideGridMetrics.cardHeight)
                        .offset(x: programmeOffset, y: GuideGridMetrics.rowInset)
                    }
                }
                .frame(width: timeline.width, height: GuideGridMetrics.rowHeight, alignment: .topLeading)
            }
        }
        .frame(width: timeline.width, alignment: .topLeading)
    }

    private func isVisible(_ program: GuideProgram) -> Bool {
        program.end > timeline.start && program.start < timeline.end
    }
}

/// Own focus styling at the individual card level. Keeping this state out of
/// `GuideProgrammeRows` means a channel change redraws two cards instead of
/// every programme in the non-lazy guide.
private struct GuideProgrammeFocusCell: View {
    let program: GuideProgram
    let now: Date
    let recordingState: TVRecordingState?
    let rowIndex: Int
    let programmeOffset: CGFloat
    let cardWidth: CGFloat
    let focusFrame: CGRect
    let registry: GuideFocusTargetRegistry
    let occlusion: GuideOcclusionCoordinator
    let accessibilityLabel: String
    let onFocused: () -> Void
    let onActivate: () -> Void
    let onPlay: () -> Void
    let onMove: (GuideGridNavigationDirection) -> Bool
    let shouldConsumeExternalFocus: (GuideGridNavigationDirection) -> Bool

    @State private var isFocused = false
    @State private var leadingContentInset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            GuideProgramCard(
                program: program,
                now: now,
                isFocused: isFocused,
                recordingState: recordingState,
                leadingContentInset: leadingContentInset
            )
            .frame(width: cardWidth, height: GuideGridMetrics.cardHeight)

            // Keep the focus geometry compact even when one programme spans
            // most of the night. A live target sits on the current-time line,
            // making vertical movement unambiguous.
            GuideProgramFocusTarget(
                id: program.id,
                registry: registry,
                accessibilityLabel: accessibilityLabel,
                onFocusChanged: { isFocused = $0 },
                onFocused: onFocused,
                onActivate: onActivate,
                onPlay: onPlay,
                onMove: onMove,
                shouldConsumeExternalFocus: shouldConsumeExternalFocus
            )
            .frame(width: focusFrame.width, height: focusFrame.height)
            .offset(x: focusFrame.minX)
        }
        .zIndex(isFocused ? 20 : 2)
        .onAppear { registerOcclusion() }
        .onDisappear { occlusion.unregister(id: program.id) }
        .onChange(of: rowIndex) { _, _ in registerOcclusion() }
        .onChange(of: programmeOffset) { _, _ in registerOcclusion() }
        .onChange(of: cardWidth) { _, _ in registerOcclusion() }
    }

    private func registerOcclusion() {
        occlusion.register(
            id: program.id,
            rowIndex: rowIndex,
            leadingEdge: programmeOffset,
            width: cardWidth
        ) { inset in
            leadingContentInset = inset
        }
    }
}

/// Delivers the channel-column occlusion inset to programme cards without
/// routing the scroll offset through view inputs. The offset changes on every
/// animation frame; passing it into `GuideProgrammeRows` would defeat its
/// Equatable shield and re-evaluate the entire non-lazy forest per frame.
/// Instead each card registers its extent here, the grid pushes the offset
/// per frame, and only cards inside the vertical viewport whose clamped inset
/// actually changed (those straddling the channel-column edge) receive a
/// state update. Cards in off-screen rows catch up when scrolling makes their
/// row visible.
@MainActor
private final class GuideOcclusionCoordinator: ObservableObject {
    private final class Entry {
        let rowIndex: Int
        let leadingEdge: CGFloat
        let width: CGFloat
        let apply: (CGFloat) -> Void
        var appliedInset: CGFloat?

        init(
            rowIndex: Int,
            leadingEdge: CGFloat,
            width: CGFloat,
            apply: @escaping (CGFloat) -> Void
        ) {
            self.rowIndex = rowIndex
            self.leadingEdge = leadingEdge
            self.width = width
            self.apply = apply
        }
    }

    private var entries: [GuideProgram.ID: Entry] = [:]
    private var offset: CGPoint = .zero
    private var viewportHeight: CGFloat = .greatestFiniteMagnitude

    func register(
        id: GuideProgram.ID,
        rowIndex: Int,
        leadingEdge: CGFloat,
        width: CGFloat,
        apply: @escaping (CGFloat) -> Void
    ) {
        let entry = Entry(rowIndex: rowIndex, leadingEdge: leadingEdge, width: width, apply: apply)
        entries[id] = entry
        applyInset(to: entry)
    }

    func unregister(id: GuideProgram.ID) {
        entries[id] = nil
    }

    func update(offset: CGPoint, viewportHeight: CGFloat) {
        guard offset != self.offset || viewportHeight != self.viewportHeight else { return }
        self.offset = offset
        self.viewportHeight = viewportHeight
        for entry in entries.values where isRowVisible(entry.rowIndex) {
            applyInset(to: entry)
        }
    }

    private func isRowVisible(_ rowIndex: Int) -> Bool {
        let rowTop = GuideGridMetrics.headerHeight + CGFloat(rowIndex) * GuideGridMetrics.rowHeight
        return rowTop + GuideGridMetrics.rowHeight > offset.y
            && rowTop < offset.y + viewportHeight
    }

    private func applyInset(to entry: Entry) {
        let inset = min(max(0, offset.x - entry.leadingEdge), entry.width)
        guard inset != entry.appliedInset else { return }
        entry.appliedInset = inset
        entry.apply(inset)
    }
}

@MainActor
private final class GuideFocusTargetRegistry: ObservableObject {
    private final class WeakTarget {
        weak var view: GuideProgramFocusUIView?

        init(_ view: GuideProgramFocusUIView) {
            self.view = view
        }
    }

    private var targets: [GuideProgram.ID: WeakTarget] = [:]
    private var pendingID: GuideProgram.ID?
    private var focusRetryTask: Task<Void, Never>?

    var focusedProgramID: GuideProgram.ID? {
        targets.first(where: { $0.value.view?.isFocused == true })?.key
    }

    func register(_ view: GuideProgramFocusUIView, for id: GuideProgram.ID) {
        targets[id] = WeakTarget(view)
        if pendingID == id {
            requestFocus(on: id)
        }
    }

    func viewDidAttach(_ view: GuideProgramFocusUIView, for id: GuideProgram.ID) {
        // A focus request that arrived before the target joined a window was
        // parked as pendingID. Retry now that UIKit can actually focus it;
        // without this the guide can look focused after a cold launch while
        // real focus is still on the tab bar.
        guard pendingID == id, targets[id]?.view === view else { return }
        requestFocus(on: id)
    }

    func unregister(_ view: GuideProgramFocusUIView, for id: GuideProgram.ID) {
        guard targets[id]?.view === view else { return }
        targets[id] = nil
    }

    func requestFocus(on id: GuideProgram.ID) {
        pendingID = id
        focusRetryTask?.cancel()
        attemptFocus(on: id, retriesRemaining: 8)
    }

    private func attemptFocus(on id: GuideProgram.ID, retriesRemaining: Int) {
        guard pendingID == id else { return }
        guard let view = targets[id]?.view, view.window != nil,
              let focusSystem = UIFocusSystem.focusSystem(for: view)
        else {
            guideFocusLogger.debug("requestFocus(\(id, privacy: .public)): parked, view/window/system unavailable")
            return
        }

        if let focusedView = focusSystem.focusedItem as? UIView, focusedView === view {
            guideFocusLogger.debug("requestFocus(\(id, privacy: .public)): already focused")
            pendingID = nil
            focusRetryTask = nil
            return
        }

        guideFocusLogger.debug("requestFocus(\(id, privacy: .public)): requesting, focusAllowed=\(view.isFocusAllowed), currentFocus=\(String(describing: focusSystem.focusedItem), privacy: .public)")
        focusSystem.requestFocusUpdate(to: view)
        focusSystem.updateFocusIfNeeded()

        // Restoring focus can arrive while UIKit is completing a transition.
        // Retry the pending target on subsequent run-loop turns rather than
        // leaving the guide visually selected while focus remains elsewhere.
        guard pendingID == id, retriesRemaining > 0 else { return }
        focusRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(35))
                guard !Task.isCancelled else { return }
                self?.attemptFocus(on: id, retriesRemaining: retriesRemaining - 1)
            } catch {
                // Superseded by a newer target or fulfilled focus request.
            }
        }
    }

    func didFocus(id: GuideProgram.ID) {
        if pendingID == id {
            pendingID = nil
            focusRetryTask?.cancel()
            focusRetryTask = nil
        }
    }

    func navigationOrigin(fallback: GuideProgram.ID) -> GuideProgram.ID {
        pendingID ?? focusedProgramID ?? fallback
    }

    var hasPreparedFocus: Bool {
        pendingID != nil
    }

    func prepareFocus(on id: GuideProgram.ID) {
        pendingID = id
    }

    func allowsFocus(on id: GuideProgram.ID) -> Bool {
        // SwiftUI ignores UIKit-initiated focus grabs while one of its own
        // focusables (the tab bar) holds focus, so a parked request cannot be
        // fulfilled programmatically. Instead, while one is parked, make the
        // requested target the only focusable card: whichever way focus next
        // enters the guide, it must land there rather than on the card the
        // geometric resolver would pick.
        guard let pendingID, pendingID != id else { return true }
        guard let pendingView = targets[pendingID]?.view,
              pendingView.window != nil,
              pendingView.isFocusAllowed
        else { return true }
        return false
    }

    func isPreparedFocusUpdate(_ context: UIFocusUpdateContext) -> Bool {
        guard let pendingID,
              let pendingView = targets[pendingID]?.view,
              let nextView = context.nextFocusedItem as? UIView
        else { return false }
        return nextView === pendingView
    }
}

private struct GuideProgramFocusTarget: UIViewRepresentable {
    let id: GuideProgram.ID
    let registry: GuideFocusTargetRegistry
    let accessibilityLabel: String
    let onFocusChanged: (Bool) -> Void
    let onFocused: () -> Void
    let onActivate: () -> Void
    let onPlay: () -> Void
    let onMove: (GuideGridNavigationDirection) -> Bool
    let shouldConsumeExternalFocus: (GuideGridNavigationDirection) -> Bool

    func makeUIView(context: Context) -> GuideProgramFocusUIView {
        let view = GuideProgramFocusUIView()
        configure(view)
        view.isFocusAllowed = context.environment.isEnabled
        registry.register(view, for: id)
        return view
    }

    func updateUIView(_ view: GuideProgramFocusUIView, context: Context) {
        configure(view)
        updateFocusAvailability(of: view, isEnabled: context.environment.isEnabled)
        registry.register(view, for: id)
    }

    private func updateFocusAvailability(of view: GuideProgramFocusUIView, isEnabled: Bool) {
        guard view.isFocusAllowed != isEnabled else { return }
        view.isFocusAllowed = isEnabled
        // A UIViewRepresentable does not inherit SwiftUI's disabled state, so
        // reevaluate UIKit focus whenever it flips: when the guide is covered
        // by the player its focused card must release focus to the player's
        // chrome instead of consuming remote presses invisibly.
        guard view.isFocused, let focusSystem = UIFocusSystem.focusSystem(for: view) else { return }
        focusSystem.requestFocusUpdate(to: view.window ?? view)
        focusSystem.updateFocusIfNeeded()
    }

    static func dismantleUIView(_ view: GuideProgramFocusUIView, coordinator: ()) {
        view.registry?.unregister(view, for: view.programID)
    }

    private func configure(_ view: GuideProgramFocusUIView) {
        view.programID = id
        view.registry = registry
        view.onFocusChanged = onFocusChanged
        view.onFocused = onFocused
        view.onActivate = onActivate
        view.onPlay = onPlay
        view.onMove = onMove
        view.shouldConsumeExternalFocus = shouldConsumeExternalFocus
        view.isAccessibilityElement = true
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityHint = "Select for programme details. Press Play to watch this channel live."
        view.accessibilityTraits = .button
    }
}

@MainActor
private final class GuideProgramFocusUIView: UIView {
    var programID: GuideProgram.ID = ""
    weak var registry: GuideFocusTargetRegistry?
    var onFocusChanged: ((Bool) -> Void)?
    var onFocused: (() -> Void)?
    var onActivate: (() -> Void)?
    var onPlay: (() -> Void)?
    var onMove: ((GuideGridNavigationDirection) -> Bool)?
    var shouldConsumeExternalFocus: ((GuideGridNavigationDirection) -> Bool)?
    private var consumedDirectionalPress: UIPress.PressType?
    var isFocusAllowed = true

    override var canBecomeFocused: Bool {
        isFocusAllowed && (registry?.allowsFocus(on: programID) ?? true)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.001)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        registry?.viewDidAttach(self, for: programID)
    }

    override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChanged?(isFocused)
        guard isFocused else { return }
        guideFocusLogger.debug("didUpdateFocus: now focused \(self.programID, privacy: .public), heading=\(context.focusHeading.rawValue)")
        registry?.didFocus(id: programID)
        onFocused?()
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // The deterministic navigator's prepared destination is the one
        // constrained vertical focus update that must pass through.
        if registry?.isPreparedFocusUpdate(context) == true {
            return super.shouldUpdateFocus(in: context)
        }

        // While a destination is prepared, do not let the geometric resolver
        // substitute a different programme.
        if registry?.hasPreparedFocus == true {
            return false
        }

        // Native focus movement within the guide supplies smooth animation
        // and held-button repeat. Only reject an escape to outside chrome
        // when the current row is not a legitimate boundary.
        if !(context.nextFocusedItem is GuideProgramFocusUIView) {
            if context.focusHeading.contains(.up), shouldConsumeExternalFocus?(.up) == true {
                return false
            }
            if context.focusHeading.contains(.down), shouldConsumeExternalFocus?(.down) == true {
                return false
            }
        }
        return super.shouldUpdateFocus(in: context)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let consumedDirectionalPress,
           presses.contains(where: { $0.type == consumedDirectionalPress }) {
            self.consumedDirectionalPress = nil
            return
        }

        if presses.contains(where: { $0.type == .select }) {
            onActivate?()
        } else if presses.contains(where: { $0.type == .playPause }) {
            onPlay?()
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .upArrow }) {
            if consumeDirectionalPress(.upArrow, direction: .up) {
                return
            }
        }

        if presses.contains(where: { $0.type == .downArrow }) {
            if consumeDirectionalPress(.downArrow, direction: .down) {
                return
            }
        }

        super.pressesBegan(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        consumedDirectionalPress = nil
        super.pressesCancelled(presses, with: event)
    }

    private func consumeDirectionalPress(
        _ pressType: UIPress.PressType,
        direction: GuideGridNavigationDirection
    ) -> Bool {
        guard onMove?(direction) == true else { return false }

        if registry?.hasPreparedFocus == true {
            // Pass the event into UIKit. Only the prepared target can become
            // focused, so tvOS performs exactly one correctly-routed move.
            return false
        }

        // A consumed move without a prepared target is the lower boundary.
        consumedDirectionalPress = pressType
        return true
    }

}

/// The scroll offset changes every animation frame, so it must only feed the
/// `.offset` transform in here. The marks themselves live in the
/// offset-independent Equatable `GuideTimelineHeader` that per-frame updates
/// skip; marks scrolled past the leading edge are culled by `.clipped()`.
private struct GuideTimelineHeaderBar: View {
    let timeline: GuideTimeline
    let contentOffsetX: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                GuideTimelineHeader(timeline: timeline)
                    .frame(width: timeline.width, height: GuideGridMetrics.headerHeight)
                    .offset(
                        GuideGridChromeLayout.timelineContentOffset(
                            for: CGPoint(x: contentOffsetX, y: 0)
                        )
                    )
            }
            .frame(
                width: max(0, geometry.size.width - GuideGridMetrics.channelWidth),
                height: GuideGridMetrics.headerHeight,
                alignment: .topLeading
            )
            .clipped()
            .offset(x: GuideGridMetrics.channelWidth)
        }
        .frame(height: GuideGridMetrics.headerHeight)
    }
}

/// The scroll offset changes every animation frame, so it must only feed the
/// `.offset` transform out here. The header rows themselves live in an
/// offset-independent Equatable subtree that per-frame updates skip entirely.
private struct GuideChannelHeadersColumn: View {
    let channels: [GuideChannel]
    let contentOffsetY: CGFloat

    var body: some View {
        GuideChannelHeadersList(channels: channels)
            .offset(
                GuideGridChromeLayout.channelHeadersOffset(
                    for: CGPoint(x: 0, y: contentOffsetY)
                )
            )
    }
}

private struct GuideChannelHeadersList: View, Equatable {
    let channels: [GuideChannel]

    nonisolated static func == (lhs: GuideChannelHeadersList, rhs: GuideChannelHeadersList) -> Bool {
        lhs.channels == rhs.channels
    }

    var body: some View {
        // Deliberately non-lazy: the whole column stays mounted, mirroring the
        // programme grid, so scrolling never materializes rows mid-animation.
        VStack(spacing: 0) {
            ForEach(channels) { channel in
                GuideChannelHeader(channel: channel)
                    .frame(
                        width: GuideGridMetrics.channelWidth,
                        height: GuideGridMetrics.cardHeight
                    )
                    .padding(.vertical, GuideGridMetrics.rowInset)
                    .frame(height: GuideGridMetrics.rowHeight)
            }
        }
        .frame(width: GuideGridMetrics.channelWidth, alignment: .topLeading)
    }
}

private struct GuideTimelineHeader: View, Equatable {
    let timeline: GuideTimeline

    nonisolated static func == (lhs: GuideTimelineHeader, rhs: GuideTimelineHeader) -> Bool {
        lhs.timeline == rhs.timeline
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AppTheme.chrome

            ForEach(timeline.halfHourMarks, id: \.self) { mark in
                VStack(alignment: .leading, spacing: 8) {
                    Text(mark.formatted(date: .omitted, time: .shortened))
                        .font(.headline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)

                    Rectangle()
                        .fill(AppTheme.divider)
                        .frame(width: 1, height: 13)
                }
                .offset(x: timeline.xOffset(for: mark) + 10, y: 9)
            }

            VStack {
                Spacer()
                Rectangle().fill(AppTheme.divider).frame(height: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct GuideChannelHeader: View {
    let channel: GuideChannel

    var body: some View {
        HStack(spacing: 12) {
            ChannelBadge(channel: channel, diameter: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        // Expand the header's painted surface to the fixed row-card frame.
        // Without this inner frame, the background and dividers only use the
        // logo/text's intrinsic height even though the outer layout advances
        // by a full guide row.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(AppTheme.chrome, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .trailing) { Rectangle().fill(AppTheme.divider).frame(width: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(channel.name)
    }
}
