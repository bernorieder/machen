import AppKit
import Combine
import Network
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
    /// The list's title as shown, with its account's name when another list has the same title.
    let title: String
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
    let accountID: String
    let listID: String
    let tasks: [TaskItem]
    let title: String
    /// The queued change that completed them, taken back instead while it waits to be sent.
    let change: UUID

    var taskIDs: [String] { tasks.map(\.taskID) }
}

/// When machen syncs. Each events request costs one Google request per shown calendar;
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
    /// After waking from sleep, wait this long for the network before refreshing.
    static let wakeDelay: TimeInterval = 5
    /// When the network comes back, wait this long for the connection to settle before syncing.
    static let reconnectDelay: TimeInterval = 2
    /// After the number of days changes, wait this long before loading more, so several clicks
    /// on the Settings stepper load once.
    static let daysChangeDelay: TimeInterval = 0.4
}

/// Holds the synced calendar and task data of all accounts, and sends edits to the account they
/// belong to.
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
    /// Calendars and task lists as loaded, by account (each account's calendars primary first,
    /// then by name); `calendars` and `taskLists` apply the custom order.
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
    /// Google can't be reached: the list shows what was loaded last, and edits wait in `outbox`.
    @Published private(set) var isOffline = false
    /// Edits not yet sent to Google, oldest first. Kept on disk until they're sent.
    @Published private(set) var outbox: [PendingChange] = []

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
    /// Ids here and in the settings below are `CalendarInfo.id` and `TaskListInfo.id`, which
    /// start with the account's id.
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

    let accounts: Accounts
    // Kept for the app's lifetime
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var accountsObserver: AnyCancellable?
    private let pathMonitor = NWPathMonitor()
    /// Whether macOS has a network connection (which doesn't mean Google can be reached).
    private var networkUp = true
    /// The error the last sync showed, which the next sync replaces. Other errors, such as a
    /// change Google refused, stay until they're dismissed.
    private var syncError: String?
    /// Ids Google gave to tasks and lists created offline, and to tasks it moved.
    private var idMap = IDMap()
    /// The run sending queued changes, while one is under way.
    private var sender: Task<Void, Never>?
    /// The change being sent, which can't be taken back any more.
    private var sendingID: UUID?
    /// Edits waiting to hear whether Google took their change: nil, or why it refused.
    private var waiters: [UUID: CheckedContinuation<Error?, Never>] = [:]
    /// The accounts as last handled, to tell which were added, removed, signed out or signed in again.
    private var knownAccounts: [AccountState]
    /// A refresh of everything was asked for while another refresh ran (for example for a newly
    /// connected account); it follows as soon as that one ends.
    private var fullRefreshPending = false
    /// Last time everything (not just events) was refreshed, successfully or not.
    private var lastFullSync: Date?
    /// Number of days from `day` that `events` covers.
    private var loadedDays = 0
    /// Bumped by every local change, so a fetch that started before it can't overwrite it.
    private var eventsVersion = 0
    private var tasksVersion = 0
    private var taskListsVersion = 0
    private var pendingDaysLoad: Task<Void, Never>?
    /// The cache as last written, without its sync time, to skip rewriting it when only that changed.
    private var lastCacheContent: Cache?
    private var loadCount = 0 {
        didSet { isLoading = loadCount > 0 }
    }

    init(accounts: Accounts) {
        self.accounts = accounts
        knownAccounts = accounts.states
        if let id = accounts.legacyAccountID { Store.moveSettings(toAccount: id) }
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
        // Going offline shows at once, and machen catches up as soon as the connection is back
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up: up) }
        }
        pathMonitor.start(queue: .main)
        // Accounts being added, removed or signed out are handled here rather than in a view,
        // because the panel's views only exist once it has been opened.
        accountsObserver = accounts.$states.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.accountsChanged() }
        }
        // Set up notifications early, so clicking "Join" in one that launches machen works
        _ = Notifier.shared
        // Show what was loaded last time right away (and schedule its reminders, in case
        // machen starts offline), then refresh.
        loadCache()
        loadOutbox()
        // Separate tasks: the first scheduling may wait for an answer to macOS's notification prompt
        Task { await scheduleReminders() }
        #if !SCREENSHOTS
        Task { await refresh() }
        #endif
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

    private func calendar(_ id: String) -> CalendarInfo? { fetchedCalendars.first { $0.id == id } }
    private func taskList(_ id: String) -> TaskListInfo? { fetchedTaskLists.first { $0.id == id } }
    private func isActive(_ accountID: String) -> Bool { accounts.state(accountID)?.isActive == true }

    private func sortedEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let rank = Dictionary(calendars.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return events.sorted(by: CalendarEvent.order(calendarRank: rank))
    }

    /// Calendars new events can go in, of accounts that are signed in.
    private var writableCalendars: [CalendarInfo] { calendars.filter { $0.canEdit && isActive($0.accountID) } }
    private var defaultCalendarID: String? {
        writableCalendars.first(where: \.isPrimary)?.id ?? writableCalendars.first?.id
    }
    var showsListNames: Bool { taskLists.filter(isShown).count > 1 }

    /// Calendars an event can be saved in, by account: any writable one for a new event, and for
    /// an existing one only those of its own account (Google can't move events between accounts).
    func calendarChoices(for d: EventDraft) -> [AccountGroup<CalendarInfo>] {
        let home = d.isNew ? nil : calendar(d.originalCalendarID ?? d.calendarID)?.accountID
        return byAccount(writableCalendars.filter { home == nil || $0.accountID == home }, account: \.accountID)
    }

    /// Lists a task can be saved in, by account: any for a new task, and for an existing one only
    /// those of its own account (Google can't move tasks between accounts).
    func taskListChoices(for d: TaskDraft) -> [AccountGroup<TaskListInfo>] {
        let home = d.isNew ? nil : taskList(d.homeListID)?.accountID
        let lists = taskLists.filter { isActive($0.accountID) && (home == nil || $0.accountID == home) }
        return byAccount(lists, account: \.accountID)
    }

    private func byAccount<T: Identifiable>(_ items: [T], account: (T) -> String) -> [AccountGroup<T>] {
        accounts.states.compactMap { state in
            let own = items.filter { account($0) == state.id }
            return own.isEmpty ? nil : AccountGroup(id: state.id, name: state.name, items: own)
        }
    }

    /// Tasks of the shown lists, grouped by list in the custom order; empty lists are left out.
    var taskGroups: [TaskGroup] {
        let lists = taskLists.filter(isShown)
        // Lists can only be collapsed while their headings are shown
        let headingsShown = lists.count > 1
        // Every Google account has a "My Tasks", for example
        let titleCounts = Dictionary(grouping: lists, by: \.title).mapValues(\.count)
        return lists.compactMap { list in
            let inList = tasks.filter { $0.listID == list.id }
            let items = taskFilter == .dueOnly ? TaskItem.withDueDates(inList) : inList
            guard !items.isEmpty else { return nil }
            let listCollapsed = headingsShown && collapsed.contains(Self.listKey(list.id))
            let visible = listCollapsed ? [] : items.filter { task in
                !(task.isSubtask && collapsed.contains(Self.taskKey(list.id, task.parentID ?? "")))
            }
            let counts = Dictionary(grouping: items.filter(\.isSubtask)) { $0.parentID ?? "" }.mapValues(\.count)
            let title = (titleCounts[list.title] ?? 0) > 1
                ? "\(list.title) · \(accounts.state(list.accountID)?.shortName ?? "")" : list.title
            return TaskGroup(list: list, title: title, color: color(for: list), tasks: items, visibleTasks: visible,
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

    /// A calendar that an earlier account has too (a shared or a holiday calendar) starts hidden,
    /// so its events don't show twice.
    func isShown(_ c: CalendarInfo) -> Bool {
        visibility["cal:" + c.id] ?? (c.shownByDefault && fetchedCalendars.first { $0.remoteID == c.remoteID }?.id == c.id)
    }
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
        let lists = taskLists.filter { isActive($0.accountID) }
        return (lists.first(where: isShown) ?? lists.first).map { TaskDraft(listID: $0.id, day: day) }
    }

    /// Accounts a task list can be created in.
    var taskListAccounts: [AccountState] { accounts.states.filter(\.isActive) }

    /// The account of the list new tasks go in, for a new list unless another is chosen.
    var defaultTaskListAccountID: String? {
        newTaskDraft().flatMap { taskList($0.listID)?.accountID } ?? taskListAccounts.first?.id
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
        let today = Date().startOfDay
        guard today != day else { return }
        (events, loadedDays) = Self.carriedOver(events, loadedDays: loadedDays, from: day, to: today)
        day = today
        eventsVersion += 1
    }

    /// Loaded events still useful on a later day: those not over by its start, with the days
    /// loaded counted from it. So the list and reminders keep going while machen is offline.
    static func carriedOver(_ events: [CalendarEvent], loadedDays: Int, from: Date, to: Date) -> ([CalendarEvent], Int) {
        let elapsed = Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0
        guard elapsed >= 0, elapsed < loadedDays else { return ([], 0) }
        return (events.filter { $0.end > to }, loadedDays - elapsed)
    }

    private func networkChanged(up: Bool) {
        guard up != networkUp else { return }
        networkUp = up
        guard up else {
            isOffline = true
            return
        }
        // Catch up, and send what was changed meanwhile (see `finishSync`)
        Task {
            try? await Task.sleep(for: .seconds(Sync.reconnectDelay))
            rollOverDay()
            await refresh()
        }
    }

    /// Opening the panel refreshes events and tasks (or everything, if that's due) while the
    /// loaded data shows, unless something was refreshed moments ago.
    func refreshOnOpen() async {
        now = Date()
        guard accounts.hasActiveAccount, loadCount == 0,
              lastSync.map({ Date().timeIntervalSince($0) >= Sync.openThreshold }) ?? true else { return }
        if fullSyncDue { return await refresh() }
        loadCount += 1
        async let nearEvents = nearEventsStep()
        async let openTasks = tasksStep()
        let results = await nearEvents + openTasks
        loadCount -= 1
        await finishSync(results)
    }

    /// Everything. Calendars with their events, and task lists with their tasks, load side by
    /// side and independently, so a problem with one doesn't hold up the other; so do accounts.
    func refresh() async {
        guard accounts.hasActiveAccount else { return }
        guard loadCount == 0 else {
            fullRefreshPending = true
            return
        }
        fullRefreshPending = false
        loadCount += 1
        async let calendarsAndEvents = calendarsAndEventsStep()
        async let listsAndTasks = listsAndTasksStep()
        let results = await calendarsAndEvents + listsAndTasks
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

    private func run(_ step: () async -> [Error?]) async {
        guard accounts.hasActiveAccount else { return }
        loadCount += 1
        let results = await step()
        loadCount -= 1
        await finishSync(results)
    }

    // The steps a refresh is made of. Each reports one result per account (nil when it worked)
    // instead of throwing, so that steps and accounts running side by side don't stop each other.

    private func calendarsAndEventsStep() async -> [Error?] {
        let calendars = await loadCalendars()
        return await calendars + loadEvents(days: fullEventDays, replacing: true)
    }

    private func listsAndTasksStep() async -> [Error?] {
        let lists = await loadTaskLists()
        return await lists + loadTasks()
    }

    private func nearEventsStep() async -> [Error?] {
        await loadEvents(days: daysToLoad, replacing: false)
    }

    private func allEventsStep() async -> [Error?] {
        await loadEvents(days: fullEventDays, replacing: true)
    }

    private func tasksStep() async -> [Error?] {
        await loadTasks()
    }

    /// Runs `work` for every signed-in account side by side. Returns what each account delivered,
    /// by account id (leaving out accounts removed or signed out meanwhile), and one result per
    /// account: nil, or its error, named after the account when there are several.
    private func eachAccount<T>(_ work: @escaping (any Account) async throws -> T) async
        -> (values: [String: T], results: [Error?]) {
        let several = accounts.all.count > 1
        let outcomes = await withTaskGroup(of: (id: String, name: String, result: Result<T, Error>).self) { group in
            for account in accounts.active {
                group.addTask { @MainActor in
                    do {
                        return (account.id, account.name, .success(try await work(account)))
                    } catch {
                        return (account.id, account.name, .failure(error))
                    }
                }
            }
            var all: [(id: String, name: String, result: Result<T, Error>)] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        var values: [String: T] = [:]
        var results: [Error?] = []
        for outcome in outcomes {
            switch outcome.result {
            case .success(let value):
                if isActive(outcome.id) { values[outcome.id] = value }
                results.append(nil)
            case .failure(let error):
                results.append(several && !(error is CancellationError) ? AccountFailure(account: outcome.name, underlying: error) : error)
            }
        }
        return (values, results)
    }

    /// After any refresh: "Synced" time, the first error (if any), cache and reminders. Runs
    /// after the spinner stops, because macOS may wait for an answer to its notification prompt.
    private func finishSync(_ results: [Error?]) async {
        let errors = results.compactMap { $0 }.filter { !($0 is CancellationError) }
        if errors.count < results.count {
            lastSync = Date()
            if isOffline { isOffline = false }
        } else if !errors.isEmpty, errors.allSatisfy(\.isConnectivity), !isOffline {
            isOffline = true
        }
        // An account that needs to be signed in again is mentioned until it is. Being offline
        // shows in the footer instead.
        let signedOut = accounts.states.first { !$0.isActive }
            .map { AccountFailure(account: $0.name, underlying: AuthError.sessionExpired) }
        let message = (errors.first { !$0.isConnectivity } ?? signedOut)?.localizedDescription
        if errorMessage == nil || errorMessage == syncError, message != errorMessage { errorMessage = message }
        syncError = message
        saveCache()
        await scheduleReminders()
        // Edits made offline, or while this sync ran
        if !isOffline { sendQueued() }
        if fullRefreshPending, loadCount == 0 { await refresh() }
    }

    /// Each account's calendars; an account that can't be reached keeps the ones it had.
    private func loadCalendars() async -> [Error?] {
        let outcome = await eachAccount { try await $0.fetchCalendars() }
        let merged = accounts.all.flatMap { account in
            outcome.values[account.id] ?? fetchedCalendars.filter { $0.accountID == account.id }
        }
        if merged != fetchedCalendars { fetchedCalendars = merged }
        return outcome.results
    }

    private func loadTaskLists() async -> [Error?] {
        let version = taskListsVersion
        let outcome = await eachAccount { try await $0.fetchTaskLists() }
        // Outdated if a list was created meanwhile
        guard version == taskListsVersion else { return outcome.results }
        let merged = accounts.all.flatMap { account in
            outcome.values[account.id].map { withPending($0, of: account.id) }
                ?? fetchedTaskLists.filter { $0.accountID == account.id }
        }
        if merged != fetchedTaskLists { fetchedTaskLists = merged }
        return outcome.results
    }

    /// Loads events for `days` days from today. For each account that answers, a full load
    /// replaces its events; otherwise those days are replaced and events loaded further ahead are
    /// kept. An account that can't be reached keeps what it had.
    private func loadEvents(days: Int, replacing: Bool) async -> [Error?] {
        let from = day, version = eventsVersion, end = day.adding(days: days)
        let shown = calendars.filter(isShown)
        let outcome = await eachAccount { account in
            try await account.fetchEvents(in: shown.filter { $0.accountID == account.id }, from: from, to: end)
        }
        // Outdated if the day rolled over or an edit happened meanwhile (the edit reloads itself)
        guard from == day, version == eventsVersion else { return outcome.results }
        let keepsLater = !replacing && days < loadedDays
        let kept = events.filter { e in
            isActive(e.accountID) && (outcome.values[e.accountID] == nil || (keepsLater && e.start >= end))
        }
        // Edits not sent yet are laid over what Google sent; what's kept has them already
        let fresh = outcome.values.flatMap { withPending($0.value, of: $0.key) }
        var seen = Set<String>()
        let merged = sortedEvents((kept + fresh).filter { seen.insert($0.id).inserted })
        if merged != events { events = merged }
        loadedDays = replacing ? days : max(loadedDays, days)
        return outcome.results
    }

    private func loadTasks() async -> [Error?] {
        let version = tasksVersion
        // A list created offline isn't at Google yet
        let shown = taskLists.filter { isShown($0) && !LocalID.isLocal($0.remoteID) }
        let outcome = await eachAccount { account in
            try await account.fetchTasks(in: shown.filter { $0.accountID == account.id })
        }
        guard version == tasksVersion else { return outcome.results }
        let kept = tasks.filter { isActive($0.accountID) && outcome.values[$0.accountID] == nil }
        let fresh = outcome.values.flatMap { withPending($0.value, of: $0.key) }
        var seen = Set<String>()
        let merged = TaskItem.arranged((kept + fresh).filter { seen.insert($0.id).inserted })
        if merged != tasks { tasks = merged }
        return outcome.results
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

    /// Accounts were added, removed, signed out or signed in again.
    private func accountsChanged() {
        let states = accounts.states
        guard states != knownAccounts else { return }
        let before = knownAccounts
        knownAccounts = states
        guard !states.isEmpty else { return clear() }
        let ids = Set(states.map(\.id))
        for removed in before where !ids.contains(removed.id) { forgetSettings(of: removed.id) }
        // Removed accounts disappear. Signed-out ones keep their calendars and lists in Settings,
        // but their events and tasks are hidden until they're signed in again.
        fetchedCalendars.removeAll { !ids.contains($0.accountID) }
        fetchedTaskLists.removeAll { !ids.contains($0.accountID) }
        events.removeAll { !isActive($0.accountID) }
        tasks.removeAll { !isActive($0.accountID) }
        if let completed = recentlyCompleted, !isActive(completed.accountID) { recentlyCompleted = nil }
        // A signed-out account's edits wait until it's signed in again; a removed one's go
        if outbox.contains(where: { !ids.contains($0.accountID) }) {
            outbox.removeAll { !ids.contains($0.accountID) }
            saveOutbox()
        }
        saveCache()
        Task { await scheduleReminders() }
        // A new account, or one signed in again, needs everything loaded
        let activeBefore = Set(before.filter(\.isActive).map(\.id))
        if states.contains(where: { $0.isActive && !activeBefore.contains($0.id) }) {
            Task { await refresh() }
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
        syncError = nil
        recentlyCompleted = nil
        outbox = []
        idMap = IDMap()
        eventsVersion += 1
        tasksVersion += 1
        deleteCache()
        saveOutbox()
        Task { await Notifier.shared?.removeAll() }
    }

    /// Drops what Settings remembers about a removed account's calendars and lists.
    private func forgetSettings(of accountID: String) {
        let prefix = accountID + "/"
        // Keys are an id, or "kind:" followed by one
        func belongs(_ key: String) -> Bool {
            key.hasPrefix(prefix) || key.split(separator: ":", maxSplits: 1).last?.hasPrefix(prefix) == true
        }
        visibility = visibility.filter { !belongs($0.key) }
        collapsed = collapsed.filter { !belongs($0) }
        listColors = listColors.filter { !belongs($0.key) }
        customOrder = customOrder.mapValues { $0.filter { !belongs($0) } }
    }

    /// machen 1.x had a single Google account and kept these settings by calendar and list id
    /// alone. They now belong to the account its sign-in became.
    private static func moveSettings(toAccount accountID: String) {
        let defaults = UserDefaults.standard
        let prefix = accountID + "/"
        // "cal:<id>" becomes "cal:<account>/<id>"
        func qualified(_ key: String) -> String {
            guard let colon = key.firstIndex(of: ":") else { return prefix + key }
            return String(key[...colon]) + prefix + String(key[key.index(after: colon)...])
        }
        if let visibility = defaults.dictionary(forKey: "visibility") as? [String: Bool] {
            defaults.set(Dictionary(visibility.map { (qualified($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }),
                         forKey: "visibility")
        }
        if let collapsed = defaults.stringArray(forKey: "collapsed") {
            defaults.set(collapsed.map(qualified), forKey: "collapsed")
        }
        if let colors = defaults.dictionary(forKey: "listColors") as? [String: String] {
            defaults.set(Dictionary(colors.map { (prefix + $0.key, $0.value) }, uniquingKeysWith: { a, _ in a }),
                         forKey: "listColors")
        }
        if let order = defaults.dictionary(forKey: "customOrder") as? [String: [String]] {
            defaults.set(order.mapValues { $0.map { prefix + $0 } }, forKey: "customOrder")
        }
    }

    /// Brings macOS's scheduled notifications in line with the loaded events. The first time,
    /// macOS asks whether machen may show notifications.
    private func scheduleReminders() async {
        guard let notifier = Notifier.shared else { return }
        guard notificationsEnabled, accounts.hasActiveAccount else {
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

    // MARK: Edits

    // Every edit becomes a `PendingChange`: shown in the list at once, kept on disk, and sent to
    // Google in order. Online, the editor waits for Google's answer, so a refusal shows there.
    // Offline, or when the connection drops, the change waits and is sent once machen is online.

    private func account(_ id: String) throws -> any Account {
        guard let account = accounts.account(id) else { throw AccountError.notConnected }
        return account
    }

    /// Saves a new or edited event. For an occurrence of a repeating event, `.allEvents` edits the
    /// series. A changed calendar moves the event, within its account.
    func save(_ d: EventDraft, scope: EditScope = .thisEvent) async throws {
        guard let target = calendar(d.calendarID), let home = calendar(d.originalCalendarID ?? d.calendarID) else {
            throw AccountError.missing
        }
        guard target.accountID == home.accountID else { throw AccountError.otherAccount }
        let editsSeries = scope == .allEvents && d.recurringEventID != nil && !d.isNew
        // Refused here rather than once it's sent
        if editsSeries, d.timesChanged, let original = d.original {
            try SeriesShift.check(original: original, edited: d.values)
        }
        try await perform(PendingChange(accountID: home.accountID,
                                        kind: .saveEvent(d, scope: editsSeries ? .allEvents : .thisEvent)))
    }

    /// Deletes an event, or with `.allEvents` the whole series an occurrence belongs to.
    func deleteEvent(_ d: EventDraft, scope: EditScope = .thisEvent) async throws {
        guard d.eventID != nil else { return }
        guard let home = calendar(d.originalCalendarID ?? d.calendarID) else { throw AccountError.missing }
        try await perform(PendingChange(accountID: home.accountID, kind: .deleteEvent(d, scope: scope)))
    }

    /// Saves a new or edited task. A changed list moves the task with its open subtasks, within
    /// its account. Returns the task's id: a local one until Google has a new task.
    @discardableResult
    func save(_ d: TaskDraft) async throws -> String? {
        let d = d.resolved(idMap)
        guard let list = taskList(d.listID), let home = taskList(d.homeListID) else { throw AccountError.missing }
        guard list.accountID == home.accountID else { throw AccountError.otherAccount }
        if let taskID = d.taskID {
            let subtaskIDs = !d.isMoving ? [] : tasks.filter { $0.listID == home.id && $0.parentID == taskID }
                .sorted { $0.position < $1.position }.map(\.taskID)
            try await perform(PendingChange(accountID: home.accountID, kind: .updateTask(d, subtaskIDs: subtaskIDs)))
            return idMap(taskID)
        }
        let localID = LocalID.make()
        try await perform(PendingChange(accountID: list.accountID, kind: .createTask(d, localID: localID)))
        return idMap(localID)
    }

    /// Creates a task list, so its first task can be added right away.
    func createTaskList(titled title: String, in accountID: String) async throws -> TaskListInfo {
        let list = TaskListInfo(accountID: accountID, remoteID: LocalID.make(), title: title)
        // Unless chosen, colours follow Google's order of lists, which the new list changes. So
        // every list keeps the colour it has, and the new one gets the least used.
        let used = Dictionary(grouping: fetchedTaskLists.map(colorHex(for:)), by: { $0 }).mapValues(\.count)
        for other in fetchedTaskLists where listColors[other.id] == nil {
            listColors[other.id] = colorHex(for: other)
        }
        listColors[list.id] = ListPalette.colors.min { used[$0.hex, default: 0] < used[$1.hex, default: 0] }?.hex
        try await perform(PendingChange(accountID: accountID, kind: .createTaskList(list)))
        return list.resolved(idMap)
    }

    /// Completing a parent also completes its open subtasks, as the Google Tasks apps do.
    /// Afterwards the completion can be undone for a few seconds.
    func complete(listID: String, taskID: String) async {
        let listID = idMap(listID), taskID = idMap(taskID)
        // Already completed, for example by a quick second click
        guard let task = tasks.first(where: { $0.listID == listID && $0.taskID == taskID }),
              let list = taskList(listID) else { return }
        let done = [task] + tasks.filter { $0.listID == listID && $0.parentID == taskID }
        let change = PendingChange(accountID: list.accountID, kind: .setCompleted(true, tasks: done))
        do {
            try await perform(change)
            offerUndo(CompletedTasks(accountID: list.accountID, listID: listID, tasks: done, title: task.title,
                                     change: change.id))
        } catch {
            report(error)
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
        let reopen = PendingChange(accountID: completed.accountID,
                                   kind: .setCompleted(false, tasks: completed.tasks.map { $0.resolved(idMap) }))
        // Not sent yet: the completion is simply taken back
        if completed.change != sendingID, outbox.contains(where: { $0.id == completed.change }) {
            outbox.removeAll { $0.id == completed.change }
            saveOutbox()
            applyLocally(reopen)
            return
        }
        do {
            try await perform(reopen)
        } catch {
            report(error)
        }
    }

    func deleteTask(_ d: TaskDraft) async throws {
        let d = d.resolved(idMap)
        guard d.taskID != nil else { return }
        guard let list = taskList(d.homeListID) else { throw AccountError.missing }
        try await perform(PendingChange(accountID: list.accountID, kind: .deleteTask(d)))
    }

    /// Whether an edit of the event or task hasn't reached Google yet.
    func isPending(_ event: CalendarEvent) -> Bool { outbox.contains { $0.concerns(event) } }
    func isPending(_ task: TaskItem) -> Bool { outbox.contains { $0.resolved(idMap).concerns(task) } }

    /// The id a task or list has now, for an editor opened before Google gave it its own.
    func currentID(_ id: String) -> String { idMap(id) }

    // MARK: Sending edits

    /// Shows a change at once and queues it. Online, returns once Google has it, and throws if
    /// Google refuses it. Offline, or when the connection drops, it returns with the change queued.
    private func perform(_ change: PendingChange) async throws {
        outbox.append(change)
        saveOutbox()
        applyLocally(change)
        guard !isOffline else { return sendQueued() }
        let refusal = await withCheckedContinuation { continuation in
            waiters[change.id] = continuation
            sendQueued()
        }
        if let refusal { throw refusal }
    }

    private func applyLocally(_ change: PendingChange) {
        if change.changesEvents {
            eventsVersion += 1
            events = sortedEvents(change.apply(to: events, calendars: fetchedCalendars))
            Task { await scheduleReminders() }
        } else if change.changesTaskLists {
            taskListsVersion += 1
            fetchedTaskLists = change.apply(to: fetchedTaskLists)
        } else {
            tasksVersion += 1
            tasks = TaskItem.arranged(change.apply(to: tasks))
        }
        saveCache()
    }

    /// Data just loaded for an account, with that account's queued changes laid over it.
    private func withPending(_ events: [CalendarEvent], of accountID: String) -> [CalendarEvent] {
        outbox.filter { $0.accountID == accountID && $0.changesEvents }
            .reduce(events) { $1.resolved(idMap).apply(to: $0, calendars: fetchedCalendars) }
    }

    private func withPending(_ tasks: [TaskItem], of accountID: String) -> [TaskItem] {
        outbox.filter { $0.accountID == accountID && !$0.changesEvents && !$0.changesTaskLists }
            .reduce(tasks) { $1.resolved(idMap).apply(to: $0) }
    }

    private func withPending(_ lists: [TaskListInfo], of accountID: String) -> [TaskListInfo] {
        outbox.filter { $0.accountID == accountID && $0.changesTaskLists }
            .reduce(lists) { $1.resolved(idMap).apply(to: $0) }
    }

    /// Starts sending the queued changes, unless that's under way.
    private func sendQueued() {
        guard sender == nil, !outbox.isEmpty else { return }
        sender = Task { await sendPending() }
    }

    /// Sends the queued changes oldest first, each with the ids Google gave meanwhile. Stops when
    /// the connection is gone. An account's changes wait while it needs to be signed in again,
    /// or while Google is busy.
    private func sendPending() async {
        var waiting: Set<String> = []
        var nearEvents = false, allEvents = false, openTasks = false
        sending: while let change = outbox.first(where: { !waiting.contains($0.accountID) }) {
            guard isActive(change.accountID) else {
                waiting.insert(change.accountID)
                continue
            }
            sendingID = change.id
            var refusal: Error?
            do {
                try await send(change.resolved(idMap))
                if isOffline { isOffline = false }
            } catch where error.isTemporary {
                sendingID = nil
                if error.isConnectivity {
                    isOffline = true
                    break sending
                }
                waiting.insert(change.accountID)
                continue
            } catch {
                refusal = error
            }
            sendingID = nil
            switch change.kind {
            case .saveEvent(let d, let scope):
                if scope == .allEvents || d.start >= day.adding(days: daysToLoad) { allEvents = true } else { nearEvents = true }
            case .deleteEvent(_, let scope):
                if scope == .allEvents { allEvents = true } else { nearEvents = true }
            default:
                openTasks = true
            }
            finish(change, refusal: refusal)
        }
        // Other edits waiting keep their change queued
        for waiter in waiters.values { waiter.resume(returning: nil) }
        waiters = [:]
        sender = nil
        // What Google made of the changes, and a refused change undone
        guard nearEvents || allEvents || openTasks else { return }
        Task {
            if openTasks { await refreshTasks() }
            if allEvents { await refreshAllEvents() } else if nearEvents { await refreshEvents() }
        }
    }

    /// Sends one change to its account. Deleting or completing what's gone already counts as done.
    private func send(_ change: PendingChange) async throws {
        let account = try self.account(change.accountID)
        switch change.kind {
        case .saveEvent(let d, let scope):
            guard let target = calendar(d.calendarID), let home = calendar(d.originalCalendarID ?? d.calendarID) else {
                throw AccountError.missing
            }
            try await account.save(d, in: target, home: home, scope: scope)
        case .deleteEvent(let d, let scope):
            guard let home = calendar(d.originalCalendarID ?? d.calendarID) else { throw AccountError.missing }
            do { try await account.deleteEvent(d, in: home, scope: scope) } catch where error.isGone {}
        case .createTask(let d, let localID):
            guard let list = taskList(d.listID) else { throw AccountError.missing }
            adopt(try await account.save(d, in: list), for: localID)
        case .updateTask(let d, let subtaskIDs):
            guard let taskID = d.taskID, let list = taskList(d.listID), let home = taskList(d.homeListID) else {
                throw AccountError.missing
            }
            _ = try await account.save(d, in: home)
            if d.isMoving {
                adopt(try await account.moveTask(taskID, subtaskIDs: subtaskIDs, from: home, to: list), for: taskID)
            }
        case .setCompleted(let done, let tasks):
            guard let listID = tasks.first?.listID, let list = taskList(listID) else { throw AccountError.missing }
            do {
                try await account.setCompleted(done, taskIDs: tasks.map(\.taskID), in: list)
            } catch where done && error.isGone {}
        case .deleteTask(let d):
            guard let taskID = d.taskID, let list = taskList(d.homeListID) else { throw AccountError.missing }
            do { try await account.deleteTask(taskID, in: list) } catch where error.isGone {}
        case .createTaskList(let local):
            adopt(try await account.createTaskList(titled: local.title).remoteID, for: local.remoteID)
        }
    }

    /// A change Google took or refused leaves the queue. Refused, it takes along the changes that
    /// needed what it would have created, and is reported unless an editor is waiting for it.
    private func finish(_ change: PendingChange, refusal: Error?) {
        var finished = [change]
        if refusal != nil, let localID = change.createdLocalID {
            finished += outbox.filter { $0.depends(on: localID) }
        }
        let ids = Set(finished.map(\.id))
        outbox.removeAll { ids.contains($0.id) }
        saveOutbox()
        // Loads that started before Google had it are outdated
        if finished.contains(where: \.changesEvents) { eventsVersion += 1 }
        if finished.contains(where: \.changesTaskLists) { taskListsVersion += 1 }
        if finished.contains(where: { !$0.changesEvents && !$0.changesTaskLists }) { tasksVersion += 1 }
        for done in finished {
            if let waiter = waiters.removeValue(forKey: done.id) {
                waiter.resume(returning: refusal)
            } else if let refusal, done.id == change.id {
                report(ChangeRefused(subject: change.subject, underlying: refusal))
            }
        }
    }

    /// Google gave a task or list a new id (one created offline, or a moved task): everything
    /// that knows the old one follows, including the list's settings.
    private func adopt(_ newID: String, for oldID: String) {
        guard newID != oldID else { return }
        idMap.record(newID, for: oldID)
        tasks = TaskItem.arranged(tasks.map { $0.resolved(idMap) })
        fetchedTaskLists = fetchedTaskLists.map { $0.resolved(idMap) }
        func renamed(_ key: String) -> String { key.replacingOccurrences(of: oldID, with: newID) }
        if listColors.keys.contains(where: { $0.contains(oldID) }) {
            listColors = Dictionary(listColors.map { (renamed($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        if visibility.keys.contains(where: { $0.contains(oldID) }) {
            visibility = Dictionary(visibility.map { (renamed($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        if collapsed.contains(where: { $0.contains(oldID) }) { collapsed = Set(collapsed.map(renamed)) }
        if customOrder.values.joined().contains(where: { $0.contains(oldID) }) {
            customOrder = customOrder.mapValues { $0.map(renamed) }
        }
        saveOutbox()
        saveCache()
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
        /// Events from `eventsFrom` for `loadedDays` days; on a later day, those not over yet.
        var events: [CalendarEvent]
        var eventsFrom: Date
        var loadedDays: Int
        var lastSync: Date?

        var withoutSyncTime: Cache {
            var copy = self
            copy.lastSync = nil
            return copy
        }
    }

    /// ~/Library/Application Support/<bundle id>/cache.json; none for the screenshot and test
    /// tools or `swift run`.
    private static let cacheURL: URL? = {
        #if SCREENSHOTS || TESTING
        return nil
        #else
        guard let bundleID = Bundle.main.bundleIdentifier,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support.appendingPathComponent(bundleID).appendingPathComponent("cache.json")
        #endif
    }()

    /// A cache from machen 1.x has no accounts in it, doesn't decode, and is replaced by the first sync.
    private func loadCache() {
        guard !accounts.all.isEmpty, let url = Self.cacheURL, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        let ids = Set(accounts.all.map(\.id))
        fetchedCalendars = cache.calendars.filter { ids.contains($0.accountID) }
        fetchedTaskLists = cache.taskLists.filter { ids.contains($0.accountID) }
        tasks = cache.tasks.filter { isActive($0.accountID) }
        (events, loadedDays) = Self.carriedOver(cache.events.filter { isActive($0.accountID) },
                                                loadedDays: cache.loadedDays, from: cache.eventsFrom, to: day)
        lastSync = cache.lastSync
        lastCacheContent = cache.withoutSyncTime
    }

    private func saveCache() {
        guard !accounts.all.isEmpty, let url = Self.cacheURL else { return }
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

    /// Edits not sent yet, and the ids Google gave meanwhile, which changes after them may need.
    private struct Outbox: Codable {
        var changes: [PendingChange]
        var ids: IDMap
    }

    /// outbox.json next to the cache; there only while edits wait to be sent.
    private static let outboxURL = cacheURL?.deletingLastPathComponent().appendingPathComponent("outbox.json")

    private func loadOutbox() {
        guard let url = Self.outboxURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Outbox.self, from: data) else { return }
        let ids = Set(accounts.all.map(\.id))
        outbox = saved.changes.filter { ids.contains($0.accountID) }
        idMap = saved.ids
    }

    /// Written for every change, so no edit is lost when machen quits.
    private func saveOutbox() {
        guard let url = Self.outboxURL else { return }
        guard !outbox.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(Outbox(changes: outbox, ids: idMap)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable only by you, like the cache
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

#if SCREENSHOTS
extension Store {
    /// Fills the store with sample data for the README screenshots (Support/make-screenshots.sh).
    /// Only compiled into that tool, never into the app.
    func loadSample(calendars: [CalendarInfo], events: [CalendarEvent], taskLists: [TaskListInfo],
                    tasks: [TaskItem], collapsedLists: [String], lastSync: Date) {
        // Setting the number of days may have asked for a load, which the sample accounts can't do
        pendingDaysLoad?.cancel()
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
