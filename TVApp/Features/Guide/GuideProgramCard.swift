import SwiftUI

struct GuideProgramCard: View {
    let program: GuideProgram
    let now: Date
    let isFocused: Bool

    private var phase: GuideProgram.Phase {
        program.phase(at: now)
    }

    private var background: Color {
        if isFocused { return AppTheme.focused }
        switch phase {
        case .past: return AppTheme.past
        case .current: return AppTheme.current
        case .future: return AppTheme.surface
        }
    }

    private var progress: CGFloat {
        guard phase == .current, program.duration > 0 else { return 0 }
        return min(max(0, now.timeIntervalSince(program.start) / program.duration), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(background)

                if phase == .current, !isFocused {
                    Rectangle()
                        .fill(AppTheme.accent)
                        .frame(width: geometry.size.width * progress, height: 5)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(program.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if geometry.size.width >= 118 {
                        Text("\(program.start.formatted(date: .omitted, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(isFocused ? Color.white : AppTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? AppTheme.focusBorder : Color.white.opacity(0.16), lineWidth: isFocused ? 4 : 1)
        }
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}
