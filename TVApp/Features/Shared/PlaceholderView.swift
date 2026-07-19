import SwiftUI

struct PlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: systemImage)
                    .font(.system(size: 72, weight: .medium))
                    .foregroundStyle(AppTheme.accent)

                Text(title)
                    .font(.largeTitle.bold())

                Text(message)
                    .font(.title3)
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
            }
        }
    }
}
