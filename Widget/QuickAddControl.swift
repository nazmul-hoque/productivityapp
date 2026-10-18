import AppIntents
import SwiftUI
import WidgetKit

/// A "New To-Do" button for Control Center, the Lock Screen and the Action button (iOS 18).
@available(iOS 18.0, *)
struct QuickAddControl: ControlWidget {
    static let kind = "com.nazmulhoque.daybook.quick-add"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenQuickAddIntent()) {
                Label("New To-Do", systemImage: "plus.circle")
            }
        }
        .displayName("New To-Do")
        .description("Opens Daybook ready to add a to-do.")
    }
}
