import Foundation

// MARK: - Google Calendar wire types

struct CalendarListResponse: Decodable {
    let items: [CalendarInfo]?
    let nextPageToken: String?
}

/// A Google Calendar reminder: "popup" ones become desktop notifications, "email" ones are Google's.
struct ReminderSetting: Codable, Hashable {
    let method: String?
    let minutes: Int?
}

struct CalendarInfo: Codable, Identifiable, Hashable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let backgroundColor: String?
    let accessRole: String
    let selected: Bool?
    let primary: Bool?
    /// Reminders for events that use the calendar's defaults.
    var defaultReminders: [ReminderSetting]? = nil

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
        /// The time zone a timed event (or a series) was set in, for example "America/New_York".
        let timeZone: String?
    }

    struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?

        enum CodingKeys: String, CodingKey {
            case isSelf = "self"
            case responseStatus
        }
    }

    struct Reminders: Decodable {
        let useDefault: Bool?
        let overrides: [ReminderSetting]?
    }

    struct ConferenceData: Decodable {
        struct EntryPoint: Decodable {
            let entryPointType: String?
            let uri: String?
        }
        let entryPoints: [EntryPoint]?
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
    /// Set on each occurrence of a recurring event: the id of the series.
    let recurringEventId: String?
    let hangoutLink: String?
    let conferenceData: ConferenceData?
    let reminders: Reminders?
}

/// Finds the video call link of an event.
enum MeetingLink {
    /// Hosts of video call services whose links count as meeting links in a location or description.
    static let hosts = ["meet.google.com", "zoom.us", "zoom.com", "teams.microsoft.com", "teams.live.com",
                        "webex.com", "whereby.com", "gotomeeting.com", "meet.jit.si", "facetime.apple.com"]

    /// The conference link Google attached (Meet, or an add-on like Zoom), else the first
    /// meeting link in the event's location or description.
    static func find(in e: GEvent) -> URL? {
        if let uri = e.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri,
           let url = URL(string: uri) {
            return url
        }
        if let link = e.hangoutLink, let url = URL(string: link) { return url }
        return [e.location, e.description].compactMap { $0 }.lazy.compactMap(firstLink).first
    }

    /// One detector for all events; creating one per text is comparatively slow.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func firstLink(in text: String) -> URL? {
        guard let detector else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.lazy.compactMap(\.url).first { url in
            guard let host = url.host?.lowercased(), url.scheme == "https" || url.scheme == "http" else { return false }
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
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

struct TaskListInfo: Codable, Identifiable, Hashable {
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

struct CalendarEvent: Identifiable, Hashable, Codable {
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
    /// Video call link, if any.
    let meetingURL: URL?
    /// For an occurrence of a recurring event: the id of the series.
    let recurringEventID: String?
    /// Minutes before the start at which to show a notification (the event's popup reminders).
    let reminderMinutes: [Int]

    var id: String { calendarID + "/" + eventID }
    /// The title as shown; an untitled event reads "(No title)", as in Google Calendar.
    var displayTitle: String { title.isEmpty ? "(No title)" : title }

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
        title = e.summary ?? ""
        location = e.location ?? ""
        notes = e.description ?? ""
        color = e.colorId.flatMap { EventColors.hex[$0] } ?? calendar.backgroundColor
        canEdit = calendar.canEdit
        declined = e.attendees?.first(where: { $0.isSelf == true })?.responseStatus == "declined"
        link = e.htmlLink.flatMap(URL.init(string:))
        meetingURL = MeetingLink.find(in: e)
        recurringEventID = e.recurringEventId
        reminderMinutes = Self.popupMinutes(e, calendar: calendar)
    }

    /// The event's own popup reminders, or its calendar's defaults when it uses those.
    static func popupMinutes(_ e: GEvent, calendar: CalendarInfo) -> [Int] {
        let settings = (e.reminders?.useDefault ?? true) ? (calendar.defaultReminders ?? []) : (e.reminders?.overrides ?? [])
        return Array(Set(settings.filter { $0.method == "popup" }.compactMap(\.minutes))).sorted()
    }

    /// All-day events first, then by start time. Ties follow the calendar order from Settings
    /// (`calendarRank`: calendar id → position), then the title.
    static func order(calendarRank: [String: Int]) -> (CalendarEvent, CalendarEvent) -> Bool {
        { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if a.start != b.start { return a.start < b.start }
            let ra = calendarRank[a.calendarID] ?? .max, rb = calendarRank[b.calendarID] ?? .max
            if ra != rb { return ra < rb }
            return a.title.localizedCompare(b.title) == .orderedAscending
        }
    }
}

/// The order of calendars and task lists that the user drags into place in Settings.
enum CustomOrder {
    /// `items` sorted by their position in `order`; items missing from it keep their original
    /// order and come after the others (for example a newly added calendar).
    static func apply<T>(_ order: [String], to items: [T], id: (T) -> String) -> [T] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? .max, rb = rank[id(b.element)] ?? .max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// `ids` with `dragged` moved into `target`'s place: before it when moving up, after it when
    /// moving down. Nil when either id is missing or they're the same.
    static func move(_ dragged: String, onto target: String, in ids: [String]) -> [String]? {
        guard dragged != target, let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: target) else {
            return nil
        }
        var result = ids
        result.remove(at: from)
        result.insert(dragged, at: to)
        return result
    }
}

struct TaskItem: Identifiable, Hashable, Codable {
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
    /// The editable values, as they were when an existing event was opened.
    struct Values: Equatable {
        var title: String
        var isAllDay: Bool
        var start: Date
        var end: Date
        var location: String
        var notes: String
    }

