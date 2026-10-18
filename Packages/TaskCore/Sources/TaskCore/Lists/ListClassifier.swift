import Foundation

/// The built-in lists in the sidebar.
public enum SmartList: String, CaseIterable, Codable, Sendable, Identifiable {
    case inbox, today, upcoming, anytime, someday, logbook, trash

    public var id: String { rawValue }
}

public enum TodaySection: String, Codable, Sendable {
    case today, evening
}

/// Decides which smart lists a to-do appears in. This is the single source of truth
/// for "where does this item show up?", so every view goes through it.
public struct ListClassifier: Sendable {
    public var today: LocalDay
    public var projects: [UUID: Project]

    public init(today: LocalDay, projects: [UUID: Project] = [:]) {
        self.today = today
        self.projects = projects
    }

    public func lists(for todo: Todo) -> Set<SmartList> {
        let project = todo.projectID.flatMap { projects[$0] }
        if todo.isDeleted || project?.isDeleted == true { return [.trash] }
        if todo.status.isClosed || project?.status.isClosed == true { return [.logbook] }

        var lists: Set<SmartList> = []
        switch effectiveWhen(of: todo, in: project) {
        case .inbox:
            lists.insert(.inbox)
        case .anytime:
            lists.insert(.anytime)
        case .someday:
            lists.insert(.someday)
        case .on(let day) where day <= today:
            lists.formUnion([.today, .anytime])
        case .on:
            lists.insert(.upcoming)
        case nil:
            break  // Waiting on a project that starts later; shown inside the project only.
        }

        if let deadline = todo.deadline {
            if deadline <= today {
                lists.insert(.today)
            } else if !lists.contains(.today) {
                lists.insert(.upcoming)
            }
        }
        return lists
    }

    public func isIn(_ list: SmartList, _ todo: Todo) -> Bool {
        lists(for: todo).contains(list)
    }

    /// Where the to-do sits within Today, or `nil` if it is not in Today.
    public func todaySection(for todo: Todo) -> TodaySection? {
        guard isIn(.today, todo) else { return nil }
        if todo.isEvening, case .on(let day) = todo.when, day <= today { return .evening }
        return .today
    }

    /// The day the to-do is listed under in Upcoming: its start day, or else its deadline.
    public func upcomingDay(for todo: Todo) -> LocalDay? {
        guard isIn(.upcoming, todo) else { return nil }
        if case .on(let day) = todo.when, day > today { return day }
        if let deadline = todo.deadline, deadline > today { return deadline }
        return nil
    }

    /// The to-do's start, taking its project into account. `nil` means it is held back
    /// until its project starts.
    func effectiveWhen(of todo: Todo, in project: Project?) -> When? {
        var when = todo.when
        if when == .inbox && (todo.projectID != nil || todo.areaID != nil) {
            when = .anytime
        }
        guard let project, when == .anytime else { return when }
        switch project.when {
        case .someday:
            return .someday
        case .on(let day) where day > today:
            return nil
        default:
            return when
        }
    }
}
