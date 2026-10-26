import AppKit
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
    /// Every task that passes the filter, each parent followed by its subtasks.
    let tasks: [TaskItem]
    /// What the agenda shows: nothing when the list is collapsed, and no subtasks under collapsed parents.
    let visibleTasks: [TaskItem]
    let isCollapsed: Bool
    /// Parent task id → number of its subtasks in `tasks`.
    let subtaskCounts: [String: Int]

    var id: String { list.id }
}

/// Tasks completed in one go (a parent with its subtasks), kept briefly so it can be undone.
struct CompletedTasks: Identifiable, Equatable {
    let id = UUID()
    let listID: String
    let taskIDs: [String]
    let title: String
}

/// When machen talks to Google. Each events refresh costs one request per visible calendar;
/// Google's default quota is 1 million Calendar requests a day per app (shared by all users),
/// and far fewer for Tasks, so tasks and lists refresh less often.
enum Sync {
    /// Events (and so notifications) refresh this often in the background.
    static let eventsInterval: TimeInterval = 60
    /// Everything, including tasks and lists, refreshes at least this often.
    static let fullInterval: TimeInterval = 5 * 60
    /// Opening the panel refreshes, unless a refresh finished this recently.
    static let openThreshold: TimeInterval = 10
    /// Days of events loaded even when fewer are shown, so reminders for early tomorrow fire.
    static let minimumDaysLoaded = 2
    /// How far ahead the 5-minute sync looks for reminders ("1 week before" and so on).
    /// Google allows reminders up to 4 weeks before an event.
    static let reminderWindowDays = 28
    /// Only the fields notifications need, to keep the 4-week request small.
    static let reminderFields = "items(id,status,summary,description,location,start,end,attendees(self,responseStatus),"
        + "reminders,hangoutLink,conferenceData(entryPoints(entryPointType,uri)),recurringEventId,colorId,htmlLink),nextPageToken"
    /// After waking from sleep, wait this long for the network before refreshing.
    static let wakeDelay: TimeInterval = 5
}

/// Holds the synced calendar and task data and performs edits against Google.
@MainActor
final class Store: ObservableObject {
    /// Today; events cover `eventDays` days from here. Rolls over at midnight.
    @Published private(set) var day = Date().startOfDay
    static let eventDayRange = 1...14
    /// Values the Events heading steps through when clicked.
    static let eventDayCycle = [1, 2, 3, 7]

    /// The next value in `eventDayCycle`; a custom count from Settings moves to the next larger step.
    var nextEventDays: Int {
        Self.eventDayCycle.first { $0 > eventDays } ?? Self.eventDayCycle[0]
    }

    static func eventDaysLabel(_ days: Int) -> String {
        switch days {
        case 1: "Today"
        case 7: "Week"
        default: "\(days) days"
        }
    }
    @Published var eventDays: Int {
        didSet {
            UserDefaults.standard.set(eventDays, forKey: "eventDays")
            events = []
            Task { await refreshEvents() }
        }
    }
    /// Calendars and task lists as Google returns them; `calendars` and `taskLists` apply the custom order.
    @Published private var fetchedCalendars: [CalendarInfo] = []
    @Published private(set) var events: [CalendarEvent] = []
    @Published private var fetchedTaskLists: [TaskListInfo] = []
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastSync: Date?
    @Published var errorMessage: String?
    /// Tasks just completed, offered for undo for a few seconds.
    @Published private(set) var recentlyCompleted: CompletedTasks?

