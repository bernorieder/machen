import Foundation

/// A change made in machen that Google hasn't confirmed yet. The store shows it in the list
/// right away and keeps it on disk until it's sent, so changes made offline survive quitting.
struct PendingChange: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case saveEvent(EventDraft, scope: EditScope)
        case deleteEvent(EventDraft, scope: EditScope)
        /// A new task, shown under `localID` until Google gives it an id.
        case createTask(TaskDraft, localID: String)
        /// An edit of a task; a changed list moves it with its subtasks, given in their order.
        case updateTask(TaskDraft, subtaskIDs: [String])
        /// Completing or reopening tasks of one list (a parent with its subtasks).
        case setCompleted(Bool, tasks: [TaskItem])
        case deleteTask(TaskDraft)
        /// A new list, shown under its local `remoteID` until Google gives it one.
        case createTaskList(TaskListInfo)
    }

    var id = UUID()
    let accountID: String
    let kind: Kind

    var changesEvents: Bool {
        switch kind {
        case .saveEvent, .deleteEvent: true
        default: false
        }
    }

    var changesTaskLists: Bool {
        if case .createTaskList = kind { return true }
        return false
    }

    /// The local id this change creates, for a task or list created offline.
    var createdLocalID: String? {
        switch kind {
        case .createTask(_, let localID): localID
        case .createTaskList(let list): list.remoteID
        default: nil
        }
    }

    /// Whether this change needs `localID` to exist, which a refused creation means it never will.
    func depends(on localID: String) -> Bool {
        func mentions(_ id: String?) -> Bool { id?.hasSuffix(localID) == true }
        switch kind {
        case .saveEvent, .deleteEvent, .createTaskList:
            return false
        case .createTask(let d, _):
            return mentions(d.listID) || mentions(d.parentID)
        case .updateTask(let d, let subtaskIDs):
            return mentions(d.taskID) || mentions(d.listID) || mentions(d.originalListID) || subtaskIDs.contains(localID)
        case .setCompleted(_, let tasks):
            return tasks.contains { mentions($0.taskID) || mentions($0.listID) }
        case .deleteTask(let d):
            return mentions(d.taskID) || mentions(d.homeListID)
        }
    }

    /// What the change is about, to name it when Google refuses it.
    var subject: String {
        let title: String
        switch kind {
        case .saveEvent(let d, _), .deleteEvent(let d, _): title = d.title
        case .createTask(let d, _), .updateTask(let d, _), .deleteTask(let d): title = d.title
        case .setCompleted(_, let tasks): title = tasks.first?.title ?? ""
        case .createTaskList(let list): title = list.title
        }
        return title.isEmpty ? "(No title)" : title
    }

    /// The change with the ids Google gave to tasks and lists created offline.
    func resolved(_ ids: IDMap) -> PendingChange {
        guard !ids.isEmpty else { return self }
        let kind: Kind
        switch self.kind {
        case .saveEvent, .deleteEvent:
            return self
        case .createTask(let d, let localID):
            kind = .createTask(d.resolved(ids), localID: localID)
        case .updateTask(let d, let subtaskIDs):
            kind = .updateTask(d.resolved(ids), subtaskIDs: subtaskIDs.map { ids($0) })
        case .setCompleted(let done, let tasks):
            kind = .setCompleted(done, tasks: tasks.map { $0.resolved(ids) })
        case .deleteTask(let d):
            kind = .deleteTask(d.resolved(ids))
        case .createTaskList(let list):
            kind = .createTaskList(list.resolved(ids))
        }
        return PendingChange(id: id, accountID: accountID, kind: kind)
    }

    // MARK: Showing it before Google has it

    // Applied to data just loaded from Google, and once to what's shown when the change is made.
    // Applying a change to data that already has it leaves that data as it is, except for moving
    // a whole series, which is why it's only applied to freshly loaded events.

    func apply(to events: [CalendarEvent], calendars: [CalendarInfo]) -> [CalendarEvent] {
        switch kind {
        case .saveEvent(let d, let scope):
            let target = calendars.first { $0.id == d.calendarID }
            if d.isNew {
                return events.filter { $0.eventID != d.newEventID } + [CalendarEvent(new: d, accountID: accountID, in: target)]
            }
            let home = d.originalCalendarID ?? d.calendarID
            let series = scope == .allEvents ? d.recurringEventID : nil
            return events.map { e in
                guard e.calendarID == home else { return e }
                if let series, e.recurringEventID == series { return e.edited(by: d, asSeries: true, in: target) }
                return e.eventID == d.eventID ? e.edited(by: d, asSeries: false, in: target) : e
            }
        case .deleteEvent(let d, let scope):
            let home = d.originalCalendarID ?? d.calendarID
            let series = scope == .allEvents ? d.recurringEventID : nil
            return events.filter { e in
                !(e.calendarID == home && (e.eventID == d.eventID || (series != nil && e.recurringEventID == series)))
            }
        default:
            return events
        }
    }

    func apply(to tasks: [TaskItem]) -> [TaskItem] {
        switch kind {
        case .createTask(let d, let localID):
            let task = TaskItem(taskID: localID, listID: d.listID, accountID: accountID, title: d.title, notes: d.notes,
                                due: d.hasDue ? d.due.startOfDay : nil, position: "", parentID: d.parentID)
            return tasks.filter { $0.taskID != localID } + [task]
        case .updateTask(let d, _):
            guard let taskID = d.taskID else { return tasks }
            return tasks.map { t in
                guard t.listID == d.homeListID else { return t }
                if t.taskID == taskID {
                    return TaskItem(taskID: taskID, listID: d.listID, accountID: t.accountID, title: d.title, notes: d.notes,
                                    due: d.hasDue ? d.due.startOfDay : nil, position: t.position, parentID: t.parentID)
                }
                // Subtasks move with their task
                return t.parentID == taskID ? t.moved(to: d.listID) : t
            }
        case .setCompleted(let done, let changed):
            let ids = Set(changed.map(\.id))
            let others = tasks.filter { !ids.contains($0.id) }
            return done ? others : others + changed
        case .deleteTask(let d):
            guard let taskID = d.taskID else { return tasks }
            return tasks.filter { !($0.listID == d.homeListID && ($0.taskID == taskID || $0.parentID == taskID)) }
        default:
            return tasks
        }
    }

    func apply(to lists: [TaskListInfo]) -> [TaskListInfo] {
        guard case .createTaskList(let list) = kind, !lists.contains(list) else { return lists }
        // After the account's other lists, where Google puts a new one
        var result = lists
        let index = lists.lastIndex { $0.accountID == list.accountID }.map { $0 + 1 } ?? lists.endIndex
        result.insert(list, at: index)
        return result
    }

    // MARK: Marking what isn't synced yet

    func concerns(_ event: CalendarEvent) -> Bool {
        guard case .saveEvent(let d, let scope) = kind else { return false }
        if d.isNew { return event.eventID == d.newEventID }
        if scope == .allEvents, let series = d.recurringEventID { return event.recurringEventID == series }
        return event.eventID == d.eventID
    }

    func concerns(_ task: TaskItem) -> Bool {
        switch kind {
        case .createTask(_, let localID): task.taskID == localID
        case .updateTask(let d, let subtaskIDs): task.taskID == d.taskID || subtaskIDs.contains(task.taskID)
        case .setCompleted(false, let tasks): tasks.contains { $0.id == task.id }
        default: false
        }
    }
}

