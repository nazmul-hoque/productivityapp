import Foundation

/// All of a user's data plus the operations on it, as a plain value.
///
/// Views and persistence wrap this type; keeping it pure makes every rule testable
/// without a device. Deletion is soft (`deletedAt`) so it can sync later.
public struct TaskDatabase: Codable, Sendable, Equatable {
    public private(set) var todos: [UUID: Todo] = [:]
    public private(set) var projects: [UUID: Project] = [:]
    public private(set) var headings: [UUID: Heading] = [:]
    public private(set) var areas: [UUID: Area] = [:]
    public private(set) var tags: [UUID: Tag] = [:]

    /// Items in the trash longer than this are removed for good.
    public static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    public init() {}

    /// Rebuilds a database from stored rows (e.g. loaded from SQLite).
    public init(todos: [Todo], projects: [Project], headings: [Heading], areas: [Area], tags: [Tag]) {
        func index<T: Identifiable>(_ items: [T]) -> [UUID: T] where T.ID == UUID {
            Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
        self.todos = index(todos)
        self.projects = index(projects)
        self.headings = index(headings)
        self.areas = index(areas)
        self.tags = index(tags)
    }

    public func classifier(today: LocalDay) -> ListClassifier {
        ListClassifier(today: today, projects: projects)
    }

    // MARK: - Queries

    /// To-dos in a smart list, in display order.
    public func todos(in list: SmartList, today: LocalDay) -> [Todo] {
        let classifier = classifier(today: today)
        let items = todos.values.filter { classifier.isIn(list, $0) }
        switch list {
        case .today:
            return items.sorted { ($0.todayOrder ?? $0.order, $0.id.uuidString) < ($1.todayOrder ?? $1.order, $1.id.uuidString) }
        case .upcoming:
            return items.sorted {
                let a = classifier.upcomingDay(for: $0)!, b = classifier.upcomingDay(for: $1)!
                return (a, $0.order) < (b, $1.order)
            }
        case .logbook:
            return items.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        case .trash:
            return items.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        case .inbox, .anytime, .someday:
            return items.sorted(by: Self.byOrder)
        }
    }

    /// Today split into its two sections.
    public func todaySections(today: LocalDay) -> (today: [Todo], evening: [Todo]) {
        let classifier = classifier(today: today)
        let items = todos(in: .today, today: today)
        return (items.filter { classifier.todaySection(for: $0) == .today },
                items.filter { classifier.todaySection(for: $0) == .evening })
    }

    /// Upcoming grouped by day, ascending, including future occurrences of repeating
    /// to-dos up to `horizon` days ahead.
    public func upcoming(today: LocalDay, horizon: Int = 60) -> [DayGroup] {
        let classifier = classifier(today: today)
        var groups: [LocalDay: [Todo]] = [:]
        for todo in todos(in: .upcoming, today: today) {
            groups[classifier.upcomingDay(for: todo)!, default: []].append(todo)
        }
        // Preview later occurrences of open repeating to-dos (not yet real items).
        let end = today.adding(days: horizon)
        for todo in todos.values where todo.status == .open && !todo.isDeleted {
            guard let repetition = todo.repetition, repetition.rule.mode == .fixed else { continue }
            let from = max(repetition.occurrence, today).adding(days: 1)
            guard from <= end else { continue }
            for occurrence in RepeatEngine.occurrences(of: repetition.rule, in: from...end) {
                var preview = todo
                preview.when = .on(occurrence.day)
                preview.repetition?.occurrence = occurrence.day
                preview.repetition?.index = occurrence.index
                groups[occurrence.day, default: []].append(preview)
            }
        }
        return groups.keys.sorted().map { DayGroup(day: $0, todos: groups[$0]!) }
    }

    public func project(_ id: UUID) -> Project? { projects[id] }

    public func openProjects(inArea areaID: UUID?) -> [Project] {
        projects.values
            .filter { $0.areaID == areaID && !$0.isDeleted && $0.status == .open }
            .sorted(by: Self.byOrder)
    }

    public var sortedAreas: [Area] { areas.values.sorted(by: Self.byOrder) }
    public var sortedTags: [Tag] { tags.values.sorted(by: Self.byOrder) }

    /// The project's headings in order, each with its open to-dos. Items without a
    /// heading come first under a `nil` heading.
    public func sections(ofProject projectID: UUID) -> [ProjectSection] {
        let items = todos.values
            .filter { $0.projectID == projectID && !$0.isDeleted && $0.status == .open }
            .sorted(by: Self.byOrder)
        let projectHeadings = headings.values.filter { $0.projectID == projectID }.sorted(by: Self.byOrder)
        var result = [ProjectSection(heading: nil, todos: items.filter { $0.headingID == nil })]
        for heading in projectHeadings {
            result.append(ProjectSection(heading: heading, todos: items.filter { $0.headingID == heading.id }))
        }
        return result
    }

    /// Open to-dos directly in an area (not inside one of its projects).
    public func looseTodos(inArea areaID: UUID) -> [Todo] {
        todos.values
            .filter { $0.areaID == areaID && $0.projectID == nil && !$0.isDeleted && $0.status == .open }
            .sorted(by: Self.byOrder)
    }

    /// Fraction of a project's to-dos that are done (canceled ones don't count).
    public func progress(ofProject projectID: UUID) -> Double {
        let items = todos.values.filter { $0.projectID == projectID && !$0.isDeleted && $0.status != .canceled }
        guard !items.isEmpty else { return 0 }
        return Double(items.filter { $0.status == .completed }.count) / Double(items.count)
    }

    /// Case-insensitive search over titles, notes, checklist items, tags and containers.
    public func search(_ query: String) -> [Todo] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        func matches(_ s: String) -> Bool { s.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return todos.values.filter { todo in
            guard !todo.isDeleted else { return false }
            return matches(todo.title) || matches(todo.notes)
                || todo.checklist.contains { matches($0.title) }
                || todo.tagIDs.contains { tags[$0].map { matches($0.title) } ?? false }
                || todo.projectID.flatMap { projects[$0] }.map { matches($0.title) } == true
                || todo.areaID.flatMap { areas[$0] }.map { matches($0.title) } == true
        }
        .sorted { ($0.status.isClosed ? 1 : 0, $0.title) < ($1.status.isClosed ? 1 : 0, $1.title) }
    }

    // MARK: - To-dos

    /// Adds a to-do at the end of its list (and of Today, if it lands there).
    @discardableResult
    public mutating func add(_ todo: Todo, today: LocalDay) -> Todo {
        var todo = todo
        todo.order = FractionalIndex.between(lastOrder(ofSiblingsOf: todo), nil)
        if classifier(today: today).isIn(.today, todo) {
            todo.todayOrder = FractionalIndex.between(lastTodayOrder(today: today), nil)
        }
        todos[todo.id] = todo
        return todo
    }

    /// Replaces a to-do with an edited copy.
    public mutating func update(_ todo: Todo, now: Date = Date()) {
        guard todos[todo.id] != nil else { return }
        var todo = todo
        todo.updatedAt = now
        todos[todo.id] = todo
    }

    public mutating func modify(_ id: UUID, now: Date = Date(), _ change: (inout Todo) -> Void) {
        guard var todo = todos[id] else { return }
        change(&todo)
        todo.updatedAt = now
        todos[id] = todo
    }

    /// Completes a to-do. For a repeating to-do this also creates the next instance,
    /// which is returned.
    @discardableResult
    public mutating func complete(_ id: UUID, now: Date = Date(), timeZone: TimeZone = .current) -> Todo? {
        close(id, as: .completed, now: now, timeZone: timeZone)
    }

    /// Cancels a to-do (it goes to the Logbook, marked canceled). Repeating to-dos continue.
    @discardableResult
    public mutating func cancel(_ id: UUID, now: Date = Date(), timeZone: TimeZone = .current) -> Todo? {
        close(id, as: .canceled, now: now, timeZone: timeZone)
    }

    private mutating func close(_ id: UUID, as status: ItemStatus, now: Date, timeZone: TimeZone) -> Todo? {
        guard let todo = todos[id], todo.status == .open else { return nil }
        modify(id, now: now) {
            $0.status = status
            $0.completedAt = now
        }
        guard let repetition = todo.repetition else { return nil }
        // Only spawn once per series: an existing open instance means this was a duplicate.
        if todos.values.contains(where: { $0.repetition?.seriesID == repetition.seriesID && $0.status == .open && !$0.isDeleted }) {
            return nil
        }
        let today = LocalDay(now, timeZone: timeZone)
        let current = Occurrence(day: repetition.occurrence, index: repetition.index)
        guard let next = RepeatEngine.next(after: current, of: repetition.rule, completedOn: today, today: today) else {
            return nil
        }
        var instance = todo
        instance.id = UUID()
        instance.status = .open
        instance.completedAt = nil
        instance.createdAt = now
        instance.updatedAt = now
        instance.when = .on(next.day)
        instance.reminder = repetition.rule.reminder ?? todo.reminder
        instance.deadline = repetition.rule.deadlineOffset.map { next.day.adding(days: $0) }
        instance.checklist = todo.checklist.map { var item = $0; item.isDone = false; return item }
        instance.repetition = Repetition(seriesID: repetition.seriesID, rule: repetition.rule,
                                         occurrence: next.day, index: next.index)
        instance.todayOrder = nil
        todos[instance.id] = instance
        return instance
    }

    /// Reopens a completed or canceled to-do.
    public mutating func reopen(_ id: UUID, now: Date = Date()) {
        modify(id, now: now) {
            $0.status = .open
            $0.completedAt = nil
        }
    }

    /// Sets when a to-do starts.
    public mutating func schedule(_ id: UUID, _ when: When, evening: Bool = false, today: LocalDay, now: Date = Date()) {
        guard let before = todos[id] else { return }
        let wasInToday = classifier(today: today).isIn(.today, before)
        modify(id, now: now) {
            $0.when = when
            $0.isEvening = evening
        }
        if !wasInToday, let after = todos[id], classifier(today: today).isIn(.today, after) {
            let key = FractionalIndex.between(lastTodayOrder(today: today, excluding: id), nil)
            modify(id, now: now) { $0.todayOrder = key }
        }
    }

    /// Reschedules one instance of a repeating to-do, leaving the rule alone.
    public mutating func rescheduleOccurrence(_ id: UUID, to day: LocalDay, today: LocalDay, now: Date = Date()) {
        schedule(id, .on(day), today: today, now: now)
    }

    /// Moves a repeating series so that this and future instances follow the new day.
    public mutating func rescheduleSeries(_ id: UUID, to day: LocalDay, today: LocalDay, now: Date = Date()) {
        guard let repetition = todos[id]?.repetition else { return }
        let rule = RepeatEngine.rule(repetition.rule, rescheduledTo: day)
        modify(id, now: now) {
            $0.repetition = Repetition(seriesID: repetition.seriesID, rule: rule, occurrence: day, index: repetition.index)
        }
        schedule(id, .on(day), today: today, now: now)
    }

    /// Pushes a to-do's reminder back, from a notification action. Its start day follows the
    /// reminder, so a snooze past midnight moves it to the next day; for a repeating to-do only
    /// this instance moves. "Tomorrow" keeps the reminder's time.
    public mutating func snooze(_ id: UUID, _ snooze: Snooze, now: Date = Date(), timeZone: TimeZone = .current) {
        guard let todo = todos[id], todo.status == .open else { return }
        let today = LocalDay(now, timeZone: timeZone)
        let day: LocalDay
        let time: TimeOfDay
        switch snooze {
        case .oneHour:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let fire = now.addingTimeInterval(60 * 60)
            let c = calendar.dateComponents([.hour, .minute], from: fire)
            day = LocalDay(fire, timeZone: timeZone)
            time = TimeOfDay(hour: c.hour!, minute: c.minute!)
        case .tomorrow:
            day = today.adding(days: 1)
            time = todo.reminder ?? TimeOfDay(hour: 9)
        }
        if todo.when != .on(day) {
            schedule(id, .on(day), evening: todo.isEvening, today: today, now: now)
        }
        modify(id, now: now) { $0.reminder = time }
    }

    /// Moves a to-do into a project (optionally under a heading), an area, or back to the
    /// inbox when both are `nil`. It goes to the end of its new container.
    public mutating func move(_ id: UUID, toProject projectID: UUID?, heading headingID: UUID? = nil, area areaID: UUID? = nil,
                              now: Date = Date()) {
        guard var todo = todos[id] else { return }
        todo.projectID = projectID
        todo.headingID = projectID == nil ? nil : headingID
        todo.areaID = projectID == nil ? areaID : nil
        if projectID == nil && areaID == nil && todo.when == .anytime {
            todo.when = .inbox
        } else if (projectID != nil || areaID != nil) && todo.when == .inbox {
            todo.when = .anytime
        }
        todo.order = FractionalIndex.between(lastOrder(ofSiblingsOf: todo, excluding: id), nil)
        todo.updatedAt = now
        todos[id] = todo
    }

    /// Places a to-do between two neighbours in its list. Pass `nil` for an end.
    public mutating func reorder(_ id: UUID, after previous: UUID?, before next: UUID?, inToday: Bool = false, now: Date = Date()) {
        let key: (Todo) -> String? = { inToday ? ($0.todayOrder ?? $0.order) : $0.order }
        let lower = previous.flatMap { todos[$0] }.flatMap(key)
        var upper = next.flatMap { todos[$0] }.flatMap(key)
        if let l = lower, let u = upper, l >= u { upper = nil }  // stale neighbours; append after `previous`
        let newKey = FractionalIndex.between(lower, upper)
        modify(id, now: now) {
            if inToday { $0.todayOrder = newKey } else { $0.order = newKey }
        }
    }

    /// Soft-deletes a to-do into the Trash.
    public mutating func trash(_ id: UUID, now: Date = Date()) {
        modify(id, now: now) { $0.deletedAt = now }
    }

    public mutating func restore(_ id: UUID, now: Date = Date()) {
        modify(id, now: now) { $0.deletedAt = nil }
    }

    /// Permanently removes items that have been in the trash past the retention period.
    public mutating func purgeTrash(now: Date = Date(), olderThan retention: TimeInterval = trashRetention) {
        todos = todos.filter { _, todo in
            guard let deleted = todo.deletedAt else { return true }
            return now.timeIntervalSince(deleted) < retention
        }
    }

    // MARK: - Checklists

    public mutating func addChecklistItem(_ title: String, to id: UUID, now: Date = Date()) {
        modify(id, now: now) { $0.checklist.append(ChecklistItem(title: title)) }
    }

    public mutating func toggleChecklistItem(_ itemID: UUID, in id: UUID, now: Date = Date()) {
        modify(id, now: now) { todo in
            guard let index = todo.checklist.firstIndex(where: { $0.id == itemID }) else { return }
            todo.checklist[index].isDone.toggle()
        }
    }

    // MARK: - Projects, headings, areas, tags

    @discardableResult
    public mutating func addProject(_ project: Project) -> Project {
        var project = project
        let last = projects.values.filter { $0.areaID == project.areaID }.map(\.order).max()
        project.order = FractionalIndex.between(last, nil)
        projects[project.id] = project
        return project
    }

    public mutating func updateProject(_ project: Project, now: Date = Date()) {
        guard projects[project.id] != nil else { return }
        var project = project
        project.updatedAt = now
        projects[project.id] = project
    }

    /// Completes a project; its remaining open to-dos are marked completed too.
    public mutating func completeProject(_ id: UUID, now: Date = Date()) {
        guard var project = projects[id], project.status == .open else { return }
        project.status = .completed
        project.completedAt = now
        project.updatedAt = now
        projects[id] = project
        for todo in todos.values where todo.projectID == id && todo.status == .open && !todo.isDeleted {
            modify(todo.id, now: now) {
                $0.status = .completed
                $0.completedAt = now
            }
        }
    }

    public mutating func trashProject(_ id: UUID, now: Date = Date()) {
        guard var project = projects[id] else { return }
        project.deletedAt = now
        project.updatedAt = now
        projects[id] = project
    }

    @discardableResult
    public mutating func addHeading(_ title: String, toProject projectID: UUID) -> Heading {
        let last = headings.values.filter { $0.projectID == projectID }.map(\.order).max()
        let heading = Heading(projectID: projectID, title: title, order: FractionalIndex.between(last, nil))
        headings[heading.id] = heading
        return heading
    }

    /// Deletes a heading; its to-dos move to the top of the project.
    public mutating func removeHeading(_ id: UUID, now: Date = Date()) {
        guard headings.removeValue(forKey: id) != nil else { return }
        for todo in todos.values where todo.headingID == id {
            modify(todo.id, now: now) { $0.headingID = nil }
        }
    }

    @discardableResult
    public mutating func addArea(_ title: String) -> Area {
        let area = Area(title: title, order: FractionalIndex.between(areas.values.map(\.order).max(), nil))
        areas[area.id] = area
        return area
    }

    /// Deletes an area. Its projects and loose to-dos stay, without an area.
    public mutating func removeArea(_ id: UUID, now: Date = Date()) {
        guard areas.removeValue(forKey: id) != nil else { return }
        for project in projects.values where project.areaID == id {
            var project = project
            project.areaID = nil
            updateProject(project, now: now)
        }
        for todo in todos.values where todo.areaID == id {
            modify(todo.id, now: now) {
                $0.areaID = nil
                if $0.when == .anytime && $0.projectID == nil { $0.when = .inbox }
            }
        }
    }

    /// Finds a tag by name (case-insensitive) or creates it.
    @discardableResult
    public mutating func tag(named title: String) -> Tag {
        if let existing = tags.values.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            return existing
        }
        let tag = Tag(title: title, order: FractionalIndex.between(tags.values.map(\.order).max(), nil))
        tags[tag.id] = tag
        return tag
    }

