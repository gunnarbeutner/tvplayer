import SwiftUI

private enum GuideGridMetrics {
    static let channelWidth: CGFloat = 220
    static let headerHeight: CGFloat = 58
    static let rowHeight: CGFloat = 94
    static let cardInset: CGFloat = 5
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
        return max(0, programmeOffset - leadingPadding)
    }

    static func isTimelineMarkVisible(markOffset: CGFloat, contentOffset: CGFloat) -> Bool {
        markOffset >= contentOffset
    }
}

struct GuideGridView: View {
    let channels: [GuideChannel]
    let timeline: GuideTimeline
    let now: Date
    let preferredProgramID: GuideProgram.ID?
    let focusScope: Namespace.ID
    let focusedProgramID: FocusState<GuideProgram.ID?>.Binding
    let recenterRequest: UUID
    let recordingState: (GuideProgram) -> TVRecordingState?
    let onActivate: (GuideProgram) -> Void

    @State private var contentOffset: CGPoint = .zero
    @State private var scrollPosition = ScrollPosition(x: 0)

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
        .onChange(of: focusedProgramID.wrappedValue) { _, newID in
            guard let newID else { return }
            keepFocusedProgrammeClearOfChannelColumn(newID)
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
        LazyVStack(alignment: .leading, spacing: 0) {
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
                        let leadingOcclusion = max(0, contentOffset.x - programmeOffset)
                        let isFocused = focusedProgramID.wrappedValue == program.id

                        GuideProgramCard(
                            program: program,
                            now: now,
                            isFocused: isFocused,
                            recordingState: recordingState(program),
                            leadingContentInset: leadingOcclusion
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .focusable()
                        .focused(focusedProgramID, equals: program.id)
                        .prefersDefaultFocus(program.id == preferredProgramID, in: focusScope)
                        .focusEffectDisabled()
                        .onTapGesture { onActivate(program) }
                        .frame(width: cardWidth, height: GuideGridMetrics.rowHeight - 10)
                        .offset(x: programmeOffset, y: 5)
                        .zIndex(isFocused ? 20 : 2)
                        .accessibilityLabel(accessibilityLabel(for: program, channel: channel))
                        .accessibilityHint("Select for programme details. Press Play to watch this channel live.")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onActivate(program) }
                    }
                }
                .frame(width: timeline.width, height: GuideGridMetrics.rowHeight, alignment: .topLeading)
            }
        }
        .frame(width: timeline.width, alignment: .topLeading)
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
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                GuideTimelineHeader(timeline: timeline, contentOffset: contentOffset.x)
                    .frame(width: timeline.width, height: GuideGridMetrics.headerHeight)
                    .offset(GuideGridChromeLayout.timelineContentOffset(for: contentOffset))
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
        LazyVStack(spacing: 0) {
            ForEach(channels) { channel in
                GuideChannelHeader(channel: channel)
                    .frame(width: GuideGridMetrics.channelWidth, height: GuideGridMetrics.rowHeight)
            }
        }
        .frame(width: GuideGridMetrics.channelWidth, alignment: .topLeading)
        .offset(GuideGridChromeLayout.channelHeadersOffset(for: contentOffset))
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

    private func keepFocusedProgrammeClearOfChannelColumn(_ programID: GuideProgram.ID) {
        guard let program = channels.lazy.flatMap(\.programs).first(where: { $0.id == programID }) else {
            return
        }
        let visibleStart = max(program.start, timeline.start)
        let programmeOffset = timeline.xOffset(for: visibleStart)

        Task { @MainActor in
            await Task.yield()
            guard focusedProgramID.wrappedValue == programID,
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
        HStack(spacing: 13) {
            ChannelBadge(channel: channel, diameter: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .background(AppTheme.chrome)
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
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(diameter * 0.12)
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
