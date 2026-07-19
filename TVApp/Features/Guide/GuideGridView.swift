import SwiftUI

private enum GuideGridMetrics {
    static let channelWidth: CGFloat = 220
    static let headerHeight: CGFloat = 58
    static let rowHeight: CGFloat = 94
    static let cardInset: CGFloat = 5
}

private struct GuideScrollOriginPreferenceKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero

    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

struct GuideGridView: View {
    let channels: [GuideChannel]
    let timeline: GuideTimeline
    let now: Date
    let focusedProgramID: FocusState<GuideProgram.ID?>.Binding
    let recenterRequest: UUID
    let onActivate: (GuideProgram) -> Void

    @State private var contentOrigin: CGPoint = .zero

    private var contentWidth: CGFloat {
        GuideGridMetrics.channelWidth + timeline.width
    }

    private var contentHeight: CGFloat {
        GuideGridMetrics.headerHeight + CGFloat(channels.count) * GuideGridMetrics.rowHeight
    }

    private var pinnedX: CGFloat {
        max(0, -contentOrigin.x)
    }

    private var pinnedY: CGFloat {
        max(0, -contentOrigin.y)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: GuideScrollOriginPreferenceKey.self,
                            value: geometry.frame(in: .named("guide-scroll")).origin
                        )
                    }
                    .frame(width: 1, height: 1)

                    guideBackground
                    programmeCards
                    nowIndicator
                    timelineHeader
                    channelHeaders
                    cornerHeader

                    Color.clear
                        .frame(width: 2, height: 2)
                        .offset(
                            x: GuideGridMetrics.channelWidth + timeline.xOffset(for: now),
                            y: GuideGridMetrics.headerHeight
                        )
                        .id("guide-now-anchor")
                }
                .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
            }
            .coordinateSpace(name: "guide-scroll")
            .background(AppTheme.background)
            .onPreferenceChange(GuideScrollOriginPreferenceKey.self) { contentOrigin = $0 }
            .onAppear { scrollToNow(using: proxy, animated: false) }
            .onChange(of: recenterRequest) { _, _ in scrollToNow(using: proxy, animated: true) }
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
                        let isFocused = focusedProgramID.wrappedValue == program.id

                        GuideProgramCard(
                            program: program,
                            now: now,
                            isFocused: isFocused
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .focusable()
                        .focused(focusedProgramID, equals: program.id)
                        .focusEffectDisabled()
                        .onTapGesture { onActivate(program) }
                        .frame(width: cardWidth, height: GuideGridMetrics.rowHeight - 10)
                        .offset(x: timeline.xOffset(for: visibleStart) + 2, y: 5)
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
        GuideTimelineHeader(timeline: timeline)
            .frame(width: timeline.width, height: GuideGridMetrics.headerHeight)
            .offset(x: GuideGridMetrics.channelWidth, y: pinnedY)
            .zIndex(30)
    }

    private var channelHeaders: some View {
        LazyVStack(spacing: 0) {
            ForEach(channels) { channel in
                GuideChannelHeader(channel: channel)
                    .frame(width: GuideGridMetrics.channelWidth, height: GuideGridMetrics.rowHeight)
            }
        }
        .frame(width: GuideGridMetrics.channelWidth, alignment: .topLeading)
        .offset(x: pinnedX, y: GuideGridMetrics.headerHeight)
        .zIndex(31)
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
        .offset(x: pinnedX, y: pinnedY)
        .zIndex(40)
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

    private func scrollToNow(using proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo("guide-now-anchor", anchor: UnitPoint(x: 0.28, y: 0.04))
        }

        Task { @MainActor in
            await Task.yield()
            if animated {
                withAnimation(.easeInOut(duration: 0.35), action)
            } else {
                action()
            }
        }
    }
}

private struct GuideTimelineHeader: View {
    let timeline: GuideTimeline

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