    /// Turns a to-do into a project in the same place. Its checklist items become the
    /// project's to-dos; its notes, deadline, tags and start carry over.
    @discardableResult
    public mutating func convertToProject(_ id: UUID, today: LocalDay, now: Date = Date()) -> Project? {
        guard let todo = todos[id], todo.projectID == nil, !todo.isDeleted else { return nil }
        let when: When = todo.when == .inbox ? .anytime : todo.when
        let project = addProject(Project(title: todo.title, notes: todo.notes, areaID: todo.areaID, when: when,
                                         deadline: todo.deadline, tagIDs: todo.tagIDs, createdAt: now))
        for item in todo.checklist {
            let child = Todo(title: item.title, projectID: project.id, when: .anytime,
                             status: item.isDone ? .completed : .open, createdAt: now,
                             completedAt: item.isDone ? now : nil)
            add(child, today: today)
        }
        todos.removeValue(forKey: id)
        return project
    }

    // MARK: - Quick add

    /// Creates a to-do from parsed quick-add text, resolving `/name` to a project or area
    /// and `#name` to tags (created if new). `defaultWhen` (and `evening`) apply when the
    /// text gives no start. With an `insertion`, the to-do goes between those neighbours,
    /// unless the text moved it to another list, in which case it goes to the end there.
    @discardableResult
    public mutating func add(_ parsed: QuickAddResult, defaultWhen: When = .inbox, evening: Bool = false,
                             projectID: UUID? = nil, headingID: UUID? = nil, areaID: UUID? = nil,
                             at insertion: Insertion? = nil, today: LocalDay, now: Date = Date()) -> Todo {
        var projectID = projectID
        var areaID = areaID
        var headingID = headingID
        if let name = parsed.project {
            if let project = projects.values.first(where: { !$0.isDeleted && $0.status == .open && $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
                projectID = project.id
                areaID = nil
                headingID = nil
            } else if let area = areas.values.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
                areaID = area.id
                projectID = nil
                headingID = nil
            }
        }
        var when = parsed.when ?? defaultWhen
        if when == .inbox && (projectID != nil || areaID != nil) { when = .anytime }
        let tagIDs = Set(parsed.tags.map { tag(named: $0).id })
        let todo = Todo(title: parsed.title, areaID: projectID == nil ? areaID : nil, projectID: projectID,
                        headingID: headingID, when: when, isEvening: parsed.isEvening || (parsed.when == nil && evening),
                        deadline: parsed.deadline, reminder: parsed.reminder, tagIDs: tagIDs, createdAt: now)
        let added = add(todo, today: today)
        guard let insertion, let neighbour = (insertion.after ?? insertion.before).flatMap({ todos[$0] }),
              isSibling(added, of: neighbour, inToday: insertion.inToday, today: today) else { return added }
        reorder(added.id, after: insertion.after, before: insertion.before, inToday: insertion.inToday, now: now)
        return todos[added.id]!
    }

