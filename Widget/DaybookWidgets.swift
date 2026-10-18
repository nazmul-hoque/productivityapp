import SwiftUI
import WidgetKit

@main
struct DaybookWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        if #available(iOS 18.0, *) {
            QuickAddControl()
        }
    }
}