/// Ids of tasks and lists created offline (`local-…`) or moved, and the ids Google gave them.
/// Kept with the queued changes, and for editors still showing an old id.
struct IDMap: Codable, Equatable {
    private var ids: [String: String] = [:]

    var isEmpty: Bool { ids.isEmpty }

    /// The current id for `id`: a task's id, or a list's `TaskListInfo.id` (`<account>/<id>`).
    func callAsFunction(_ id: String) -> String {
        if let current = ids[id] { return current }
        guard let slash = id.firstIndex(of: "/"), let current = ids[String(id[id.index(after: slash)...])] else { return id }
        return String(id[...slash]) + current
    }

    mutating func record(_ newID: String, for oldID: String) {
        ids[oldID] = newID
        // A change of an id given earlier
        for (key, value) in ids where value == oldID { ids[key] = newID }
    }
}

/// Ids for tasks and lists created in machen, until Google gives them their own.
enum LocalID {
    static func make() -> String { "local-" + UUID().uuidString.lowercased() }
    static func isLocal(_ id: String) -> Bool { id.hasPrefix("local-") }
}

extension Error {
    /// The request didn't get to Google and back: no connection, or one that broke off.
    var isConnectivity: Bool {
        if let failure = self as? AccountFailure { return failure.underlying.isConnectivity }
        guard let error = self as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return true
        default:
            return false
        }
    }

    /// Worth trying again later: no connection, Google busy or briefly failing, or an account
    /// that needs to be signed in again first.
    var isTemporary: Bool {
        if isConnectivity || self is AuthError { return true }
        guard let error = self as? APIError else { return false }
        return error.status == 429 || (500...599).contains(error.status)
    }

    /// Google says the item isn't there (any more).
    var isGone: Bool {
        guard let error = self as? APIError else { return false }
        return error.status == 404 || error.status == 410
    }
}