    /// Whether two to-dos sit in the same section of a list, so one can be ordered next to the other.
    private func isSibling(_ a: Todo, of b: Todo, inToday: Bool, today: LocalDay) -> Bool {
        let classifier = classifier(today: today)
        if inToday {
            return classifier.isIn(.today, a) && classifier.isIn(.today, b)
                && classifier.todaySection(for: a) == classifier.todaySection(for: b)
        }
        guard a.projectID == b.projectID, a.areaID == b.areaID, a.headingID == b.headingID else { return false }
        // Projects and areas list their to-dos whatever their start; loose ones are split by list.
        if a.projectID != nil || a.areaID != nil { return true }
        return [SmartList.inbox, .anytime, .someday].allSatisfy { classifier.isIn($0, a) == classifier.isIn($0, b) }
    }

    // MARK: - Helpers

    static func byOrder<T: Ordered>(_ a: T, _ b: T) -> Bool { (a.order, a.id.uuidString) < (b.order, b.id.uuidString) }

    private func lastOrder(ofSiblingsOf todo: Todo, excluding id: UUID? = nil) -> String? {
        todos.values
            .filter { $0.id != id && $0.projectID == todo.projectID && $0.areaID == todo.areaID && $0.headingID == todo.headingID }
            .map(\.order).max()
    }

