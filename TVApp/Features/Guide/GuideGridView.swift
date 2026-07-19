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

enum GuideGridNavigationDirection {
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

        let destinationIndex = direction == .up ? channelIndex - 1 : channelIndex + 1
        guard channels.indices.contains(destinationIndex) else { return nil }

        let programs = visiblePrograms(in: channels[destinationIndex], timeline: timeline)
        guard !programs.isEmpty else { return nil }

        let referenceDate = currentProgram.isAiring(at: now)
            ? now
            : currentProgram.start.addingTimeInterval(currentProgram.duration / 2)

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
        .onScrollGeometryChange(for: CGPoint.self) { geometry in
            // ScrollGeometry reports the leading resting position as the
            // negative safe-area inset on tvOS. Normalize it so zero always
            // means the true top-leading content edge.
            CGPoint(
                x: geometry.contentOffset.x + geometry.contentInsets.leading,
                y: geometry.contentOffset.y + geometry.contentInsets.top
            )
        } action: { _, newOffset in
            contentOffset = newOffset
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
            contentOffsetX: contentOffset.x,
            focusedProgramID: focusedProgramID,
            recordingsFingerprint: recordingsFingerprint,
            isFocusEnabled: isEnabled,
            focusTargets: focusTargets,
            recordingState: recordingState,
            accessibilityLabel: { self.accessibilityLabel(for: $0, channel: $1) },
            onFocused: { focusedProgramID = $0 },
            onActivate: onActivate,
            onPlay: onPlay,
            onMove: { moveFocus(from: $0, direction: $1) }
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
        guard let destination = GuideGridNavigation.destinationProgram(
            in: channels,
            timeline: timeline,
            from: programID,
            direction: direction,
            at: Date()
        ) else {
            // Prevent Down from wrapping at the final channel. Up from the
            // first row remains native so it can return to the tab bar.
            return direction == .down
        }

        focusedProgramID = destination.id
        return true
    }

}

/// The card grid is deliberately non-lazy so every focus target stays
/// mounted, which makes it expensive to re-evaluate. Scroll offsets change on
/// every animation frame, so this subtree opts into Equatable diffing keyed
/// on the values the cards actually render: vertical scrolling and chrome
/// offset churn skip the entire forest, and only horizontal movement (which
/// feeds the occlusion insets) re-renders it.
private struct GuideProgrammeRows: View, Equatable {
    let channels: [GuideChannel]
    let timeline: GuideTimeline
    let now: Date
    let contentOffsetX: CGFloat
    let focusedProgramID: GuideProgram.ID?
    let recordingsFingerprint: Int
    let isFocusEnabled: Bool
    let focusTargets: GuideFocusTargetRegistry
    let recordingState: (GuideProgram) -> TVRecordingState?
    let accessibilityLabel: (GuideProgram, GuideChannel) -> String
    let onFocused: (GuideProgram.ID) -> Void
    let onActivate: (GuideProgram) -> Void
    let onPlay: (GuideProgram) -> Void
    let onMove: (GuideProgram.ID, GuideGridNavigationDirection) -> Bool

    nonisolated static func == (lhs: GuideProgrammeRows, rhs: GuideProgrammeRows) -> Bool {
        lhs.contentOffsetX == rhs.contentOffsetX
            && lhs.focusedProgramID == rhs.focusedProgramID
            && lhs.isFocusEnabled == rhs.isFocusEnabled
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
                        let leadingOcclusion = max(0, contentOffsetX - programmeOffset)
                        let isFocused = focusedProgramID == program.id

                        let focusFrame = GuideProgramFocusLayout.targetFrame(
                            cardWidth: cardWidth,
                            programmeOffset: programmeOffset,
                            program: program,
                            timeline: timeline,
                            now: now
                        )

                        ZStack(alignment: .topLeading) {
                            GuideProgramCard(
                                program: program,
                                now: now,
                                isFocused: isFocused,
                                recordingState: recordingState(program),
                                leadingContentInset: leadingOcclusion
                            )
                            .frame(width: cardWidth, height: GuideGridMetrics.cardHeight)

                            // Keep the focus geometry compact even when one
                            // programme spans most of the night. For a live
                            // programme the target sits on the current-time
                            // line, making vertical focus movement unambiguous.
                            GuideProgramFocusTarget(
                                id: program.id,
                                registry: focusTargets,
                                accessibilityLabel: accessibilityLabel(program, channel),
                                onFocused: {
                                    onFocused(program.id)
                                },
                                onActivate: {
                                    onActivate(program)
                                },
                                onPlay: {
                                    onPlay(program)
                                },
                                onMove: { direction in
                                    onMove(program.id, direction)
                                }
                            )
                                .frame(width: focusFrame.width, height: focusFrame.height)
                                .offset(x: focusFrame.minX)
                        }
                        .frame(width: cardWidth, height: GuideGridMetrics.cardHeight)
                        .offset(x: programmeOffset, y: GuideGridMetrics.rowInset)
                        .zIndex(isFocused ? 20 : 2)
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
    private var blockedDirectionalPress: UIPress.PressType?
    private var blockGeneration = 0

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
        guard let view = targets[id]?.view, view.window != nil,
              let focusSystem = UIFocusSystem.focusSystem(for: view)
        else {
            guideFocusLogger.debug("requestFocus(\(id, privacy: .public)): parked, view/window/system unavailable")
            return
        }

        if let focusedView = focusSystem.focusedItem as? UIView, focusedView === view {
            guideFocusLogger.debug("requestFocus(\(id, privacy: .public)): already focused")
            pendingID = nil
            return
        }

        guideFocusLogger.debug("requestFocus(\(id, privacy: .public)): requesting, focusAllowed=\(view.isFocusAllowed), currentFocus=\(String(describing: focusSystem.focusedItem), privacy: .public)")
        focusSystem.requestFocusUpdate(to: view)
        focusSystem.updateFocusIfNeeded()
    }

