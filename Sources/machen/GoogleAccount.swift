import Foundation

// MARK: - Google Calendar wire types

struct CalendarListResponse: Decodable {
    let items: [GCalendar]?
    let nextPageToken: String?
}

/// A Google Calendar reminder: "popup" ones become desktop notifications, "email" ones are Google's.
struct ReminderSetting: Decodable {
    let method: String?
    let minutes: Int?
}

struct GCalendar: Decodable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let backgroundColor: String?
    let accessRole: String
    let selected: Bool?
    let primary: Bool?
    /// Reminders for events that use the calendar's defaults.
    let defaultReminders: [ReminderSetting]?
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
    let items: [GTaskList]?
    let nextPageToken: String?
}

struct GTaskList: Decodable {
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

// MARK: - Account

struct TokenSet: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

/// A connected Google account: its sign-in, and its calendars and task lists through the Google
/// Calendar and Google Tasks APIs.
@MainActor
final class GoogleAccount: Account {
    let id: String
    /// The account's address, which is also the id of its primary calendar. Empty for the account
    /// carried over from machen 1.x until it has synced once.
    private(set) var email: String {
        didSet { if email != oldValue { onChange?(self) } }
    }
    /// Nil once Google no longer accepts the sign-in (it expired, or access was revoked).
    var tokens: TokenSet? {
        didSet { onChange?(self) }
    }
    /// Called when the address or the tokens change, so they're saved.
    var onChange: ((GoogleAccount) -> Void)?

    private let auth: GoogleAuth
    private var refreshTask: Task<TokenSet, Error>?
    private lazy var api = GoogleAPI { [weak self] forceRefresh in
        guard let self else { throw AuthError.notSignedIn }
        return try await self.accessToken(forceRefresh: forceRefresh)
    }

    /// The event fields machen uses. Asking for just these keeps responses small (no guest lists).
    private static let eventFields = "items(id,status,summary,description,location,start,end,attendees(self,responseStatus),"
        + "reminders,hangoutLink,conferenceData(entryPoints(entryPointType,uri)),recurringEventId,colorId,htmlLink),nextPageToken"

    init(id: String, email: String, tokens: TokenSet?, auth: GoogleAuth) {
        self.id = id
        self.email = email
        self.tokens = tokens
        self.auth = auth
    }

    var name: String { email.isEmpty ? "Google account" : email }
    var isActive: Bool { tokens != nil }

    /// The address of the account `tokens` belong to: the id of its primary calendar, from the
    /// calendar list (which machen may read, unlike the calendars themselves).
    static func email(for tokens: TokenSet) async throws -> String {
        struct Primary: Decodable { let id: String }
        let api = GoogleAPI { _ in tokens.accessToken }
        let primary: Primary = try await api.get(Endpoint.calendar("users", "me", "calendarList", "primary",
                                                                   query: ["fields": "id"]))
        return primary.id
    }

    /// A valid access token, refreshed when it's about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        #if SCREENSHOTS
        throw AuthError.notSignedIn
        #else
        guard let current = tokens else { throw AuthError.sessionExpired }
        if !forceRefresh, current.expiry > Date().addingTimeInterval(60) {
            return current.accessToken
        }
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        let task = Task { try await auth.refreshed(current) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let new = try await task.value
            // Removed meanwhile, or signed in again: don't bring the old sign-in back
            guard let latest = tokens else { throw AuthError.notSignedIn }
            guard latest.refreshToken == current.refreshToken else { return latest.accessToken }
            tokens = new
            return new.accessToken
        } catch AuthError.server(let code, _) where code == "invalid_grant" {
            if tokens?.refreshToken == current.refreshToken { tokens = nil }
            throw AuthError.sessionExpired
        }
        #endif
    }

    // MARK: Fetching

