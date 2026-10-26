import SwiftUI

struct EventDay: Identifiable {
    let day: Date
    let events: [CalendarEvent]

    var id: Date { day }

    /// Whether a multi-day event begins on this day (shown with a "Starts" label).
    func isStartDay(of event: CalendarEvent) -> Bool {
        event.isMultiDay && event.start.startOfDay == day
    }

    /// Each of `days` days from `first`, with the events that overlap it. Multi-day events
    /// follow `mode`: on every day they cover; once, under the first shown day they cover
    /// (today for one already running, otherwise its start day); or not at all.
    static func group(_ events: [CalendarEvent], from first: Date, days: Int, multiDay mode: MultiDayMode) -> [EventDay] {
        (0..<days).map { offset in
            let start = first.adding(days: offset), end = start.adding(days: 1)
            return EventDay(day: start, events: events.filter { e in
                guard e.start < end, e.end > start else { return false }
                guard e.isMultiDay else { return true }
                switch mode {
                case .everyDay: return true
                case .todayAndStart: return start == max(e.start.startOfDay, first)
                case .exclude: return false
                }
            })
        }
    }
}

struct TaskGroup: Identifiable {
    let list: TaskListInfo
    let color: Color
    let tasks: [TaskItem]

    var id: String { list.id }
}

/// Holds the synced calendar and task data and performs edits against Google.
@MainActor
final class Store: ObservableObject {
    /// Today; events cover `eventDays` days from here. Rolls over at midnight.
    @Published private(set) var day = Date().startOfDay
    static let eventDayRange = 1...14
    @Published var eventDays: Int {
        didSet {
            UserDefaults.standard.set(eventDays, forKey: "eventDays")
            events = []
            Task { await refreshEvents() }
        }
    }
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var taskLists: [TaskListInfo] = []
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastSync: Date?
    @Published var errorMessage: String?

    /// Per-calendar / per-list visibility chosen in Settings; keys are "cal:<id>" and "list:<id>".
    @Published private var visibility: [String: Bool] {
        didSet { UserDefaults.standard.set(visibility, forKey: "visibility") }
    }

    @Published var multiDayMode: MultiDayMode {
        didSet { UserDefaults.standard.set(multiDayMode.rawValue, forKey: "multiDayMode") }
    }

    @Published var taskFilter: TaskFilter {
        didSet { UserDefaults.standard.set(taskFilter.rawValue, forKey: "taskFilter") }
    }

    @Published var menuBarIcon: String {
        didSet { UserDefaults.standard.set(menuBarIcon, forKey: "menuBarIcon") }
    }

