import Foundation

// MARK: - Google Calendar wire types

struct CalendarListResponse: Decodable {
    let items: [CalendarInfo]?
    let nextPageToken: String?
}

struct CalendarInfo: Decodable, Identifiable, Hashable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let backgroundColor: String?
    let accessRole: String
    let selected: Bool?
    let primary: Bool?

    var name: String { summaryOverride ?? summary ?? id }
    var canEdit: Bool { accessRole == "owner" || accessRole == "writer" }
}

struct EventsResponse: Decodable {
    let items: [GEvent]?
    let nextPageToken: String?
}

struct GEvent: Decodable {
    struct Time: Decodable {
        let date: String?
        let dateTime: String?
    }

    struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?

        enum CodingKeys: String, CodingKey {
            case isSelf = "self"
            case responseStatus
        }
    }

    let id: String
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let start: Time?
    let end: Time?
    let htmlLink: String?
    let attendees: [Attendee]?
    /// Set when the event has its own color instead of its calendar's.
    let colorId: String?
}

/// Google Calendar's event colors by `colorId`, as the web and mobile apps show them.
/// The API's /colors endpoint still returns the older pastel palette, so it isn't used.
enum EventColors {
    static let hex: [String: String] = [
        "1": "#7986CB", // Lavender
        "2": "#33B679", // Sage
        "3": "#8E24AA", // Grape
        "4": "#E67C73", // Flamingo
        "5": "#F6BF26", // Banana
        "6": "#F4511E", // Tangerine
        "7": "#039BE5", // Peacock
        "8": "#616161", // Graphite
        "9": "#3F51B5", // Blueberry
        "10": "#0B8043", // Basil
        "11": "#D50000", // Tomato
    ]
}

// MARK: - Google Tasks wire types

struct TaskListsResponse: Decodable {
    let items: [TaskListInfo]?
    let nextPageToken: String?
}

struct TaskListInfo: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
}

struct TasksResponse: Decodable {
    let items: [GTask]?
    let nextPageToken: String?
}

struct GTask: Decodable {
    let id: String
    let title: String?
    let notes: String?
    let due: String?
    let status: String?
    let parent: String?
    let position: String?
    let deleted: Bool?
}

// MARK: - App models

struct CalendarEvent: Identifiable, Hashable {
    let eventID: String
    let calendarID: String
    let title: String
    let start: Date
    /// Exclusive end; for all-day events this is midnight of the day after the last day.
    let end: Date
    let isAllDay: Bool
    let location: String
    let notes: String
    let color: String?
    let canEdit: Bool
    let declined: Bool
    let link: URL?

    var id: String { calendarID + "/" + eventID }

    /// All-day events longer than one day, or timed events lasting 24 hours or more.
    /// (An overnight timed event, say 22:00–06:00, doesn't count.)
    var isMultiDay: Bool {
        isAllDay ? end > start.adding(days: 1) : end.timeIntervalSince(start) >= 24 * 3600
    }

    init?(_ e: GEvent, calendar: CalendarInfo) {
        guard e.status != "cancelled", let s = e.start, let en = e.end else { return nil }
        if let d = s.date, let day = GDate.parseDay(d) {
            isAllDay = true
            start = day
            end = en.date.flatMap(GDate.parseDay) ?? day.adding(days: 1)
        } else if let dt = s.dateTime, let time = GDate.parseDateTime(dt) {
            isAllDay = false
            start = time
            end = en.dateTime.flatMap(GDate.parseDateTime) ?? time
        } else {
            return nil
        }
        eventID = e.id
        calendarID = calendar.id
        title = e.summary?.isEmpty == false ? e.summary! : "(No title)"
        location = e.location ?? ""
        notes = e.description ?? ""
        color = e.colorId.flatMap { EventColors.hex[$0] } ?? calendar.backgroundColor
        canEdit = calendar.canEdit
        declined = e.attendees?.first(where: { $0.isSelf == true })?.responseStatus == "declined"
        link = e.htmlLink.flatMap(URL.init(string:))
    }

    static func order(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.start != b.start { return a.start < b.start }
        return a.title.localizedCompare(b.title) == .orderedAscending
    }
}