    /// Desktop notifications for events' Google Calendar reminders.
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            Task { await scheduleReminders() }
        }
    }
    /// macOS doesn't allow machen's notifications (set in System Settings → Notifications).
    @Published private(set) var notificationsBlocked = false

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

    @Published var headingTextSize: TextSize {
        didSet { UserDefaults.standard.set(headingTextSize.rawValue, forKey: "headingTextSize") }
    }

    @Published var nameTextSize: TextSize {
        didSet { UserDefaults.standard.set(nameTextSize.rawValue, forKey: "nameTextSize") }
    }

    @Published var detailTextSize: TextSize {
        didSet { UserDefaults.standard.set(detailTextSize.rawValue, forKey: "detailTextSize") }
    }

    var textSizes: TextSizes {
        TextSizes(heading: headingTextSize, name: nameTextSize, detail: detailTextSize)
    }

    @Published var panelHeight: PanelHeight {
        didSet { UserDefaults.standard.set(panelHeight.rawValue, forKey: "panelHeight") }
    }

    @Published var density: RowDensity {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "density") }
    }

    /// Ids in the order dragged into place in Settings, under "calendars" and "lists".
    @Published private var customOrder: [String: [String]] {
        didSet { UserDefaults.standard.set(customOrder, forKey: "customOrder") }
    }

    /// Collapsed task lists ("list:<id>") and parents with hidden subtasks ("task:<listID>/<taskID>").
    @Published private var collapsed: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
    }

    /// Task list id → palette hex chosen in Settings.
    @Published private var listColors: [String: String] {
        didSet { UserDefaults.standard.set(listColors, forKey: "listColors") }
    }

    let auth: GoogleAuth
    private let api: GoogleAPI
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// Last time everything (not just events) was refreshed.
    private var lastFullSync: Date?
    /// Events up to `Sync.reminderWindowDays` ahead, only for scheduling notifications.
    private var reminderEvents: [CalendarEvent] = []
    private var loadCount = 0 {
        didSet { isLoading = loadCount > 0 }
    }

    init(auth: GoogleAuth) {
        self.auth = auth
        api = GoogleAPI(auth: auth)
        visibility = UserDefaults.standard.dictionary(forKey: "visibility") as? [String: Bool] ?? [:]
        listColors = UserDefaults.standard.dictionary(forKey: "listColors") as? [String: String] ?? [:]
        collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? [])
        customOrder = UserDefaults.standard.dictionary(forKey: "customOrder") as? [String: [String]] ?? [:]
        density = UserDefaults.standard.string(forKey: "density").flatMap(RowDensity.init) ?? .standard
        panelHeight = UserDefaults.standard.string(forKey: "panelHeight").flatMap(PanelHeight.init) ?? .standard
        headingTextSize = UserDefaults.standard.string(forKey: "headingTextSize").flatMap(TextSize.init) ?? .medium
        nameTextSize = UserDefaults.standard.string(forKey: "nameTextSize").flatMap(TextSize.init) ?? .medium
        detailTextSize = UserDefaults.standard.string(forKey: "detailTextSize").flatMap(TextSize.init) ?? .medium
        taskFilter = UserDefaults.standard.string(forKey: "taskFilter").flatMap(TaskFilter.init) ?? .all
        menuBarIcon = UserDefaults.standard.string(forKey: "menuBarIcon") ?? "calendar"
        multiDayMode = UserDefaults.standard.string(forKey: "multiDayMode").flatMap(MultiDayMode.init) ?? .everyDay
        notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        let savedDays = UserDefaults.standard.integer(forKey: "eventDays")
        eventDays = Self.eventDayRange.contains(savedDays) ? savedDays : 1
        timer = Timer.scheduledTimer(withTimeInterval: Sync.eventsInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        // The timer pauses during sleep, so catch up right after waking
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Sync.wakeDelay))
                await self?.refreshAfterWake()
            }
        }
        // Show what was loaded last time right away, then refresh.
        loadCache()
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
    var calendars: [CalendarInfo] {
        CustomOrder.apply(customOrder["calendars"] ?? [], to: fetchedCalendars, id: \.id)
    }

    var taskLists: [TaskListInfo] {
        CustomOrder.apply(customOrder["lists"] ?? [], to: fetchedTaskLists, id: \.id)
    }

    /// Moves a calendar into another one's place (drag and drop in Settings).
    func moveCalendar(_ id: String, onto target: String) {
        guard let ids = CustomOrder.move(id, onto: target, in: calendars.map(\.id)) else { return }
        customOrder["calendars"] = ids
        events = sortedEvents(events)
    }

    /// Moves a task list into another one's place (drag and drop in Settings).
    func moveTaskList(_ id: String, onto target: String) {
        guard let ids = CustomOrder.move(id, onto: target, in: taskLists.map(\.id)) else { return }
        customOrder["lists"] = ids
    }

    private func sortedEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let rank = Dictionary(calendars.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return events.sorted(by: CalendarEvent.order(calendarRank: rank))
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
            guard !items.isEmpty else { return nil }
            // Lists can only be collapsed while their headings are shown.
            let listCollapsed = showsListNames && collapsed.contains("list:" + list.id)
            let visible = listCollapsed ? [] : items.filter { task in
                !(task.isSubtask && collapsed.contains("task:" + list.id + "/" + (task.parentID ?? "")))
            }
            let counts = Dictionary(grouping: items.filter(\.isSubtask)) { $0.parentID ?? "" }.mapValues(\.count)
            return TaskGroup(list: list, color: color(for: list), tasks: items, visibleTasks: visible,
                             isCollapsed: listCollapsed, subtaskCounts: counts)
        }
    }

    func toggleCollapsed(_ list: TaskListInfo) {
        collapsed.formSymmetricDifference(["list:" + list.id])
    }

    func subtasksCollapsed(_ task: TaskItem) -> Bool {
        collapsed.contains("task:" + task.id)
    }

    func toggleSubtasks(_ task: TaskItem) {
        collapsed.formSymmetricDifference(["task:" + task.id])
    }

    var shownTaskCount: Int { taskGroups.reduce(0) { $0 + $1.tasks.count } }

    func colorHex(for list: TaskListInfo) -> String {
        if let hex = listColors[list.id] { return hex }
        // Google's order, so dragging a list in Settings doesn't change its color
        let index = fetchedTaskLists.firstIndex(of: list) ?? 0
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

    /// Every minute: events, and everything else every few minutes.
    private func tick() async {
        rollOverDay()
        guard loadCount == 0 else { return }
        if lastFullSync.map({ Date().timeIntervalSince($0) >= Sync.fullInterval }) ?? true {
            await refresh()
        } else {
            await refreshEvents()
        }
    }

    // MARK: Sync

    private func refreshAfterWake() async {
        rollOverDay()
        await refresh()
    }

    private func rollOverDay() {
        let now = Date().startOfDay
        if now != day {
            day = now
            events = []
        }
    }

    /// Called whenever the panel opens; the cached data shows while this runs.
    func refreshOnOpen() async {
        if lastSync.map({ Date().timeIntervalSince($0) >= Sync.openThreshold }) ?? true {
            await refresh()
        }
    }

    /// Days of events to load: what's shown, but at least `Sync.minimumDaysLoaded`.
    private var daysToLoad: Int { max(eventDays, Sync.minimumDaysLoaded) }

    func refresh() async {
        guard auth.isSignedIn, loadCount == 0 else { return }
        loadCount += 1
        defer { loadCount -= 1 }
        do {
            async let cals = fetchCalendars()
            async let lists = fetchTaskLists()
            fetchedCalendars = try await cals
            fetchedTaskLists = try await lists

            let d = day, n = eventDays
            async let ev = fetchEvents(from: d, days: daysToLoad)
            async let tk = fetchTasks()
            let (newEvents, newTasks) = try await (ev, tk)
            if d == day, n == eventDays { events = newEvents }
            tasks = newTasks
            lastSync = Date()
            lastFullSync = lastSync
            errorMessage = nil
            saveCache()
            await scheduleReminders()
            await refreshReminderWindow()
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
            let new = try await fetchEvents(from: d, days: daysToLoad)
            if d == day, n == eventDays { events = new }
            lastSync = Date()
            errorMessage = nil
            saveCache()
            await scheduleReminders()
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
            saveCache()
        } catch {
            report(error)
        }
    }

    func clear() {
        fetchedCalendars = []
        events = []
        fetchedTaskLists = []
        tasks = []
        lastSync = nil
        errorMessage = nil
        recentlyCompleted = nil
        reminderEvents = []
        deleteCache()
        Task { await Notifier.shared?.removeAll() }
    }

    /// Brings macOS's scheduled notifications in line with the loaded events. The first time,
    /// macOS asks whether machen may show notifications.
    private func scheduleReminders() async {
        guard let notifier = Notifier.shared else { return }
        guard notificationsEnabled, auth.isSignedIn else {
            await notifier.removeAll()
            return
        }
        switch await notifier.authorizationStatus() {
        case .notDetermined: notificationsBlocked = !(await notifier.requestAuthorization())
        case .denied: notificationsBlocked = true
        default: notificationsBlocked = false
        }
        if notificationsBlocked {
            await notifier.removeAll()
        } else {
            await notifier.schedule(ReminderNotification.upcoming(for: eventsForReminders))
        }
    }

    private var eventsForReminders: [CalendarEvent] {
        ReminderNotification.sources(loaded: events, window: reminderEvents, loadedEnd: day.adding(days: daysToLoad))
    }

    /// Loads events up to 4 weeks ahead for notifications only (on the 5-minute sync and after
    /// event edits), then reschedules. Skipped while notifications are off, to save requests.
    private func refreshReminderWindow() async {
        guard auth.isSignedIn, notificationsEnabled, Notifier.shared != nil, !notificationsBlocked else { return }
        if let upcoming = try? await fetchEvents(from: day, days: Sync.reminderWindowDays, fields: Sync.reminderFields) {
            reminderEvents = upcoming
            saveCache()
        }
        await scheduleReminders()
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

    private func fetchEvents(from day: Date, days: Int, fields: String? = nil) async throws -> [CalendarEvent] {
        let visible = calendars.filter(isShown)
        let start = day, end = day.adding(days: days)
        return try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
            for cal in visible {
                group.addTask { try await self.fetchEvents(in: cal, from: start, to: end, fields: fields) }
            }
            var all: [CalendarEvent] = []
            for try await items in group { all += items }
            return sortedEvents(all)
        }
    }

    private func fetchEvents(in cal: CalendarInfo, from start: Date, to end: Date,
                             fields: String? = nil) async throws -> [CalendarEvent] {
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
                    "fields": fields,
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

    /// Saves a new or edited event. For an occurrence of a recurring event, `.allEvents` edits the
    /// series instead, shifted by the change made to this occurrence. A changed calendar moves the
    /// event (Google only moves whole series, so the editor asks for `.allEvents` then).
    func save(_ d: EventDraft, scope: EditScope = .thisEvent) async throws {
        let patch = !d.isNew
        let home = d.originalCalendarID ?? d.calendarID
        var targetID = d.eventID
        var start = d.start, end = max(d.end, d.start)
        if patch, scope == .allEvents, let seriesID = d.recurringEventID, let occurrenceStart = d.originalStart {
            let seriesStart = try await startOfEvent(seriesID, in: home)
            start = SeriesShift.start(seriesStart: seriesStart, occurrenceStart: occurrenceStart,
                                      editedStart: d.start, allDay: d.isAllDay)
            end = SeriesShift.end(newStart: start, editedStart: d.start, editedEnd: end, allDay: d.isAllDay)
            targetID = seriesID
        }
        var body: [String: Any] = ["summary": d.title, "location": d.location, "description": d.notes]
        if d.isAllDay {
            body["start"] = allDayTime(start.startOfDay, patch: patch)
            body["end"] = allDayTime(end.startOfDay.adding(days: 1), patch: patch)
        } else {
            body["start"] = timedTime(start, patch: patch)
            body["end"] = timedTime(end, patch: patch)
        }
        if let id = targetID {
            try await api.send("PATCH", Endpoint.calendar("calendars", home, "events", id), body: body)
            if d.isMoving {
                try await api.send("POST", Endpoint.calendar("calendars", home, "events", id, "move",
                                                             query: ["destination": d.calendarID]))
            }
        } else {
            try await api.send("POST", Endpoint.calendar("calendars", d.calendarID, "events"), body: body)
        }
        await refreshEvents()
        await refreshReminderWindow()
    }

    /// Deletes an event, or with `.allEvents` the whole series an occurrence belongs to.
    func deleteEvent(_ d: EventDraft, scope: EditScope = .thisEvent) async throws {
        guard let id = d.eventID else { return }
        let home = d.originalCalendarID ?? d.calendarID
        let series = scope == .allEvents ? d.recurringEventID : nil
        try await api.send("DELETE", Endpoint.calendar("calendars", home, "events", series ?? id))
        events.removeAll { event in
            event.calendarID == home && (event.eventID == id || (series != nil && event.recurringEventID == series))
        }
        saveCache()
        await refreshReminderWindow()
    }

    /// Start of an event as stored by Google (for a series: its first occurrence).
    private func startOfEvent(_ id: String, in calendarID: String) async throws -> Date {
        let event: GEvent = try await api.get(Endpoint.calendar("calendars", calendarID, "events", id))
        if let day = event.start?.date.flatMap(GDate.parseDay) { return day }
        if let time = event.start?.dateTime.flatMap(GDate.parseDateTime) { return time }
        throw APIError(status: 0, message: "The recurring event has no start time.")
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
    /// Afterwards the completion can be undone for a few seconds.
    func complete(listID: String, taskID: String) async {
        let ids = [taskID] + tasks.filter { $0.listID == listID && $0.parentID == taskID }.map(\.taskID)
        let title = tasks.first { $0.listID == listID && $0.taskID == taskID }?.title ?? ""
        tasks.removeAll { $0.listID == listID && ids.contains($0.taskID) }
        do {
            for id in ids {
                try await api.send("PATCH", Endpoint.tasks("lists", listID, "tasks", id), body: ["status": "completed"])
            }
            saveCache()
            offerUndo(CompletedTasks(listID: listID, taskIDs: ids, title: title))
        } catch {
            report(error)
            await refreshTasks()
        }
    }

    private func offerUndo(_ completed: CompletedTasks) {
        recentlyCompleted = completed
        Task {
            try? await Task.sleep(for: .seconds(8))
            if recentlyCompleted?.id == completed.id { recentlyCompleted = nil }
        }
    }

    /// Reopens the tasks completed last (a parent together with its subtasks).
    func undoComplete() async {
        guard let completed = recentlyCompleted else { return }
        recentlyCompleted = nil
        do {
            for id in completed.taskIDs {
                try await api.send("PATCH", Endpoint.tasks("lists", completed.listID, "tasks", id),
                                   body: ["status": "needsAction", "completed": NSNull()])
            }
        } catch {
            report(error)
        }
        await refreshTasks()
    }

    func dismissUndo() {
        recentlyCompleted = nil
    }

    // MARK: Cache

    /// What's kept on disk between launches, so machen shows data right away, and offline.
    private struct Cache: Codable {
        var calendars: [CalendarInfo]
        var taskLists: [TaskListInfo]
        var tasks: [TaskItem]
        /// Events are only reused for the same range of days.
        var events: [CalendarEvent]
        var eventsFrom: Date
        var eventDays: Int
        var lastSync: Date?
        /// Optional so caches written before it existed still load.
        var reminderEvents: [CalendarEvent]?
    }

    /// ~/Library/Application Support/<bundle id>/cache.json; none for the screenshot tool or `swift run`.
    private static let cacheURL: URL? = {
        #if SCREENSHOTS
        return nil
        #else
        guard let bundleID = Bundle.main.bundleIdentifier,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support.appendingPathComponent(bundleID).appendingPathComponent("cache.json")
        #endif
    }()

    private func loadCache() {
        guard auth.isSignedIn, let url = Self.cacheURL, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        fetchedCalendars = cache.calendars
        fetchedTaskLists = cache.taskLists
        tasks = cache.tasks
        if cache.eventsFrom == day, cache.eventDays == eventDays { events = cache.events }
        reminderEvents = cache.reminderEvents ?? []
        lastSync = cache.lastSync
    }

    private func saveCache() {
        guard auth.isSignedIn, let url = Self.cacheURL else { return }
        let cache = Cache(calendars: fetchedCalendars, taskLists: fetchedTaskLists, tasks: tasks,
                          events: events, eventsFrom: day, eventDays: eventDays, lastSync: lastSync,
                          reminderEvents: reminderEvents)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable only by you: it holds your calendar and task data
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private func deleteCache() {
        guard let url = Self.cacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func deleteTask(_ d: TaskDraft) async throws {
        guard let id = d.taskID else { return }
        try await api.send("DELETE", Endpoint.tasks("lists", d.listID, "tasks", id))
        // Reload so any subtasks reflect what Google did with them.
        await refreshTasks()
    }
}

#if SCREENSHOTS
extension Store {
    /// Fills the store with sample data for the README screenshots (Support/make-screenshots.sh).
    /// Only compiled into that tool, never into the app.
    func loadSample(calendars: [CalendarInfo], events: [CalendarEvent], taskLists: [TaskListInfo],
                    tasks: [TaskItem], collapsedLists: [String], lastSync: Date) {
        fetchedCalendars = calendars
        fetchedTaskLists = taskLists
        self.events = sortedEvents(events)
        self.tasks = tasks
        collapsed = Set(collapsedLists.map { "list:" + $0 })
        self.lastSync = lastSync
    }
}
#endif