    @Published var density: RowDensity {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "density") }
    }

    /// Task list id → palette hex chosen in Settings.
    @Published private var listColors: [String: String] {
        didSet { UserDefaults.standard.set(listColors, forKey: "listColors") }
    }

    let auth: GoogleAuth
    private let api: GoogleAPI
    private var timer: Timer?
    private var loadCount = 0 {
        didSet { isLoading = loadCount > 0 }
    }

    init(auth: GoogleAuth) {
        self.auth = auth
        api = GoogleAPI(auth: auth)
        visibility = UserDefaults.standard.dictionary(forKey: "visibility") as? [String: Bool] ?? [:]
        listColors = UserDefaults.standard.dictionary(forKey: "listColors") as? [String: String] ?? [:]
        density = UserDefaults.standard.string(forKey: "density").flatMap(RowDensity.init) ?? .standard
        taskFilter = UserDefaults.standard.string(forKey: "taskFilter").flatMap(TaskFilter.init) ?? .all
        menuBarIcon = UserDefaults.standard.string(forKey: "menuBarIcon") ?? "calendar"
        multiDayMode = UserDefaults.standard.string(forKey: "multiDayMode").flatMap(MultiDayMode.init) ?? .everyDay
        let savedDays = UserDefaults.standard.integer(forKey: "eventDays")
        eventDays = Self.eventDayRange.contains(savedDays) ? savedDays : 1
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        // Load right away so the first click shows data instead of a spinner.
        Task { await refresh() }
    }

    // MARK: Derived state


    var eventsByDay: [EventDay] {
        EventDay.group(events, from: day, days: eventDays, multiDay: multiDayMode)
    }

    /// Number of distinct events shown, counting a repeated multi-day event once.
    var shownEventCount: Int {
        Set(eventsByDay.flatMap { $0.events.map(\.id) }).count
    }
    var writableCalendars: [CalendarInfo] { calendars.filter(\.canEdit) }
    var defaultCalendarID: String? {
        writableCalendars.first(where: { $0.primary == true })?.id ?? writableCalendars.first?.id
    }
    var showsListNames: Bool { taskLists.filter(isShown).count > 1 }

    /// Tasks grouped by list, in the order Google returns the lists; empty lists are left out.
    var taskGroups: [TaskGroup] {
        taskLists.compactMap { list in
            let inList = tasks.filter { $0.listID == list.id }
            let items = taskFilter == .dueOnly ? TaskItem.withDueDates(inList) : inList
            return items.isEmpty ? nil : TaskGroup(list: list, color: color(for: list), tasks: items)
        }
    }

    var shownTaskCount: Int { taskGroups.reduce(0) { $0 + $1.tasks.count } }

    func colorHex(for list: TaskListInfo) -> String {
        if let hex = listColors[list.id] { return hex }
        let index = taskLists.firstIndex(of: list) ?? 0
        return ListPalette.colors[index % ListPalette.colors.count].hex
    }

    func color(for list: TaskListInfo) -> Color {
        Color(hex: colorHex(for: list)) ?? .accentColor
    }

    func setColor(_ hex: String, for list: TaskListInfo) {
        listColors[list.id] = hex
    }

    func isShown(_ c: CalendarInfo) -> Bool { visibility["cal:" + c.id] ?? (c.selected == true) }
    func isShown(_ l: TaskListInfo) -> Bool { visibility["list:" + l.id] ?? true }

    func setShown(_ c: CalendarInfo, _ shown: Bool) {
        visibility["cal:" + c.id] = shown
        Task { await refreshEvents() }
    }

    func setShown(_ l: TaskListInfo, _ shown: Bool) {
        visibility["list:" + l.id] = shown
        Task { await refreshTasks() }
    }

    func newEventDraft() -> EventDraft? {
        newEventDraft(on: day)
    }

    func newEventDraft(on date: Date) -> EventDraft? {
        defaultCalendarID.map { EventDraft(calendarID: $0, day: date) }
    }

    func newTaskDraft() -> TaskDraft? {
        (taskLists.first(where: isShown) ?? taskLists.first).map { TaskDraft(listID: $0.id, day: day) }
    }

    private func tick() async {
        let now = Date().startOfDay
        if now != day {
            day = now
            events = []
        }
        await refresh()
    }

    // MARK: Sync

    func refreshIfStale() async {
        if lastSync.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            await refresh()
        }
    }

    func refresh() async {
        guard auth.isSignedIn, loadCount == 0 else { return }
        loadCount += 1
        defer { loadCount -= 1 }
        do {
            async let cals = fetchCalendars()
            async let lists = fetchTaskLists()
            calendars = try await cals
            taskLists = try await lists

            let d = day, n = eventDays
            async let ev = fetchEvents(from: d, days: n)
            async let tk = fetchTasks()
            let (newEvents, newTasks) = try await (ev, tk)
            if d == day, n == eventDays { events = newEvents }
            tasks = newTasks
            lastSync = Date()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    func refreshEvents() async {
        guard auth.isSignedIn else { return }
        loadCount += 1
        defer { loadCount -= 1 }
        let d = day, n = eventDays
        do {
            let new = try await fetchEvents(from: d, days: n)
            if d == day, n == eventDays { events = new }
        } catch {
            report(error)
        }
    }

    func refreshTasks() async {
        guard auth.isSignedIn else { return }
        loadCount += 1
        defer { loadCount -= 1 }
        do {
            tasks = try await fetchTasks()
        } catch {
            report(error)
        }
    }

    func clear() {
        calendars = []
        events = []
        taskLists = []
        tasks = []
        lastSync = nil
        errorMessage = nil
    }

    private func report(_ error: Error) {
        if error is CancellationError { return }
        errorMessage = error.localizedDescription
    }

    private func fetchCalendars() async throws -> [CalendarInfo] {
        var result: [CalendarInfo] = []
        var token: String?
        repeat {
            let page: CalendarListResponse = try await api.get(Endpoint.calendar(
                "users", "me", "calendarList", query: ["maxResults": "250", "pageToken": token]))
            result += page.items ?? []
            token = page.nextPageToken
        } while token != nil
        return result.sorted { ($0.primary == true ? 0 : 1, $0.name) < ($1.primary == true ? 0 : 1, $1.name) }
    }

    private func fetchEvents(from day: Date, days: Int) async throws -> [CalendarEvent] {
        let visible = calendars.filter(isShown)
        let start = day, end = day.adding(days: days)
        return try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
            for cal in visible {
                group.addTask { try await self.fetchEvents(in: cal, from: start, to: end) }
            }
            var all: [CalendarEvent] = []
            for try await items in group { all += items }
            return all.sorted(by: CalendarEvent.order)
        }
    }

    private func fetchEvents(in cal: CalendarInfo, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        var result: [CalendarEvent] = []
        var token: String?
        repeat {
            let page: EventsResponse = try await api.get(Endpoint.calendar(
                "calendars", cal.id, "events",
                query: [
                    "timeMin": GDate.dateTimeString(start),
                    "timeMax": GDate.dateTimeString(end),
                    "singleEvents": "true",
                    "orderBy": "startTime",
                    "maxResults": "250",
                    "pageToken": token,
                ]))
            result += (page.items ?? []).compactMap { CalendarEvent($0, calendar: cal) }
            token = page.nextPageToken
        } while token != nil
        return result
    }

    private func fetchTaskLists() async throws -> [TaskListInfo] {
        var result: [TaskListInfo] = []
        var token: String?
        repeat {
            let page: TaskListsResponse = try await api.get(Endpoint.tasks(
                "users", "@me", "lists", query: ["maxResults": "100", "pageToken": token]))
            result += page.items ?? []
            token = page.nextPageToken
        } while token != nil
        return result
    }

    private func fetchTasks() async throws -> [TaskItem] {
        let visible = taskLists.filter(isShown)
        return try await withThrowingTaskGroup(of: [TaskItem].self) { group in
            for list in visible {
                group.addTask { try await self.fetchTasks(in: list) }
            }
            var all: [TaskItem] = []
            for try await items in group { all += items }
            return TaskItem.arranged(all)
        }
    }

    private func fetchTasks(in list: TaskListInfo) async throws -> [TaskItem] {
        var result: [TaskItem] = []
        var token: String?
        repeat {
            let page: TasksResponse = try await api.get(Endpoint.tasks(
                "lists", list.id, "tasks",
                query: ["showCompleted": "false", "showHidden": "false", "maxResults": "100", "pageToken": token]))
            result += (page.items ?? [])
                .filter { $0.status != "completed" && $0.deleted != true }
                .map { TaskItem($0, list: list) }
            token = page.nextPageToken
        } while token != nil
        return result
    }

    // MARK: Event edits

    func save(_ d: EventDraft) async throws {
        let patch = !d.isNew
        var body: [String: Any] = ["summary": d.title, "location": d.location, "description": d.notes]
        if d.isAllDay {
            let first = d.start.startOfDay
            let last = max(d.end, d.start).startOfDay
            body["start"] = allDayTime(first, patch: patch)
            body["end"] = allDayTime(last.adding(days: 1), patch: patch)
        } else {
            body["start"] = timedTime(d.start, patch: patch)
            body["end"] = timedTime(max(d.end, d.start), patch: patch)
        }
        if let id = d.eventID {
            try await api.send("PATCH", Endpoint.calendar("calendars", d.calendarID, "events", id), body: body)
        } else {
            try await api.send("POST", Endpoint.calendar("calendars", d.calendarID, "events"), body: body)
        }
        await refreshEvents()
    }

    func deleteEvent(_ d: EventDraft) async throws {
        guard let id = d.eventID else { return }
        try await api.send("DELETE", Endpoint.calendar("calendars", d.calendarID, "events", id))
        events.removeAll { $0.calendarID == d.calendarID && $0.eventID == id }
    }

    // Switching an existing event between timed and all-day requires nulling the other field.
    private func allDayTime(_ d: Date, patch: Bool) -> [String: Any] {
        var t: [String: Any] = ["date": GDate.dayString(d)]
        if patch { t["dateTime"] = NSNull() }
        return t
    }

    private func timedTime(_ d: Date, patch: Bool) -> [String: Any] {
        var t: [String: Any] = ["dateTime": GDate.dateTimeString(d), "timeZone": TimeZone.current.identifier]
        if patch { t["date"] = NSNull() }
        return t
    }

    // MARK: Task edits

    func save(_ d: TaskDraft) async throws {
        var body: [String: Any] = ["title": d.title, "notes": d.notes]
        if d.hasDue {
            body["due"] = GDate.taskDueString(d.due)
        } else if !d.isNew {
            body["due"] = NSNull()
        }
        if let id = d.taskID {
            try await api.send("PATCH", Endpoint.tasks("lists", d.listID, "tasks", id), body: body)
        } else {
            try await api.send("POST", Endpoint.tasks("lists", d.listID, "tasks", query: ["parent": d.parentID]), body: body)
        }
        await refreshTasks()
    }

    /// Completing a parent also completes its open subtasks, as the Google Tasks apps do.
    func complete(listID: String, taskID: String) async {
        let ids = [taskID] + tasks.filter { $0.listID == listID && $0.parentID == taskID }.map(\.taskID)
        tasks.removeAll { $0.listID == listID && ids.contains($0.taskID) }
        do {
            for id in ids {
                try await api.send("PATCH", Endpoint.tasks("lists", listID, "tasks", id), body: ["status": "completed"])
            }
        } catch {
            report(error)
            await refreshTasks()
        }
    }

    func deleteTask(_ d: TaskDraft) async throws {
        guard let id = d.taskID else { return }
        try await api.send("DELETE", Endpoint.tasks("lists", d.listID, "tasks", id))
        // Reload so any subtasks reflect what Google did with them.
        await refreshTasks()
    }
}