struct TaskItem: Identifiable, Hashable {
    let taskID: String
    let listID: String
    let title: String
    let notes: String
    let due: Date?
    let position: String
    let parentID: String?
    /// Set by `arranged` when the task is shown indented below its parent.
    var isSubtask = false

    var id: String { listID + "/" + taskID }
    private var parentKey: String? { parentID.map { listID + "/" + $0 } }

    init(_ t: GTask, list: TaskListInfo) {
        taskID = t.id
        listID = list.id
        title = t.title ?? ""
        notes = t.notes ?? ""
        due = t.due.flatMap(GDate.parseDay)
        position = t.position ?? ""
        parentID = t.parent
    }

    /// Top-level tasks in `order`, each followed by its subtasks in Google's own order.
    /// A subtask whose parent isn't among `items` is treated as top-level.
    static func arranged(_ items: [TaskItem]) -> [TaskItem] {
        let ids = Set(items.map(\.id))
        let hasParent = { (t: TaskItem) in t.parentKey.map(ids.contains) ?? false }
        let children = Dictionary(grouping: items.filter(hasParent)) { $0.parentKey! }
        return items.filter { !hasParent($0) }.sorted(by: order).flatMap { root in
            [root] + (children[root.id] ?? []).sorted { $0.position < $1.position }.map { child in
                var c = child
                c.isSubtask = true
                return c
            }
        }
    }

    /// Keeps only dated tasks from an `arranged` list. A parent without a date stays when one
    /// of its subtasks has one, so the subtask keeps its context.
    static func withDueDates(_ arranged: [TaskItem]) -> [TaskItem] {
        var result: [TaskItem] = []
        var block: [TaskItem] = []
        func flush() {
            guard let root = block.first else { return }
            let datedSubtasks = block.dropFirst().filter { $0.due != nil }
            if root.due != nil || !datedSubtasks.isEmpty {
                result.append(root)
                result += datedSubtasks
            }
            block = []
        }
        for task in arranged {
            if !task.isSubtask { flush() }
            block.append(task)
        }
        flush()
        return result
    }

    /// By due date ascending, undated tasks last, then Google's own order.
    static func order(_ a: TaskItem, _ b: TaskItem) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.position < b.position
        }
    }
}

// MARK: - Editable drafts

struct EventDraft: Equatable {
    var eventID: String?
    var calendarID: String
    var title = ""
    var isAllDay = false
    var start: Date
    /// Exact end for timed events; the last day (inclusive) for all-day events.
    var end: Date
    var location = ""
    var notes = ""

    var isNew: Bool { eventID == nil }

    init(calendarID: String, day: Date) {
        self.calendarID = calendarID
        let now = Date()
        if Calendar.current.isDate(day, inSameDayAs: now) {
            let nextHour = Calendar.current.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
            start = nextHour
        } else {
            start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        }
        end = start.addingTimeInterval(3600)
    }

    init(_ e: CalendarEvent) {
        eventID = e.eventID
        calendarID = e.calendarID
        title = e.title == "(No title)" ? "" : e.title
        isAllDay = e.isAllDay
        start = e.start
        end = e.isAllDay ? max(e.start, e.end.adding(days: -1)) : e.end
        location = e.location
        notes = e.notes
    }
}

struct TaskDraft: Equatable {
    var taskID: String?
    var listID: String
    /// Set for subtasks; Google Tasks allows only one level of nesting.
    var parentID: String?
    var title = ""
    var notes = ""
    var hasDue = false
    var due: Date

    var isNew: Bool { taskID == nil }
    var isSubtask: Bool { parentID != nil }
    /// Distinguishes editors so SwiftUI doesn't reuse one draft's state for another.
    var editorID: String { taskID ?? "new/\(listID)/\(parentID ?? "")" }

    init(listID: String, day: Date) {
        self.listID = listID
        due = day
    }

    init(subtaskOf parentID: String, listID: String) {
        self.listID = listID
        self.parentID = parentID
        due = Date().startOfDay
    }

    init(_ t: TaskItem) {
        taskID = t.taskID
        listID = t.listID
        parentID = t.parentID
        title = t.title
        notes = t.notes
        hasDue = t.due != nil
        due = t.due ?? Date().startOfDay
    }
}
