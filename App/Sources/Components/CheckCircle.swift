import SwiftUI

/// The completion checkbox. Springs when checked.
struct CheckCircle: View {
    var isChecked: Bool
    var isCanceled = false
    var tint: Color = .accentColor
    var action: () -> Void
    /// Grows with the text size.
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .strokeBorder(isChecked ? tint : Color.secondary.opacity(0.6), lineWidth: 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                            .fill(isChecked ? tint : .clear)
                    )
                if isChecked {
                    Image(systemName: isCanceled ? "xmark" : "checkmark")
                        .font(.system(size: side * 0.55, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: side, height: side)
            .scaleEffect(isChecked || reduceMotion ? 1.0 : 0.95)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.55), value: isChecked)
            .contentShape(Rectangle().inset(by: -10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isChecked ? "Completed" : "Not completed")
        .accessibilityAddTraits(.isButton)
    }
}
