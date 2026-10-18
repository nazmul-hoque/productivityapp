import UIKit

/// Feedback for actions whose view goes away straight after (a row swiped out of its list,
/// a completed project), where `.sensoryFeedback` would never fire.
@MainActor
enum Haptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func impact() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
