import SwiftUI

/// The floating add button. Tap it to add at the end of the current list, or drag it
/// onto the list and let go where the new to-do should go.
struct AddButton: View {
    var action: () -> Void
    /// The finger's position in global coordinates while dragging, `nil` when the drag ends.
    var onDrag: (CGPoint?) -> Void = { _ in }
    /// Where the button was let go, in global coordinates.
    var onDrop: (CGPoint) -> Void = { _ in }

    @State private var taps = 0
    @State private var offset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(Circle().fill(Color.accentColor))
            .shadow(color: .black.opacity(isDragging ? 0.3 : 0.2), radius: isDragging ? 14 : 8, y: isDragging ? 8 : 4)
            .scaleEffect(isDragging ? 1.12 : 1)
            .offset(offset)
            .contentShape(Circle())
            .gesture(drag)
            .accessibilityElement()
            .accessibilityLabel("New To-Do")
            .accessibilityHint("Adds a to-do to this list")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
            .sensoryFeedback(.impact(weight: .medium), trigger: isDragging) { _, dragging in dragging }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging && hypot(value.translation.width, value.translation.height) > 10 {
                    withAnimation(.snappy(duration: 0.2)) { isDragging = true }
                }
                guard isDragging else { return }
                offset = value.translation
                onDrag(value.location)
            }
            .onEnded { value in
                if isDragging {
                    onDrag(nil)
                    onDrop(value.location)
                } else {
                    tap()
                }
                withAnimation(.spring(duration: 0.35)) {
                    isDragging = false
                    offset = .zero
                }
            }
    }

    private func tap() {
        taps += 1
        action()
    }
}