    var eventID: String?
    var calendarID: String
    /// Where an existing event lives now; differs from `calendarID` when it's being moved.
    var originalCalendarID: String?
    /// For an occurrence of a recurring event: the id of its series.
    var recurringEventID: String?
    /// An existing event's values before editing, so only what changed is sent to Google.
    var original: Values?
    /// Video call link of an existing event (not editable here).
    var meetingURL: URL?
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

    var isRecurring: Bool { recurringEventID != nil }
    var isMoving: Bool { originalCalendarID.map { $0 != calendarID } ?? false }
    var values: Values { Values(title: title, isAllDay: isAllDay, start: start, end: end, location: location, notes: notes) }
    /// Whether the date, time, length or all-day setting changed (always true for a new event).
    var timesChanged: Bool {
        guard let original else { return true }
        return original.isAllDay != isAllDay || original.start != start || original.end != end
    }

    init(_ e: CalendarEvent) {
        eventID = e.eventID
        calendarID = e.calendarID
        originalCalendarID = e.calendarID
        recurringEventID = e.recurringEventID
        meetingURL = e.meetingURL
        title = e.title
        isAllDay = e.isAllDay
        start = e.start
        end = e.isAllDay ? max(e.start, e.end.adding(days: -1)) : e.end
        location = e.location
        notes = e.notes
        original = values
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

/// Which events an edit to an occurrence of a recurring event applies to.
enum EditScope: String, CaseIterable, Identifiable {
    case thisEvent, allEvents

    var id: String { rawValue }
    var label: String {
        switch self {
        case .thisEvent: "This event"
        case .allEvents: "All events"
        }
    }
}

/// Applying an edit of one occurrence to its whole recurring series. Only the time of day and
/// the length can change: moving the series' first event to another day would leave its repeat
/// rule (for example "every Monday") pointing at the old weekday.
enum SeriesShift {
    enum Refusal: LocalizedError {
        case otherDay, allDayChange

        var errorDescription: String? {
            switch self {
            case .otherDay:
                "A whole repeating series can't be moved to other days from machen, because its repeat rule would keep the old day. Change only the time, choose This event, or edit the series in Google Calendar."
            case .allDayChange:
                "A whole repeating series can't be switched between all-day and timed from machen. Choose This event, or edit the series in Google Calendar."
            }
        }
    }

    /// Checks that an edit of an occurrence can be applied to its whole series.
    static func check(original: EventDraft.Values, edited: EventDraft.Values) throws {
        if original.isAllDay != edited.isAllDay { throw Refusal.allDayChange }
        if !Calendar.current.isDate(original.start, inSameDayAs: edited.start) { throw Refusal.otherDay }
    }

    /// New start and end of a timed series: its first event moves by as much as the occurrence
    /// did, and takes the occurrence's new length. Working with the time difference (rather than
    /// a local time of day) keeps the series in its own time zone.
    static func timed(seriesStart: Date, occurrenceStart: Date, editedStart: Date, editedEnd: Date) -> (start: Date, end: Date) {
        let start = seriesStart.addingTimeInterval(editedStart.timeIntervalSince(occurrenceStart))
        return (start, start.addingTimeInterval(max(editedEnd.timeIntervalSince(editedStart), 0)))
    }

    /// New first and last day (inclusive) of an all-day series: same start day, new length in days.
    static func allDay(seriesStart: Date, editedStart: Date, editedEnd: Date) -> (start: Date, end: Date) {
        let days = Calendar.current.dateComponents([.day], from: editedStart.startOfDay, to: editedEnd.startOfDay).day ?? 0
        return (seriesStart.startOfDay, seriesStart.startOfDay.adding(days: max(days, 0)))
    }
}