    private func lastTodayOrder(today: LocalDay, excluding id: UUID? = nil) -> String? {
        let classifier = classifier(today: today)
        return todos.values
            .filter { $0.id != id && classifier.isIn(.today, $0) }
            .map { $0.todayOrder ?? $0.order }.max()
    }
}

/// How far a reminder is pushed back from its notification.
public enum Snooze: String, Sendable, CaseIterable {
    case oneHour, tomorrow
}

/// A spot between two to-dos in a list, for adding a new one there. `nil` means that end
/// of the section; `inToday` orders by the Today order instead of the list order.
public struct Insertion: Hashable, Sendable {
    public var after: UUID?
    public var before: UUID?
    public var inToday: Bool

    public init(after: UUID?, before: UUID?, inToday: Bool = false) {
        self.after = after
        self.before = before
        self.inToday = inToday
    }
}

/// One day in Upcoming.
public struct DayGroup: Identifiable, Sendable {
    public var day: LocalDay
    public var todos: [Todo]
    public var id: LocalDay { day }
}

/// A heading in a project and its open to-dos; `heading` is `nil` for the untitled top section.
public struct ProjectSection: Identifiable, Sendable {
    public var heading: Heading?
    public var todos: [Todo]
    public var id: UUID? { heading?.id }
}

// Encoded as plain arrays rather than UUID-keyed dictionaries, so the JSON is readable.
extension TaskDatabase {
    enum CodingKeys: String, CodingKey {
        case todos, projects, headings, areas, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func load<T: Decodable & Identifiable>(_ key: CodingKeys) throws -> [UUID: T] where T.ID == UUID {
            let items = try c.decodeIfPresent([T].self, forKey: key) ?? []
            return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
        todos = try load(.todos)
        projects = try load(.projects)
        headings = try load(.headings)
        areas = try load(.areas)
        tags = try load(.tags)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(todos.values.sorted { $0.createdAt < $1.createdAt }, forKey: .todos)
        try c.encode(projects.values.sorted { $0.createdAt < $1.createdAt }, forKey: .projects)
        try c.encode(headings.values.sorted(by: Self.byOrder), forKey: .headings)
        try c.encode(areas.values.sorted(by: Self.byOrder), forKey: .areas)
        try c.encode(tags.values.sorted(by: Self.byOrder), forKey: .tags)
    }
}

protocol Ordered {
    var id: UUID { get }
    var order: String { get }
}

extension Todo: Ordered {}
extension Project: Ordered {}
extension Heading: Ordered {}
extension Area: Ordered {}
extension Tag: Ordered {}
