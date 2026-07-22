import SwiftUI

struct GuideProgramCard: View {
    let program: GuideProgram
    let now: Date
    let isFocused: Bool
    let isPlaying: Bool
    let recordingState: TVRecordingState?
    let leadingContentInset: CGFloat

    private var phase: GuideProgram.Phase {
        program.phase(at: now)
    }

    private var background: Color {
        if isFocused { return AppTheme.focused }
        if isPlaying { return AppTheme.playing }
        switch phase {
        case .past: return AppTheme.past
        case .current: return AppTheme.current
        case .future: return AppTheme.surface
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let safeLeadingInset = min(max(0, leadingContentInset), geometry.size.width)
            let visibleContentWidth = max(0, geometry.size.width - safeLeadingInset)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(background)

                if visibleContentWidth >= 46 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            if recordingState == .recording || recordingState == .upcoming {
                                Image(systemName: recordingState == .recording ? "record.circle.fill" : "clock.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(recordingState == .recording ? .red : AppTheme.accent)
                            }
                            Text(program.title)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }

                        if visibleContentWidth >= 118 {
                            Text("\(program.start.formatted(date: .omitted, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(isFocused ? Color.white : AppTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .frame(
                        width: visibleContentWidth,
                        height: geometry.size.height,
                        alignment: .topLeading
                    )
                    .offset(x: safeLeadingInset)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? AppTheme.focusBorder : Color.white.opacity(0.16), lineWidth: isFocused ? 4 : 1)
        }
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}
