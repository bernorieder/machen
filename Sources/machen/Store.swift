import AppKit
import Combine
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

/// When machen talks to Google. Each events request costs one request per shown calendar;
/// Google's default quota is 1 million Calendar requests a day per app (shared by all users),
/// and far fewer for Tasks, so tasks and lists refresh less often.
enum Sync {
    /// Events near today (and so notifications) refresh this often in the background.
    static let eventsInterval: TimeInterval = 60
    /// Everything (calendars, task lists, tasks, and events up to 4 weeks ahead) refreshes this often.
    static let fullInterval: TimeInterval = 5 * 60
    /// Opening the panel refreshes events and tasks, unless something was refreshed this recently.
    static let openThreshold: TimeInterval = 10
    /// Days of events refreshed every minute even when fewer are shown, so reminders for early
    /// tomorrow are current.
    static let minimumDaysLoaded = 2
    /// How far ahead the full sync loads events while notifications are on, for reminders like
    /// "1 week before". Google allows reminders up to 4 weeks before an event.
    static let reminderWindowDays = 28
    /// The event fields machen uses. Asking for just these keeps responses small (no guest lists).
    static let eventFields = "items(id,status,summary,description,location,start,end,attendees(self,responseStatus),"
        + "reminders,hangoutLink,conferenceData(entryPoints(entryPointType,uri)),recurringEventId,colorId,htmlLink),nextPageToken"
    /// After waking from sleep, wait this long for the network before refreshing.
    static let wakeDelay: TimeInterval = 5
    /// After the number of days changes, wait this long before loading more, so several clicks
    /// on the Settings stepper load once.
    static let daysChangeDelay: TimeInterval = 0.4
}

