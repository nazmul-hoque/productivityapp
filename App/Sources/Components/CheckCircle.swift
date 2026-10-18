import SwiftUI

/// The completion checkbox. Springs when checked.
struct CheckCircle: View {
    var isChecked: Bool
    var isCanceled = false
    var tint: Color = .accentColor
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isChecked ? tint : Color.secondary.opacity(0.6), lineWidth: 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isChecked ? tint : .clear)
                    )
                if isChecked {
                    Image(systemName: isCanceled ? "xmark" : "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 20, height: 20)
            .scaleEffect(isChecked ? 1.0 : 0.95)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isChecked)
            .contentShape(Rectangle().inset(by: -10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isChecked ? "Completed" : "Not completed")
        .accessibilityAddTraits(.isButton)
    }
}
