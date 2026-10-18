import SwiftUI

/// A project's progress, shown as a filling pie inside a ring.
struct ProgressRing: View {
    var progress: Double
    var size: CGFloat = 18
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().strokeBorder(tint, lineWidth: 1.5)
            PieSlice(fraction: progress)
                .fill(tint)
                .padding(size * 0.18)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut, value: progress)
        .accessibilityLabel("\(Int(progress * 100)) percent complete")
    }
}

private struct PieSlice: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * min(fraction, 1)), clockwise: false)
        path.closeSubpath()
        return path
    }
}
