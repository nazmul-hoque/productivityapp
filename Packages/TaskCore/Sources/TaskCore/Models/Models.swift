import Foundation

/// When a to-do (or project) becomes actionable. Kept separate from the deadline.
public enum When: Hashable, Codable, Sendable {
    /// Captured but not yet processed.
    case inbox
    /// Actionable now, no particular day.
    case anytime
    /// Parked; hidden from Today and Anytime.
    case someday
    /// Starts on this day. A day on or before today means "Today".
    case on(LocalDay)
}

public enum ItemStatus: String, Codable, Sendable {
    case open, completed, canceled

    public var isClosed: Bool { self != .open }
}

public struct Todo: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var areaID: UUID?
    public var projectID: UUID?
    public var headingID: UUID?
    public var when: When
    /// Shows in the This Evening section when the to-do is in Today.
    public var isEvening: Bool
    public var deadline: LocalDay?
    /// Reminder time on the start day.
    public var reminder: TimeOfDay?
    public var repetition: Repetition?
    public var tagIDs: Set<UUID>
    public var checklist: [ChecklistItem]
    public var status: ItemStatus
    /// Position within its list, project or heading (fractional index).
    public var order: String
    /// Position within Today (fractional index), independent of `order`.
    public var todayOrder: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        areaID: UUID? = nil,
        projectID: UUID? = nil,
        headingID: UUID? = nil,
        when: When = .inbox,
        isEvening: Bool = false,
        deadline: LocalDay? = nil,
        reminder: TimeOfDay? = nil,
        repetition: Repetition? = nil,
        tagIDs: Set<UUID> = [],
        checklist: [ChecklistItem] = [],
        status: ItemStatus = .open,
        order: String = FractionalIndex.first,
        todayOrder: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        completedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.areaID = areaID
        self.projectID = projectID
        self.headingID = headingID
        self.when = when
        self.isEvening = isEvening
        self.deadline = deadline
        self.reminder = reminder
        self.repetition = repetition
        self.tagIDs = tagIDs
        self.checklist = checklist
        self.status = status
        self.order = order
        self.todayOrder = todayOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }
}

/// Links a to-do instance to its repeating series.
public struct Repetition: Hashable, Codable, Sendable {
    public var seriesID: UUID
    public var rule: RepeatRule
    /// The scheduled day of this instance (before any one-off reschedule).
    public var occurrence: LocalDay
    /// 1-based position in the series, used by count-limited rules.
    public var index: Int

    public init(seriesID: UUID = UUID(), rule: RepeatRule, occurrence: LocalDay, index: Int = 1) {
        self.seriesID = seriesID
        self.rule = rule
        self.occurrence = occurrence
        self.index = index
    }
}

public struct ChecklistItem: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var isDone: Bool

    public init(id: UUID = UUID(), title: String, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }
}

public struct Project: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var areaID: UUID?
    /// `.inbox` is treated as `.anytime` for projects.
    public var when: When
    public var deadline: LocalDay?
    public var tagIDs: Set<UUID>
    public var status: ItemStatus
    public var order: String
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        areaID: UUID? = nil,
        when: When = .anytime,
        deadline: LocalDay? = nil,
        tagIDs: Set<UUID> = [],
        status: ItemStatus = .open,
        order: String = FractionalIndex.first,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        completedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.areaID = areaID
        self.when = when
        self.deadline = deadline
        self.tagIDs = tagIDs
        self.status = status
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }
}

public struct Heading: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var order: String

    public init(id: UUID = UUID(), projectID: UUID, title: String, order: String = FractionalIndex.first) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.order = order
    }
}

/// An ongoing area of responsibility (Work, Family, Health). Never completes.
public struct Area: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var tagIDs: Set<UUID>
    public var order: String

    public init(id: UUID = UUID(), title: String, tagIDs: Set<UUID> = [], order: String = FractionalIndex.first) {
        self.id = id
        self.title = title
        self.tagIDs = tagIDs
        self.order = order
    }
}

public struct Tag: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var parentID: UUID?
    public var order: String

    public init(id: UUID = UUID(), title: String, parentID: UUID? = nil, order: String = FractionalIndex.first) {
        self.id = id
        self.title = title
        self.parentID = parentID
        self.order = order
    }
}