    func didFocus(id: GuideProgram.ID) {
        if pendingID == id { pendingID = nil }
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

    func beginBlockingDirectionalFocus(_ pressType: UIPress.PressType) {
        blockedDirectionalPress = pressType
        blockGeneration += 1
    }

    func supersedeDirectionalFocusBlock(_ pressType: UIPress.PressType) {
        // A new physical press of the same type means the previous press is
        // finished; its stray focus updates are no longer worth blocking and
        // the new press must be handled instead of being swallowed.
        guard blockedDirectionalPress == pressType else { return }
        blockedDirectionalPress = nil
    }

    func endBlockingDirectionalFocus(_ pressType: UIPress.PressType) {
        guard blockedDirectionalPress == pressType else { return }
        let generation = blockGeneration
        Task { @MainActor [weak self] in
            // tvOS can deliver the geometric focus update for a press well
            // after pressesEnded. Keep same-heading updates blocked briefly
            // so a single physical press cannot move a second row; a fresh
            // press lifts the block immediately via pressesBegan.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self,
                  self.blockGeneration == generation,
                  self.blockedDirectionalPress == pressType
            else { return }
            self.blockedDirectionalPress = nil
        }
    }

    func cancelDirectionalFocusBlock() {
        blockedDirectionalPress = nil
    }

    func blocksFocusUpdate(_ context: UIFocusUpdateContext) -> Bool {
        let matchesDirection = switch blockedDirectionalPress {
        case .upArrow: context.focusHeading.contains(.up)
        case .downArrow: context.focusHeading.contains(.down)
        default: false
        }
        guard matchesDirection else { return false }

        if let pendingID,
           let pendingView = targets[pendingID]?.view,
           let nextView = context.nextFocusedItem as? UIView,
           nextView === pendingView {
            return false
        }
        return true
    }
}

private struct GuideProgramFocusTarget: UIViewRepresentable {
    let id: GuideProgram.ID
    let registry: GuideFocusTargetRegistry
    let accessibilityLabel: String
    let onFocused: () -> Void
    let onActivate: () -> Void
    let onPlay: () -> Void
    let onMove: (GuideGridNavigationDirection) -> Bool

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
        view.onFocused = onFocused
        view.onActivate = onActivate
        view.onPlay = onPlay
        view.onMove = onMove
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
    var onFocused: (() -> Void)?
    var onActivate: (() -> Void)?
    var onPlay: (() -> Void)?
    var onMove: ((GuideGridNavigationDirection) -> Bool)?
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
        guard isFocused else { return }
        guideFocusLogger.debug("didUpdateFocus: now focused \(self.programID, privacy: .public), heading=\(context.focusHeading.rawValue)")
        registry?.didFocus(id: programID)
        onFocused?()
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if registry?.blocksFocusUpdate(context) == true {
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let consumedDirectionalPress,
           presses.contains(where: { $0.type == consumedDirectionalPress }) {
            registry?.endBlockingDirectionalFocus(consumedDirectionalPress)
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
            registry?.supersedeDirectionalFocusBlock(.upArrow)
            if onMove?(.up) == true {
                consumedDirectionalPress = .upArrow
                registry?.beginBlockingDirectionalFocus(.upArrow)
                return
            }
        }

        if presses.contains(where: { $0.type == .downArrow }) {
            registry?.supersedeDirectionalFocusBlock(.downArrow)
            if onMove?(.down) == true {
                consumedDirectionalPress = .downArrow
                registry?.beginBlockingDirectionalFocus(.downArrow)
                return
            }
        }

        super.pressesBegan(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        consumedDirectionalPress = nil
        registry?.cancelDirectionalFocusBlock()
        super.pressesCancelled(presses, with: event)
    }

}

private struct GuideTimelineHeaderBar: View, Equatable {
    let timeline: GuideTimeline
    let contentOffsetX: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                GuideTimelineHeader(timeline: timeline, contentOffset: contentOffsetX)
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

private struct GuideChannelHeadersColumn: View, Equatable {
    let channels: [GuideChannel]
    let contentOffsetY: CGFloat