/// Holds the synced calendar and task data and performs edits against Google.
@MainActor
final class Store: ObservableObject {
    /// Today; events are shown for `eventDays` days from here. Rolls over at midnight.
    @Published private(set) var day = Date().startOfDay
    /// The time the list was last checked against; events that ended before it are hidden.
    /// Updated every minute and when the panel opens.
    @Published private(set) var now = Date()
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
            // Days already loaded show right away; only load when more are needed
            if daysToLoad > loadedDays { loadMoreDaysSoon() }
        }
    }
    /// Calendars (primary first, then by name) and task lists as loaded; `calendars` and
    /// `taskLists` apply the custom order.
    @Published private var fetchedCalendars: [CalendarInfo] = []
    /// Events from `day` for `loadedDays` days, of the calendars shown when they were loaded.
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
            // Turning them on needs events up to 4 weeks ahead; turning them off removes what's scheduled
            Task {
                if notificationsEnabled { await refreshAllEvents() } else { await scheduleReminders() }
            }
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

    /// Collapsed task lists (`listKey`) and parents with hidden subtasks (`taskKey`).
    @Published private var collapsed: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
    }

    /// Task list id → palette hex chosen in Settings.
    @Published private var listColors: [String: String] {
        didSet { UserDefaults.standard.set(listColors, forKey: "listColors") }
    }

    let auth: GoogleAuth
    private let api: GoogleAPI
    // Kept for the app's lifetime
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var signInObserver: AnyCancellable?
    /// Last time everything (not just events) was refreshed, successfully or not.
    private var lastFullSync: Date?
    /// Number of days from `day` that `events` covers.
    private var loadedDays = 0
    /// Bumped by every local change, so a fetch that started before it can't overwrite it.
    private var eventsVersion = 0
    private var tasksVersion = 0
    private var pendingDaysLoad: Task<Void, Never>?
    /// The cache as last written, without its sync time, to skip rewriting it when only that changed.
    private var lastCacheContent: Cache?
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
        // Signing in and out (including an expired session) is handled here rather than in a
        // view, because the panel's views only exist once it has been opened.
        signInObserver = auth.$isSignedIn.dropFirst().removeDuplicates().sink { [weak self] signedIn in
            Task { @MainActor in
                if signedIn { await self?.refresh() } else { self?.clear() }
            }
        }
        // Set up notifications early, so clicking "Join" in one that launches machen works
        _ = Notifier.shared
        // Show what was loaded last time right away (and schedule its reminders, in case
        // machen starts offline), then refresh.
        loadCache()
        // Separate tasks: the first scheduling may wait for an answer to macOS's notification prompt
        Task { await scheduleReminders() }
        Task { await refresh() }
    }

    // MARK: Derived state

    /// Ids of the calendars switched on in Settings → Sources.
    private var shownCalendarIDs: Set<String> { Set(fetchedCalendars.filter(isShown).map(\.id)) }

    /// Loaded events of shown calendars; a calendar hidden a moment ago disappears without a reload.
    private var shownEvents: [CalendarEvent] {
        let shown = shownCalendarIDs
        return events.filter { shown.contains($0.calendarID) }
    }

    /// Events still to come or under way, by day. Finished ones are left out.
    var eventsByDay: [EventDay] {
        EventDay.group(shownEvents.filter { $0.end > now }, from: day, days: eventDays, multiDay: multiDayMode)
    }

    /// Number of distinct events shown, counting a repeated multi-day event once.
    var shownEventCount: Int {
        Set(eventsByDay.flatMap { $0.events.map(\.id) }).count
    }

    /// Whether events for this day have been loaded (a newly added day may still be loading).
    func isLoaded(_ date: Date) -> Bool { date < day.adding(days: loadedDays) }

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

    /// Tasks of the shown lists, grouped by list in the custom order; empty lists are left out.
    var taskGroups: [TaskGroup] {
        let lists = taskLists.filter(isShown)
        // Lists can only be collapsed while their headings are shown
        let headingsShown = lists.count > 1
        return lists.compactMap { list in
            let inList = tasks.filter { $0.listID == list.id }
            let items = taskFilter == .dueOnly ? TaskItem.withDueDates(inList) : inList
            guard !items.isEmpty else { return nil }
            let listCollapsed = headingsShown && collapsed.contains(Self.listKey(list.id))
            let visible = listCollapsed ? [] : items.filter { task in
                !(task.isSubtask && collapsed.contains(Self.taskKey(list.id, task.parentID ?? "")))
            }
            let counts = Dictionary(grouping: items.filter(\.isSubtask)) { $0.parentID ?? "" }.mapValues(\.count)
            return TaskGroup(list: list, color: color(for: list), tasks: items, visibleTasks: visible,
                             isCollapsed: listCollapsed, subtaskCounts: counts)
        }
    }

    private static func listKey(_ listID: String) -> String { "list:" + listID }
    private static func taskKey(_ listID: String, _ taskID: String) -> String { "task:" + listID + "/" + taskID }

    func toggleCollapsed(_ list: TaskListInfo) {
        collapsed.formSymmetricDifference([Self.listKey(list.id)])
    }

    func subtasksCollapsed(_ task: TaskItem) -> Bool {
        collapsed.contains(Self.taskKey(task.listID, task.taskID))
    }

    func toggleSubtasks(_ task: TaskItem) {
        collapsed.formSymmetricDifference([Self.taskKey(task.listID, task.taskID)])
    }

    func colorHex(for list: TaskListInfo) -> String {
        if let hex = listColors[list.id] { return hex }
        // Google's order, so dragging a list in Settings doesn't change its colour
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

    /// Hiding filters what's loaded; showing a calendar loads its events.
    func setShown(_ c: CalendarInfo, _ shown: Bool) {
        visibility["cal:" + c.id] = shown
        Task {
            if shown { await refreshAllEvents() } else { await scheduleReminders() }
        }
    }

    func setShown(_ l: TaskListInfo, _ shown: Bool) {
        visibility["list:" + l.id] = shown
        if shown { Task { await refreshTasks() } }
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

    // MARK: Sync

    /// Days of events refreshed every minute: what's shown, but at least `Sync.minimumDaysLoaded`.
    private var daysToLoad: Int { max(eventDays, Sync.minimumDaysLoaded) }
    /// Days of events loaded by the full sync: 4 weeks while notifications may need them.
    private var fullEventDays: Int {
        notificationsEnabled && !notificationsBlocked && Notifier.shared != nil
            ? max(Sync.reminderWindowDays, daysToLoad) : daysToLoad
    }
    private var fullSyncDue: Bool {
        lastFullSync.map { Date().timeIntervalSince($0) >= Sync.fullInterval } ?? true
    }

    /// Every minute: events near today, and everything every few minutes.
    private func tick() async {
        now = Date()
        rollOverDay()
        guard loadCount == 0 else { return }
        if fullSyncDue { await refresh() } else { await refreshEvents() }
    }

    private func refreshAfterWake() async {
        rollOverDay()
        await refresh()
    }

    private func rollOverDay() {
        let now = Date().startOfDay
        guard now != day else { return }
        day = now
        events = []
        loadedDays = 0
        eventsVersion += 1
    }

    /// Opening the panel refreshes events and tasks (or everything, if that's due) while the
    /// loaded data shows, unless something was refreshed moments ago.
    func refreshOnOpen() async {
        now = Date()
        guard auth.isSignedIn, loadCount == 0,
              lastSync.map({ Date().timeIntervalSince($0) >= Sync.openThreshold }) ?? true else { return }
        if fullSyncDue { return await refresh() }
        loadCount += 1
        async let nearEvents = nearEventsStep()
        async let openTasks = tasksStep()
        let results = await [nearEvents, openTasks]
        loadCount -= 1
        await finishSync(results)
    }

    /// Everything. Calendars with their events, and task lists with their tasks, load side by
    /// side and independently, so a problem with one doesn't hold up the other.
    func refresh() async {
        guard auth.isSignedIn, loadCount == 0 else { return }
        loadCount += 1
        async let calendarsAndEvents = calendarsAndEventsStep()
        async let listsAndTasks = listsAndTasksStep()
        let results = await [calendarsAndEvents, listsAndTasks]
        loadCount -= 1
        // Counted even after a failure, so a failing Tasks API doesn't make every tick a full sync
        lastFullSync = Date()
        await finishSync(results)
    }

    /// Events near today; later loaded days are kept.
    func refreshEvents() async {
        await run(nearEventsStep)
    }

    /// All events the full sync covers, without calendars or tasks.
    private func refreshAllEvents() async {
        await run(allEventsStep)
    }

    func refreshTasks() async {
        await run(tasksStep)
    }

    private func run(_ step: () async -> Error?) async {
        guard auth.isSignedIn else { return }
        loadCount += 1
        let result = await step()
        loadCount -= 1
        await finishSync([result])
    }

    // The steps a refresh is made of; each reports its error instead of throwing, so that
    // steps running side by side don't stop each other.

    private func calendarsAndEventsStep() async -> Error? {
        await attempt {
            let calendars = try await fetchCalendars()
            if calendars != fetchedCalendars { fetchedCalendars = calendars }
            try await loadEvents(days: fullEventDays, replacing: true)
        }
    }

    private func listsAndTasksStep() async -> Error? {
        await attempt {
            let lists = try await fetchTaskLists()
            if lists != fetchedTaskLists { fetchedTaskLists = lists }
            try await loadTasks()
        }
    }

    private func nearEventsStep() async -> Error? {
        await attempt { try await loadEvents(days: daysToLoad, replacing: false) }
    }

    private func allEventsStep() async -> Error? {
        await attempt { try await loadEvents(days: fullEventDays, replacing: true) }
    }

    private func tasksStep() async -> Error? {
        await attempt { try await loadTasks() }
    }

    private func attempt(_ step: () async throws -> Void) async -> Error? {
        do {
            try await step()
            return nil
        } catch {
            return error
        }
    }

    /// After any refresh: "Synced" time, the first error (if any), cache and reminders. Runs
    /// after the spinner stops, because macOS may wait for an answer to its notification prompt.
    private func finishSync(_ results: [Error?]) async {
        let errors = results.compactMap { $0 }.filter { !($0 is CancellationError) }
        if errors.count < results.count { lastSync = Date() }
        let message = errors.first?.localizedDescription
        if message != errorMessage { errorMessage = message }
        saveCache()
        await scheduleReminders()
    }

    /// Loads events for `days` days from today. A full load replaces everything; otherwise
    /// those days are replaced and events loaded further ahead are kept.
    private func loadEvents(days: Int, replacing: Bool) async throws {
        let from = day, version = eventsVersion
        let fetched = try await fetchEvents(from: from, days: days)
        // Outdated if the day rolled over or an edit happened meanwhile (the edit reloads itself)
        guard from == day, version == eventsVersion else { return }
        let end = from.adding(days: days)
        let merged = replacing || days >= loadedDays ? fetched : sortedEvents(fetched + events.filter { $0.start >= end })
        if merged != events { events = merged }
        loadedDays = replacing ? days : max(loadedDays, days)
    }

    private func loadTasks() async throws {
        let version = tasksVersion
        let fetched = try await fetchTasks()
        guard version == tasksVersion else { return }
        if fetched != tasks { tasks = fetched }
    }

    /// More days were chosen than are loaded: load them shortly (clicks in between restart the wait).
    private func loadMoreDaysSoon() {
        pendingDaysLoad?.cancel()
        pendingDaysLoad = Task {
            try? await Task.sleep(for: .seconds(Sync.daysChangeDelay))
            guard !Task.isCancelled else { return }
            await refreshEvents()
        }
    }

    func clear() {
        fetchedCalendars = []
        events = []
        loadedDays = 0
        fetchedTaskLists = []
        tasks = []
        lastSync = nil
        lastFullSync = nil
        errorMessage = nil
        recentlyCompleted = nil
        eventsVersion += 1
        tasksVersion += 1
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
        let blocked: Bool
        switch await notifier.authorizationStatus() {
        case .notDetermined: blocked = !(await notifier.requestAuthorization())
        case .denied: blocked = true
        default: blocked = false
        }
        if blocked != notificationsBlocked { notificationsBlocked = blocked }
        if blocked {
            await notifier.removeAll()
        } else {
            await notifier.schedule(ReminderNotification.upcoming(for: shownEvents))
        }
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
        let shown = calendars.filter(isShown)
        let start = day, end = day.adding(days: days)
        return try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
            for cal in shown {
                group.addTask { try await self.fetchEvents(in: cal, from: start, to: end) }
            }
            var all: [CalendarEvent] = []
            for try await items in group { all += items }
            return sortedEvents(all)
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
                    "fields": Sync.eventFields,
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
        let shown = taskLists.filter(isShown)
        return try await withThrowingTaskGroup(of: [TaskItem].self) { group in
            for list in shown {
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

    /// Saves a new or edited event, sending only what changed. Returns once Google has it; the
    /// list refreshes in the background. For an occurrence of a repeating event, `.allEvents`
    /// edits the series instead (see `SeriesShift`). A changed calendar moves the event (Google
    /// only moves whole series, so the editor offers that for `.allEvents` only).
    func save(_ d: EventDraft, scope: EditScope = .thisEvent) async throws {
        eventsVersion += 1
        let home = d.originalCalendarID ?? d.calendarID
        let editsSeries = scope == .allEvents && d.recurringEventID != nil && !d.isNew
        var body: [String: Any] = [:]
        if d.original?.title != d.title { body["summary"] = d.title }
        if d.original?.location != d.location { body["location"] = d.location }
        if d.original?.notes != d.notes { body["description"] = d.notes }
        if d.timesChanged {
            var start = d.start, end = max(d.end, d.start), timeZone = TimeZone.current.identifier
            if editsSeries, let original = d.original, let seriesID = d.recurringEventID {
                try SeriesShift.check(original: original, edited: d.values)
                let series: GEvent = try await api.get(Endpoint.calendar("calendars", home, "events", seriesID))
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
        if let id = editsSeries ? d.recurringEventID : d.eventID {
            if !body.isEmpty {
                try await api.send("PATCH", Endpoint.calendar("calendars", home, "events", id), body: body)
            }
            if d.isMoving {
                try await api.send("POST", Endpoint.calendar("calendars", home, "events", id, "move",
                                                             query: ["destination": d.calendarID]))
            }
        } else {
            try await api.send("POST", Endpoint.calendar("calendars", d.calendarID, "events"), body: body)
        }
        // A series or an event beyond the near days needs the whole range reloaded
        let near = !editsSeries && d.start < day.adding(days: daysToLoad)
        Task {
            if near { await refreshEvents() } else { await refreshAllEvents() }
        }
    }

    /// Deletes an event, or with `.allEvents` the whole series an occurrence belongs to.
    func deleteEvent(_ d: EventDraft, scope: EditScope = .thisEvent) async throws {
        guard let id = d.eventID else { return }
        eventsVersion += 1
        let home = d.originalCalendarID ?? d.calendarID
        let series = scope == .allEvents ? d.recurringEventID : nil
        try await api.send("DELETE", Endpoint.calendar("calendars", home, "events", series ?? id))
        events.removeAll { event in
            event.calendarID == home && (event.eventID == id || (series != nil && event.recurringEventID == series))
        }
        saveCache()
        await scheduleReminders()
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

    /// Saves a new or edited task. Returns once Google has it; the list refreshes in the background.
    func save(_ d: TaskDraft) async throws {
        tasksVersion += 1
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
        Task { await refreshTasks() }
    }

    /// Completing a parent also completes its open subtasks, as the Google Tasks apps do.
    /// Afterwards the completion can be undone for a few seconds.
    func complete(listID: String, taskID: String) async {
        // Already completed, for example by a quick second click
        guard let task = tasks.first(where: { $0.listID == listID && $0.taskID == taskID }) else { return }
        tasksVersion += 1
        let ids = [taskID] + tasks.filter { $0.listID == listID && $0.parentID == taskID }.map(\.taskID)
        tasks.removeAll { $0.listID == listID && ids.contains($0.taskID) }
        do {
            for id in ids {
                try await api.send("PATCH", Endpoint.tasks("lists", listID, "tasks", id), body: ["status": "completed"])
            }
            saveCache()
            offerUndo(CompletedTasks(listID: listID, taskIDs: ids, title: task.title))
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
        tasksVersion += 1
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

    func deleteTask(_ d: TaskDraft) async throws {
        guard let id = d.taskID else { return }
        tasksVersion += 1
        try await api.send("DELETE", Endpoint.tasks("lists", d.listID, "tasks", id))
        tasks.removeAll { $0.listID == d.listID && ($0.taskID == id || $0.parentID == id) }
        // Reload so any subtasks reflect what Google did with them
        Task { await refreshTasks() }
    }

    private func report(_ error: Error) {
        if error is CancellationError { return }
        errorMessage = error.localizedDescription
    }

    // MARK: Cache

    /// What's kept on disk between launches, so machen shows data right away, and offline.
    private struct Cache: Codable, Equatable {
        var calendars: [CalendarInfo]
        var taskLists: [TaskListInfo]
        var tasks: [TaskItem]
        /// Events from `eventsFrom` for `loadedDays` days; only reused on the same day.
        var events: [CalendarEvent]
        var eventsFrom: Date
        /// Optional so cache files written before it existed still load.
        var loadedDays: Int?
        var lastSync: Date?

        var withoutSyncTime: Cache {
            var copy = self
            copy.lastSync = nil
            return copy
        }
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
        if cache.eventsFrom == day {
            events = cache.events
            loadedDays = cache.loadedDays ?? 0
        }
        lastSync = cache.lastSync
        lastCacheContent = cache.withoutSyncTime
    }

    private func saveCache() {
        guard auth.isSignedIn, let url = Self.cacheURL else { return }
        let cache = Cache(calendars: fetchedCalendars, taskLists: fetchedTaskLists, tasks: tasks,
                          events: events, eventsFrom: day, loadedDays: loadedDays, lastSync: lastSync)
        // The sync time alone changes every minute; it's not worth a write
        guard cache.withoutSyncTime != lastCacheContent, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable only by you: it holds your calendar and task data
        if FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            lastCacheContent = cache.withoutSyncTime
        }
    }

    private func deleteCache() {
        lastCacheContent = nil
        guard let url = Self.cacheURL else { return }
        try? FileManager.default.removeItem(at: url)
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
        loadedDays = Self.eventDayRange.upperBound
        self.tasks = tasks
        collapsed = Set(collapsedLists.map(Self.listKey))
        self.lastSync = lastSync
    }
}
#endif