    /// Primary first, then by name.
    func fetchCalendars() async throws -> [CalendarInfo] {
        var result: [GCalendar] = []
        var token: String?
        repeat {
            let page: CalendarListResponse = try await api.get(Endpoint.calendar(
                "users", "me", "calendarList", query: ["maxResults": "250", "pageToken": token]))
            result += page.items ?? []
            token = page.nextPageToken
        } while token != nil
        if let primary = result.first(where: { $0.primary == true }) { email = primary.id }
        return result.map(calendar).sorted { ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name) }
    }

    private func calendar(_ c: GCalendar) -> CalendarInfo {
        CalendarInfo(accountID: id, remoteID: c.id, name: c.summaryOverride ?? c.summary ?? c.id,
                     color: c.backgroundColor, canEdit: c.accessRole == "owner" || c.accessRole == "writer",
                     isPrimary: c.primary == true, shownByDefault: c.selected == true,
                     defaultReminderMinutes: Self.popupMinutes(c.defaultReminders))
    }

    func fetchEvents(in calendars: [CalendarInfo], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
            for cal in calendars {
                group.addTask { try await self.fetchEvents(in: cal, from: start, to: end) }
            }
            var all: [CalendarEvent] = []
            for try await items in group { all += items }
            return all
        }
    }

    private func fetchEvents(in cal: CalendarInfo, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        var result: [CalendarEvent] = []
        var token: String?
        repeat {
            let page: EventsResponse = try await api.get(Endpoint.calendar(
                "calendars", cal.remoteID, "events",
                query: [
                    "timeMin": GDate.dateTimeString(start),
                    "timeMax": GDate.dateTimeString(end),
                    "singleEvents": "true",
                    "orderBy": "startTime",
                    "maxResults": "250",
                    "pageToken": token,
                    "fields": Self.eventFields,
                ]))
            result += (page.items ?? []).compactMap { event($0, in: cal) }
            token = page.nextPageToken
        } while token != nil
        return result
    }

    /// The event as machen shows it; nil when it's cancelled or has no usable times.
    private func event(_ e: GEvent, in calendar: CalendarInfo) -> CalendarEvent? {
        guard e.status != "cancelled", let s = e.start, let en = e.end else { return nil }
        let start: Date, end: Date, isAllDay: Bool
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
        let usesDefaults = e.reminders?.useDefault ?? true
        return CalendarEvent(
            eventID: e.id, calendarID: calendar.id, accountID: id, title: e.summary ?? "",
            start: start, end: end, isAllDay: isAllDay, location: e.location ?? "", notes: e.description ?? "",
            color: e.colorId.flatMap { EventColors.hex[$0] } ?? calendar.color, canEdit: calendar.canEdit,
            declined: e.attendees?.first(where: { $0.isSelf == true })?.responseStatus == "declined",
            link: link(e.htmlLink), meetingURL: Self.meetingLink(e), recurringEventID: e.recurringEventId,
            reminderMinutes: usesDefaults ? calendar.defaultReminderMinutes : Self.popupMinutes(e.reminders?.overrides))
    }

    /// The event in Google Calendar, opened as this account: the browser may be signed in to several.
    private func link(_ htmlLink: String?) -> URL? {
        guard let htmlLink, var c = URLComponents(string: htmlLink) else { return nil }
        if !email.isEmpty { c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "authuser", value: email)] }
        return c.url
    }

    /// The conference link Google attached (Meet, or an add-on like Zoom), else the first
    /// meeting link in the event's location or description.
    private static func meetingLink(_ e: GEvent) -> URL? {
        if let uri = e.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri,
           let url = URL(string: uri) {
            return url
        }
        if let link = e.hangoutLink, let url = URL(string: link) { return url }
        return [e.location, e.description].compactMap { $0 }.lazy.compactMap(MeetingLink.firstLink).first
    }

    /// The minutes of the popup reminders among `reminders`, each once.
    private static func popupMinutes(_ reminders: [ReminderSetting]?) -> [Int] {
        Array(Set((reminders ?? []).filter { $0.method == "popup" }.compactMap(\.minutes))).sorted()
    }

    func fetchTaskLists() async throws -> [TaskListInfo] {
        var result: [TaskListInfo] = []
        var token: String?
        repeat {
            let page: TaskListsResponse = try await api.get(Endpoint.tasks(
                "users", "@me", "lists", query: ["maxResults": "100", "pageToken": token]))
            result += (page.items ?? []).map { TaskListInfo(accountID: id, remoteID: $0.id, title: $0.title) }
            token = page.nextPageToken
        } while token != nil
        return result
    }

    func fetchTasks(in lists: [TaskListInfo]) async throws -> [TaskItem] {
        try await withThrowingTaskGroup(of: [TaskItem].self) { group in
            for list in lists {
                group.addTask { try await self.fetchTasks(in: list) }
            }
            var all: [TaskItem] = []
            for try await items in group { all += items }
            return all
        }
    }

    private func fetchTasks(in list: TaskListInfo) async throws -> [TaskItem] {
        var result: [TaskItem] = []
        var token: String?
        repeat {
            let page: TasksResponse = try await api.get(Endpoint.tasks(
                "lists", list.remoteID, "tasks",
                query: ["showCompleted": "false", "showHidden": "false", "maxResults": "100", "pageToken": token]))
            result += (page.items ?? [])
                .filter { $0.status != "completed" && $0.deleted != true }
                .map { t in
                    TaskItem(taskID: t.id, listID: list.id, accountID: id, title: t.title ?? "", notes: t.notes ?? "",
                             due: t.due.flatMap(GDate.parseDay), position: t.position ?? "", parentID: t.parent)
                }
            token = page.nextPageToken
        } while token != nil
        return result
    }

    // MARK: Event edits

    /// Sends only what changed. For an occurrence of a repeating event, `.allEvents` edits the
    /// series instead (see `SeriesShift`). Google moves only whole series to another calendar,
    /// so the editor offers a move of an occurrence for `.allEvents` only.
    func save(_ d: EventDraft, in calendar: CalendarInfo, home: CalendarInfo, scope: EditScope) async throws {
        let editsSeries = scope == .allEvents && d.recurringEventID != nil && !d.isNew
        var body: [String: Any] = [:]
        if d.original?.title != d.title { body["summary"] = d.title }
        if d.original?.location != d.location { body["location"] = d.location }
        if d.original?.notes != d.notes { body["description"] = d.notes }
        if d.timesChanged {
            var start = d.start, end = max(d.end, d.start), timeZone = TimeZone.current.identifier
            if editsSeries, let original = d.original, let seriesID = d.recurringEventID {
                try SeriesShift.check(original: original, edited: d.values)
                let series: GEvent = try await api.get(Endpoint.calendar("calendars", home.remoteID, "events", seriesID))
                if d.isAllDay, let first = series.start?.date.flatMap(GDate.parseDay) {
                    (start, end) = SeriesShift.allDay(seriesStart: first, editedStart: d.start, editedEnd: end)
                } else if let first = series.start?.dateTime.flatMap(GDate.parseDateTime) {
                    (start, end) = SeriesShift.timed(seriesStart: first, occurrenceStart: original.start,
                                                     editedStart: d.start, editedEnd: end)
                    timeZone = series.start?.timeZone ?? timeZone
                }
            }
            let patch = !d.isNew
            if d.isAllDay {
                body["start"] = allDayTime(start.startOfDay, patch: patch)
                body["end"] = allDayTime(end.startOfDay.adding(days: 1), patch: patch)
            } else {
                body["start"] = timedTime(start, timeZone: timeZone, patch: patch)
                body["end"] = timedTime(end, timeZone: timeZone, patch: patch)
            }
        }
        if let eventID = editsSeries ? d.recurringEventID : d.eventID {
            if !body.isEmpty {
                try await api.send("PATCH", Endpoint.calendar("calendars", home.remoteID, "events", eventID), body: body)
            }
            if calendar.remoteID != home.remoteID {
                try await api.send("POST", Endpoint.calendar("calendars", home.remoteID, "events", eventID, "move",
                                                             query: ["destination": calendar.remoteID]))
            }
        } else {
            try await api.send("POST", Endpoint.calendar("calendars", calendar.remoteID, "events"), body: body)
        }
    }

    func deleteEvent(_ d: EventDraft, in calendar: CalendarInfo, scope: EditScope) async throws {
        guard let eventID = d.eventID else { return }
        let target = scope == .allEvents ? d.recurringEventID ?? eventID : eventID
        try await api.send("DELETE", Endpoint.calendar("calendars", calendar.remoteID, "events", target))
    }

    // Switching an existing event between timed and all-day requires nulling the other field.
    private func allDayTime(_ d: Date, patch: Bool) -> [String: Any] {
        var t: [String: Any] = ["date": GDate.dayString(d)]
        if patch { t["dateTime"] = NSNull() }
        return t
    }

    private func timedTime(_ d: Date, timeZone: String, patch: Bool) -> [String: Any] {
        var t: [String: Any] = ["dateTime": GDate.dateTimeString(d), "timeZone": timeZone]
        if patch { t["date"] = NSNull() }
        return t
    }

    // MARK: Task edits

    func save(_ d: TaskDraft, in list: TaskListInfo) async throws {
        var body: [String: Any] = ["title": d.title, "notes": d.notes]
        if d.hasDue {
            body["due"] = GDate.taskDueString(d.due)
        } else if !d.isNew {
            body["due"] = NSNull()
        }
        if let id = d.taskID {
            try await api.send("PATCH", Endpoint.tasks("lists", list.remoteID, "tasks", id), body: body)
        } else {
            try await api.send("POST", Endpoint.tasks("lists", list.remoteID, "tasks", query: ["parent": d.parentID]),
                               body: body)
        }
    }

    func setCompleted(_ completed: Bool, taskIDs: [String], in list: TaskListInfo) async throws {
        let body: [String: Any] = completed ? ["status": "completed"] : ["status": "needsAction", "completed": NSNull()]
        for id in taskIDs {
            try await api.send("PATCH", Endpoint.tasks("lists", list.remoteID, "tasks", id), body: body)
        }
    }

    func deleteTask(_ taskID: String, in list: TaskListInfo) async throws {
        try await api.send("DELETE", Endpoint.tasks("lists", list.remoteID, "tasks", taskID))
    }
}