    var body: some View {
        LazyVStack(spacing: 0) {
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
        .offset(
            GuideGridChromeLayout.channelHeadersOffset(
                for: CGPoint(x: 0, y: contentOffsetY)
            )
        )
    }
}

private struct GuideTimelineHeader: View {
    let timeline: GuideTimeline
    let contentOffset: CGFloat

    private var visibleMarks: [Date] {
        timeline.halfHourMarks.filter {
            GuideGridChromeLayout.isTimelineMarkVisible(
                markOffset: timeline.xOffset(for: $0),
                contentOffset: contentOffset
            )
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AppTheme.chrome

            ForEach(visibleMarks, id: \.self) { mark in
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

struct ChannelBadge: View {
    let channel: GuideChannel
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(channel.tint.gradient)

            if let iconURL = channel.iconURL {
                AsyncImage(url: iconURL) { phase in
                    if let image = phase.image {
                        AdaptiveChannelLogo(
                            image: image,
                            fallbackTint: channel.tint,
                            diameter: diameter
                        )
                    } else {
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay { Circle().stroke(.white.opacity(0.24), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        Text(channel.monogram)
            .font(.system(size: diameter * 0.31, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.6)
    }
}

/// Channel logos are commonly transparent artwork intended for either a light
/// or a dark surface. A channel-derived accent can therefore make parts of a
/// logo disappear. Render a tiny copy once, measure the visible pixels, and
/// choose the neutral surface with the stronger average WCAG contrast.
private struct AdaptiveChannelLogo: View {
    let image: Image
    let fallbackTint: Color
    let diameter: CGFloat

    @State private var backgroundTone: ChannelLogoBackgroundTone?

    var body: some View {
        ZStack {
            Circle().fill(backgroundColor)

            image
                .resizable()
                .scaledToFit()
                .padding(diameter * 0.12)
                .shadow(color: foregroundEdgeColor, radius: 0.8)
        }
        .task {
            guard backgroundTone == nil else { return }
            backgroundTone = renderedBackgroundTone()
        }
    }

    private var backgroundColor: Color {
        switch backgroundTone {
        case .light:
            Color(red: 0.94, green: 0.95, blue: 0.97)
        case .dark:
            Color(red: 0.055, green: 0.065, blue: 0.085)
        case nil:
            fallbackTint
        }
    }

    private var foregroundEdgeColor: Color {
        switch backgroundTone {
        case .light: .black.opacity(0.22)
        case .dark: .white.opacity(0.18)
        case nil: .clear
        }
    }

    @MainActor
    private func renderedBackgroundTone() -> ChannelLogoBackgroundTone? {
        let sampleSize: CGFloat = 64
        let renderer = ImageRenderer(
            content: image
                .resizable()
                .scaledToFit()
                .padding(sampleSize * 0.12)
                .frame(width: sampleSize, height: sampleSize)
        )
        renderer.scale = 1
        guard let cgImage = renderer.uiImage?.cgImage else { return nil }
        return ChannelLogoContrast.backgroundTone(for: cgImage)
    }
}

private enum ChannelLogoBackgroundTone {
    case light
    case dark
}

private enum ChannelLogoContrast {
    static func backgroundTone(for image: CGImage) -> ChannelLogoBackgroundTone? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let lightBackgroundLuminance = 0.90
        let darkBackgroundLuminance = 0.006
        var lightScore = 0.0
        var darkScore = 0.0
        var totalWeight = 0.0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha >= 0.08 else { continue }

            // CGContext gave us premultiplied components, so recover the
            // original logo colour before measuring its luminance.
            let red = min(1, Double(pixels[index]) / 255 / alpha)
            let green = min(1, Double(pixels[index + 1]) / 255 / alpha)
            let blue = min(1, Double(pixels[index + 2]) / 255 / alpha)
            let luminance = relativeLuminance(red: red, green: green, blue: blue)
            let weight = alpha * alpha

            lightScore += log(contrastRatio(luminance, lightBackgroundLuminance)) * weight
            darkScore += log(contrastRatio(luminance, darkBackgroundLuminance)) * weight
            totalWeight += weight
        }

        guard totalWeight > 1 else { return nil }
        return lightScore >= darkScore ? .light : .dark
    }

    private static func contrastRatio(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        (0.2126 * linearized(red)) + (0.7152 * linearized(green)) + (0.0722 * linearized(blue))
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