// MARK: - Model helpers for pending changes

extension CalendarEvent {
    /// A new event as it will look once Google has it.
    init(new d: EventDraft, accountID: String, in calendar: CalendarInfo?) {
        let (start, end) = d.eventTimes
        self.init(eventID: d.newEventID, calendarID: d.calendarID, accountID: accountID, title: d.title,
                  start: start, end: end, isAllDay: d.isAllDay, location: d.location, notes: d.notes,
                  color: calendar?.color, canEdit: true, declined: false, link: nil,
                  meetingURL: [d.location, d.notes].lazy.compactMap(MeetingLink.firstLink).first,
                  recurringEventID: nil, reminderMinutes: calendar?.defaultReminderMinutes ?? [])
    }

    /// The event with an edit applied. For an occurrence edited `asSeries`, only what changed
    /// applies: a new time moves it by as much as the edited occurrence moved (see `SeriesShift`).
    func edited(by d: EventDraft, asSeries: Bool, in calendar: CalendarInfo?) -> CalendarEvent {
        let original = d.original
        var start = self.start, end = self.end
        if d.timesChanged {
            let edited = d.eventTimes
            if !asSeries {
                (start, end) = edited
            } else if isAllDay {
                end = start.adding(days: Calendar.current.dateComponents([.day], from: edited.start, to: edited.end).day ?? 1)
            } else if let original {
                start = start.addingTimeInterval(d.start.timeIntervalSince(original.start))
                end = start.addingTimeInterval(edited.end.timeIntervalSince(edited.start))
            }
        }
        let title = original?.title != d.title ? d.title : self.title
        let location = original?.location != d.location ? d.location : self.location
        let notes = original?.notes != d.notes ? d.notes : self.notes
        let moved = calendarID != d.calendarID
        return CalendarEvent(eventID: eventID, calendarID: d.calendarID, accountID: accountID, title: title,
                             start: start, end: end, isAllDay: d.isAllDay, location: location, notes: notes,
                             color: moved ? calendar?.color ?? color : color, canEdit: canEdit, declined: declined,
                             link: link,
                             meetingURL: meetingURL ?? [location, notes].lazy.compactMap(MeetingLink.firstLink).first,
                             recurringEventID: recurringEventID, reminderMinutes: reminderMinutes)
    }
}

extension EventDraft {
    /// Start and exclusive end as Google stores them: an all-day event ends at midnight after its last day.
    var eventTimes: (start: Date, end: Date) {
        isAllDay ? (start.startOfDay, end.startOfDay.adding(days: 1)) : (start, max(end, start))
    }
}

extension TaskDraft {
    func resolved(_ ids: IDMap) -> TaskDraft {
        var d = self
        d.taskID = taskID.map { ids($0) }
        d.listID = ids(listID)
        d.originalListID = originalListID.map { ids($0) }
        d.parentID = parentID.map { ids($0) }
        return d
    }
}

extension TaskItem {
    func resolved(_ ids: IDMap) -> TaskItem {
        TaskItem(taskID: ids(taskID), listID: ids(listID), accountID: accountID, title: title, notes: notes, due: due,
                 position: position, parentID: parentID.map { ids($0) }, isSubtask: isSubtask)
    }

    func moved(to listID: String) -> TaskItem {
        TaskItem(taskID: taskID, listID: listID, accountID: accountID, title: title, notes: notes, due: due,
                 position: position, parentID: parentID, isSubtask: isSubtask)
    }
}

extension TaskListInfo {
    func resolved(_ ids: IDMap) -> TaskListInfo {
        TaskListInfo(accountID: accountID, remoteID: ids(remoteID), title: title)
    }
}

/// A queued change Google didn't accept, reported once no editor shows it any more.
struct ChangeRefused: LocalizedError {
    let subject: String
    let underlying: Error

    var errorDescription: String? { "“\(subject)” couldn't be saved to Google: \(underlying.localizedDescription)" }
}
