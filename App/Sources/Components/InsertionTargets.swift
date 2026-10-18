import SwiftUI
import TaskCore

/// A section of a list that the add button can be dropped into.
struct DropSection: Equatable {
    /// Unique among the sections on screen.
    var id: String
    var context: QuickAddContext
    /// The section's to-dos in display order, or `nil` if new ones always go to the end
    /// (Upcoming orders by day, not by hand).
    var order: [UUID]?
    var inToday = false
}

/// Where a dragged add button would put the new to-do, and where to draw the line.
struct DropTarget: Equatable {
    var context: QuickAddContext
    /// The line, in global coordinates.
    var y: CGFloat
    var minX: CGFloat
    var maxX: CGFloat
}

/// Frames of the rows and section headers on screen, reported by `.dropSlot(...)`.
///
/// A plain class rather than observable state: rows update it on every scroll frame and
/// nothing needs to re-render because of that. It is read when the add button moves.
@MainActor
final class InsertionTargets {
    private struct Key: Hashable {
        var section: String
        var row: UUID?
    }

    private struct Entry {
        var frame: CGRect
        var section: DropSection
        /// `nil` for a section header.
        var row: UUID?
    }

    private var entries: [Key: Entry] = [:]

    /// Scrolls the list under the dragged add button near its edges.
    let autoScroller = AutoScroller()

    func set(_ frame: CGRect, section: DropSection, row: UUID?) {
        entries[Key(section: section.id, row: row)] = Entry(frame: frame, section: section, row: row)
    }

    func remove(section: String, row: UUID?) {
        entries[Key(section: section, row: row)] = nil
    }

    /// Frames cover a row's content, not its cell; the line sits this far outside them, in the cell padding.
    private let linePadding: CGFloat = 12

    /// The gap nearest to `point`, if it is within a row's height of a registered row or header.
    func target(at point: CGPoint) -> DropTarget? {
        // Headers can be narrower than their rows, so test x against each section's full width.
        var extents: [String: CGRect] = [:]
        for entry in entries.values {
            extents[entry.section.id] = extents[entry.section.id]?.union(entry.frame) ?? entry.frame
        }
        func distance(_ entry: Entry) -> CGFloat {
            max(0, entry.frame.minY - point.y, point.y - entry.frame.maxY)
        }
        let hit = entries.values
            .filter {
                let extent = extents[$0.section.id]!
                return extent.minX <= point.x && point.x <= extent.maxX && distance($0) < 44
            }
            .min { distance($0) < distance($1) }
        guard let hit else { return nil }
        let section = hit.section
        let extent = extents[section.id]!
        var context = section.context

        guard let order = section.order else {
            // Unordered: the new to-do joins the end of the section.
            return DropTarget(context: context, y: extent.maxY + linePadding, minX: extent.minX, maxX: extent.maxX)
        }

        let index: Int
        let y: CGFloat
        if let row = hit.row, let position = order.firstIndex(of: row) {
            let upperHalf = point.y < hit.frame.midY
            index = upperHalf ? position : position + 1
            y = upperHalf ? hit.frame.minY - linePadding : hit.frame.maxY + linePadding
        } else {
            index = 0  // a header: the top of its section
            y = hit.frame.maxY + linePadding
        }
        context.insertion = Insertion(after: index > 0 ? order[index - 1] : nil,
                                      before: index < order.count ? order[index] : nil,
                                      inToday: section.inToday)
        return DropTarget(context: context, y: y, minX: extent.minX, maxX: extent.maxX)
    }
}

extension EnvironmentValues {
    @Entry var insertionTargets: InsertionTargets?
}

extension View {
    /// Registers this row (or, with `row: nil`, a section header) as a place the add button can drop.
    /// A `nil` section (Logbook, Trash) registers nothing.
    func dropSlot(_ section: DropSection?, row: UUID?) -> some View {
        modifier(DropSlotModifier(section: section, row: row))
    }
}

private struct DropSlotModifier: ViewModifier {
    @Environment(\.insertionTargets) private var targets
    let section: DropSection?
    let row: UUID?
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                self.frame = frame
                if let section { targets?.set(frame, section: section, row: row) }
            }
            .onChange(of: section) { old, new in
                // Neighbours changed (a row added, moved or completed): same frame, new order.
                if let old { targets?.remove(section: old.id, row: row) }
                if let new, let frame { targets?.set(frame, section: new, row: row) }
            }
            .onDisappear { if let section { targets?.remove(section: section.id, row: row) } }
            // Lets the add button scroll this row's list while it is dragged near an edge.
            .background {
                if section != nil, let targets {
                    EnclosingScrollViewReader { targets.autoScroller.register($0) }
                }
            }
    }
}
