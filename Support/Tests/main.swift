// Checks machen's offline editing against a fake account whose connection can be cut: edits
// made offline show at once and wait, are sent in order once online, with the ids the "server"
// gives, and a refused change is undone and reported. Run with Support/run-tests.sh.
import AppKit

@MainActor var failures = 0

@MainActor func check(_ condition: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if condition {
        print("  ok    \(what)")
    } else {
        failures += 1
        print("  FAIL  \(what) (line \(line))")
    }
}

/// Lets the store's background work (loads, sending) run until `done` or a few seconds pass.
@MainActor func settle(until done: () -> Bool = { false }) async {
    for _ in 0..<150 {
        if done() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// A Google account kept in memory. `offline` cuts its connection; `refuse` makes it turn down
/// requests whose description contains the string, the way Google answers 403.
@MainActor final class FakeAccount: Account {
    let id = "fake"
    let name = "sam@example.org"
    var isActive = true
    var offline = false
    var refuse: String?
    /// Cuts the connection right after a request whose description contains this arrives.
    var cutAfter: String?
    /// Every request that reached the "server", in order.
    var log: [String] = []
    var calendars: [CalendarInfo]
    var events: [CalendarEvent]
    var lists: [TaskListInfo]
    var tasks: [TaskItem]
    /// Moving gives a task a new id, which Google may do too.
    var movesChangeIDs = true
    private var counter = 0

    init() {
        let work = CalendarInfo(accountID: "fake", remoteID: "work", name: "Work", color: "#0B8043", canEdit: true,
                                isPrimary: true, shownByDefault: true, defaultReminderMinutes: [10])
        let home = CalendarInfo(accountID: "fake", remoteID: "home", name: "Home", color: "#039BE5", canEdit: true,
                                isPrimary: false, shownByDefault: true, defaultReminderMinutes: [])
        calendars = [work, home]
        let today = Date().startOfDay
        func event(_ id: String, _ title: String, in cal: CalendarInfo, hour: Int, series: String? = nil) -> CalendarEvent {
            let start = today.adding(days: 1).addingTimeInterval(Double(hour) * 3600)
            return CalendarEvent(eventID: id, calendarID: cal.id, accountID: "fake", title: title, start: start,
                                 end: start.addingTimeInterval(3600), isAllDay: false, location: "", notes: "",
                                 color: cal.color, canEdit: true, declined: false, link: nil, meetingURL: nil,
                                 recurringEventID: series, reminderMinutes: [])
        }
        events = [event("e1", "Stand-up", in: work, hour: 9), event("e2", "Dentist", in: home, hour: 11)]
        let todo = TaskListInfo(accountID: "fake", remoteID: "todo", title: "To do")
        let errands = TaskListInfo(accountID: "fake", remoteID: "errands", title: "Errands")
        lists = [todo, errands]
        func task(_ id: String, _ title: String, in list: TaskListInfo, parent: String? = nil) -> TaskItem {
            TaskItem(taskID: id, listID: list.id, accountID: "fake", title: title, notes: "", due: nil, position: id,
                     parentID: parent)
        }
        tasks = [task("t1", "Renew passport", in: todo), task("t2", "Call the bank", in: todo),
                 task("t3", "Groceries", in: errands), task("t3a", "Coffee", in: errands, parent: "t3"),
                 task("t4", "Water plants", in: todo)]
    }

    private func reach(_ request: String) throws {
        if offline { throw URLError(.notConnectedToInternet) }
        if let refuse, request.contains(refuse) { throw APIError(status: 403, message: "Not allowed") }
        log.append(request)
        if let cutAfter, request.contains(cutAfter) { offline = true }
    }

    private func newID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)\(counter)"
    }

    func fetchCalendars() async throws -> [CalendarInfo] {
        if offline { throw URLError(.notConnectedToInternet) }
        return calendars
    }

    func fetchEvents(in calendars: [CalendarInfo], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        if offline { throw URLError(.notConnectedToInternet) }
        let ids = Set(calendars.map(\.id))
        return events.filter { ids.contains($0.calendarID) && $0.end > start && $0.start < end }
    }

    func fetchTaskLists() async throws -> [TaskListInfo] {
        if offline { throw URLError(.notConnectedToInternet) }
        return lists
    }

    func fetchTasks(in lists: [TaskListInfo]) async throws -> [TaskItem] {
        if offline { throw URLError(.notConnectedToInternet) }
        let ids = Set(lists.map(\.id))
        if let missing = lists.first(where: { !self.lists.contains($0) }) {
            throw APIError(status: 404, message: "No list \(missing.remoteID)")
        }
        return tasks.filter { ids.contains($0.listID) }
    }

    func save(_ d: EventDraft, in calendar: CalendarInfo, home: CalendarInfo, scope: EditScope) async throws {
        try reach("save event \(d.title)")
        if d.isNew {
            if events.contains(where: { $0.eventID == d.newEventID }) { throw APIError(status: 409, message: "Exists") }
            events.append(CalendarEvent(new: d, accountID: id, in: calendar))
        } else {
            events = events.map { $0.calendarID == home.id && $0.eventID == d.eventID ? $0.edited(by: d, asSeries: false, in: calendar) : $0 }
        }
    }

    func deleteEvent(_ d: EventDraft, in calendar: CalendarInfo, scope: EditScope) async throws {
        try reach("delete event \(d.title)")
        guard events.contains(where: { $0.eventID == d.eventID }) else { throw APIError(status: 410, message: "Gone") }
        events.removeAll { $0.eventID == d.eventID }
    }

    func save(_ d: TaskDraft, in list: TaskListInfo) async throws -> String {
        try reach("save task \(d.title) in \(list.remoteID)" + (d.parentID.map { " under \($0)" } ?? ""))
        if LocalID.isLocal(list.remoteID) || d.parentID.map(LocalID.isLocal) == true || d.taskID.map(LocalID.isLocal) == true {
            throw APIError(status: 404, message: "Sent a local id")
        }
        guard let taskID = d.taskID else {
            let id = newID("T")
            tasks.append(TaskItem(taskID: id, listID: list.id, accountID: self.id, title: d.title, notes: d.notes,
                                  due: d.hasDue ? d.due.startOfDay : nil, position: "0", parentID: d.parentID))
            return id
        }
        tasks = tasks.map { t in
            t.taskID == taskID ? TaskItem(taskID: taskID, listID: t.listID, accountID: id, title: d.title, notes: d.notes,
                                          due: d.hasDue ? d.due.startOfDay : nil, position: t.position, parentID: t.parentID) : t
        }
        return taskID
    }

    func moveTask(_ taskID: String, subtaskIDs: [String], from home: TaskListInfo, to list: TaskListInfo) async throws -> String {
        try reach("move task \(taskID) to \(list.remoteID)")
        let movedID = movesChangeIDs ? newID("M") : taskID
        tasks = tasks.map { t in
            guard t.taskID == taskID || subtaskIDs.contains(t.taskID) else { return t }
            return TaskItem(taskID: t.taskID == taskID ? movedID : t.taskID, listID: list.id, accountID: id, title: t.title,
                            notes: t.notes, due: t.due, position: t.position, parentID: t.parentID == taskID ? movedID : t.parentID)
        }
        return movedID
    }

    func createTaskList(titled title: String) async throws -> TaskListInfo {
        try reach("create list \(title)")
        let list = TaskListInfo(accountID: id, remoteID: newID("L"), title: title)
        lists.append(list)
        return list
    }

    func setCompleted(_ completed: Bool, taskIDs: [String], in list: TaskListInfo) async throws {
        try reach("\(completed ? "complete" : "reopen") \(taskIDs.joined(separator: ","))")
        if completed { tasks.removeAll { taskIDs.contains($0.taskID) } }
    }

    func deleteTask(_ taskID: String, in list: TaskListInfo) async throws {
        try reach("delete task \(taskID)")
        tasks.removeAll { $0.taskID == taskID || $0.parentID == taskID }
    }
}

@MainActor func runTests() async {
    let fake = FakeAccount()
    let accounts = Accounts()
    let store = Store(accounts: accounts)
    accounts.testing = [fake]
    await store.refresh()
    print("Loading")
    check(store.events.count == 2, "loads the account's events")
    check(store.tasks.count == 5, "loads its tasks")
    check(!store.isOffline, "is online")

    print("Going offline")
    fake.offline = true
    await store.refresh()
    check(store.isOffline, "notices it's offline")
    check(store.errorMessage == nil, "shows no error for it")
    check(store.events.count == 2 && store.tasks.count == 5, "keeps what it loaded")

    print("Editing offline")
    let todo = store.taskLists.first { $0.remoteID == "todo" }!
    var newEvent = EventDraft(calendarID: "fake/work", day: Date().startOfDay.adding(days: 1))
    newEvent.title = "Planning"
    _ = try? await store.save(newEvent)
    let created = store.events.first { $0.title == "Planning" }
    check(created?.eventID == newEvent.newEventID, "a new event shows at once, under the id machen gave it")
    check(created.map(store.isPending) == true, "and is marked as not synced")

    var dentist = EventDraft(store.events.first { $0.eventID == "e2" }!)
    dentist.title = "Dentist (moved)"
    dentist.calendarID = "fake/work"
    _ = try? await store.save(dentist)
    check(store.events.contains { $0.eventID == "e2" && $0.title == "Dentist (moved)" && $0.calendarID == "fake/work" },
          "an edited and moved event shows its changes")
    try? await store.deleteEvent(EventDraft(store.events.first { $0.eventID == "e1" }!))
    check(!store.events.contains { $0.eventID == "e1" }, "a deleted event goes")

    let trip = try? await store.createTaskList(titled: "Trip", in: "fake")
    check(trip.map { LocalID.isLocal($0.remoteID) } == true, "a new list gets a local id")
    var pack = TaskDraft(listID: trip?.id ?? "", day: Date())
    pack.title = "Pack"
    let packID = (try? await store.save(pack)) ?? nil
    check(packID.map(LocalID.isLocal) == true, "a new task in it gets a local id")
    var socks = TaskDraft(subtaskOf: packID ?? "", listID: trip?.id ?? "")
    socks.title = "Socks"
    _ = try? await store.save(socks)
    check(store.tasks.contains { $0.title == "Socks" && $0.parentID == packID && $0.isSubtask },
          "a subtask of it shows under it")
    check(store.taskGroups.contains { $0.list.title == "Trip" && $0.tasks.count == 2 }, "the new list shows with both")

    var passport = TaskDraft(store.tasks.first { $0.taskID == "t1" }!)
    passport.title = "Renew passport soon"
    _ = try? await store.save(passport)
    var groceries = TaskDraft(store.tasks.first { $0.taskID == "t3" }!)
    groceries.listID = todo.id
    _ = try? await store.save(groceries)
    check(store.tasks.contains { $0.taskID == "t3a" && $0.listID == todo.id }, "a moved task takes its subtask along")
    await store.complete(listID: todo.id, taskID: "t2")
    check(!store.tasks.contains { $0.taskID == "t2" }, "a completed task goes")
    await store.complete(listID: todo.id, taskID: "t4")
    await store.undoComplete()
    check(store.tasks.contains { $0.taskID == "t4" }, "undo brings it back")
    check(!store.outbox.contains { if case .setCompleted(_, let tasks) = $0.kind { return tasks.contains { $0.taskID == "t4" } }; return false },
          "and takes the unsent completion back instead of sending both")
    check(fake.log.isEmpty, "nothing reached the server")
    check(store.outbox.count == 9, "nine changes wait (\(store.outbox.count))")

    let encoded = try? JSONEncoder().encode(store.outbox)
    let decoded = encoded.flatMap { try? JSONDecoder().decode([PendingChange].self, from: $0) }
    check(decoded == store.outbox, "the waiting changes survive being saved and read back")

    print("Refreshing while still offline")
    await store.refresh()
    check(store.tasks.contains { $0.title == "Renew passport soon" } && store.events.contains { $0.title == "Planning" },
          "edits stay shown")

    print("Back online")
    fake.offline = false
    await store.refresh()
    await settle { store.outbox.isEmpty }
    await settle()
    check(store.outbox.isEmpty, "every change was sent")
    check(!store.isOffline, "is online again")
    print("    sent: " + fake.log.joined(separator: " | "))
    check(fake.log.first == "save event Planning", "in the order they were made")
    check(fake.events.contains { $0.eventID == newEvent.newEventID && $0.title == "Planning" },
          "the new event is at Google under machen's id")
    check(fake.events.contains { $0.eventID == "e2" && $0.calendarID == "fake/work" }, "the moved event too")
    check(!fake.events.contains { $0.eventID == "e1" }, "the deleted one is gone")
    let realTrip = fake.lists.first { $0.title == "Trip" }
    check(realTrip != nil, "the new list exists")
    let realPack = fake.tasks.first { $0.title == "Pack" }
    check(realPack?.listID == realTrip?.id, "its task is in it")
    check(fake.tasks.contains { $0.title == "Socks" && $0.parentID == realPack?.taskID }, "with its subtask under it")
    check(fake.tasks.contains { $0.title == "Renew passport soon" }, "the edit arrived")
    check(!fake.tasks.contains { $0.taskID == "t2" } && fake.tasks.contains { $0.taskID == "t4" },
          "one task is completed, the undone one isn't")
    check(fake.tasks.contains { $0.title == "Groceries" && $0.listID == todo.id }
          && fake.tasks.contains { $0.taskID == "t3a" && $0.listID == todo.id }, "the moved task and its subtask arrived")
    check(!store.tasks.contains { LocalID.isLocal($0.taskID) || LocalID.isLocal($0.listID) },
          "machen shows Google's ids now")
    check(store.taskLists.contains { $0.title == "Trip" && !LocalID.isLocal($0.remoteID) }, "for the list too")
    check(store.currentID(packID ?? "") == realPack?.taskID, "an editor's old id leads to the new one")
    check(!store.events.contains(where: store.isPending) && !store.tasks.contains(where: store.isPending),
          "nothing is marked as not synced")
    check(store.events.filter { $0.title == "Planning" }.count == 1, "the new event shows once")

    print("A refused edit, online")
    fake.log = []
    fake.refuse = "save task Call"
    var bank = TaskDraft(store.tasks.first { $0.title == "Water plants" }!)
    bank.title = "Call the bank"
    var thrown: Error?
    do { try await store.save(bank) } catch { thrown = error }
    check(thrown is APIError, "the editor gets Google's refusal")
    check(store.outbox.isEmpty, "the change isn't kept")
    await settle { store.tasks.contains { $0.title == "Water plants" } }
    check(store.tasks.contains { $0.title == "Water plants" }, "and the list shows Google's version again")
    fake.refuse = nil

    print("A refused creation, sent later")
    fake.offline = true
    await store.refresh()
    fake.refuse = "save task Doomed"
    var doomed = TaskDraft(listID: todo.id, day: Date())
    doomed.title = "Doomed"
    let doomedID = (try? await store.save(doomed)) ?? nil
    var child = TaskDraft(subtaskOf: doomedID ?? "", listID: todo.id)
    child.title = "Child"
    _ = try? await store.save(child)
    var later = TaskDraft(listID: todo.id, day: Date())
    later.title = "Unrelated"
    _ = try? await store.save(later)
    fake.offline = false
    await store.refresh()
    await settle { store.outbox.isEmpty }
    await settle()
    check(store.outbox.isEmpty, "the queue is empty")
    check(!fake.tasks.contains { $0.title == "Child" }, "the subtask of the refused task is dropped too")
    check(fake.tasks.contains { $0.title == "Unrelated" }, "other changes still go through")
    check(store.errorMessage?.contains("Doomed") == true, "the refusal is reported: \(store.errorMessage ?? "nothing")")
    await store.refresh()
    check(store.errorMessage?.contains("Doomed") == true, "and stays after the next sync")
    check(!store.tasks.contains { $0.title == "Doomed" || $0.title == "Child" }, "the list no longer shows them")
    fake.refuse = nil
    store.errorMessage = nil

    print("The connection breaks off while sending")
    fake.offline = true
    await store.refresh()
    var first = TaskDraft(listID: todo.id, day: Date())
    first.title = "First"
    _ = try? await store.save(first)
    var second = TaskDraft(listID: todo.id, day: Date())
    second.title = "Second"
    _ = try? await store.save(second)
    fake.offline = false
    fake.log = []
    fake.cutAfter = "First"
    await store.refresh()
    await settle { store.isOffline }
    fake.cutAfter = nil
    check(fake.tasks.contains { $0.title == "First" } && !fake.tasks.contains { $0.title == "Second" },
          "the first arrived, the second didn't")
    check(store.outbox.count == 1 && store.isOffline, "the second waits, and machen is offline")
    fake.offline = false
    await store.refresh()
    await settle { store.outbox.isEmpty }
    check(fake.tasks.contains { $0.title == "Second" }, "it's sent once the connection is back")

    print("Google briefly failing")
    fake.log = []
    fake.refuse = nil
    var busy = TaskDraft(listID: todo.id, day: Date())
    busy.title = "Busy"
    let busyFake = BusyOnce(fake)
    accounts.testing = [busyFake]
    _ = try? await store.save(busy)
    check(store.outbox.count == 1 && !store.isOffline, "a 503 keeps the change waiting, without counting as offline")
    await store.refresh()
    await settle { store.outbox.isEmpty }
    check(fake.tasks.contains { $0.title == "Busy" }, "and it's sent on the next try")
    accounts.testing = [fake]

    print("A new day while offline")
    let today = Date().startOfDay
    func timed(_ id: String, days: Int) -> CalendarEvent {
        let start = today.adding(days: days).addingTimeInterval(9 * 3600)
        return CalendarEvent(eventID: id, calendarID: "c", accountID: "a", title: id, start: start,
                             end: start.addingTimeInterval(3600), isAllDay: false, location: "", notes: "", color: nil,
                             canEdit: true, declined: false, link: nil, meetingURL: nil, recurringEventID: nil,
                             reminderMinutes: [])
    }
    let loaded = [timed("today", days: 0), timed("tomorrow", days: 1), timed("in a week", days: 7)]
    let (kept, days) = Store.carriedOver(loaded, loadedDays: 28, from: today, to: today.adding(days: 1))
    check(kept.map(\.eventID) == ["tomorrow", "in a week"] && days == 27, "events still to come are kept, with 27 days loaded")
    check(Store.carriedOver(loaded, loadedDays: 2, from: today, to: today.adding(days: 3)).1 == 0,
          "nothing is kept beyond what was loaded")

    print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
}

/// The fake account, answering 503 to the first change sent to it.
@MainActor final class BusyOnce: Account {
    let base: FakeAccount
    private var failed = false
    init(_ base: FakeAccount) { self.base = base }
    var id: String { base.id }
    var name: String { base.name }
    var isActive: Bool { base.isActive }
    private func once() throws {
        if !failed { failed = true; throw APIError(status: 503, message: "Backend Error") }
    }
    func fetchCalendars() async throws -> [CalendarInfo] { try await base.fetchCalendars() }
    func fetchEvents(in calendars: [CalendarInfo], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try await base.fetchEvents(in: calendars, from: start, to: end)
    }
    func fetchTaskLists() async throws -> [TaskListInfo] { try await base.fetchTaskLists() }
    func fetchTasks(in lists: [TaskListInfo]) async throws -> [TaskItem] { try await base.fetchTasks(in: lists) }
    func save(_ draft: EventDraft, in calendar: CalendarInfo, home: CalendarInfo, scope: EditScope) async throws {
        try once()
        try await base.save(draft, in: calendar, home: home, scope: scope)
    }
    func deleteEvent(_ draft: EventDraft, in calendar: CalendarInfo, scope: EditScope) async throws {
        try once()
        try await base.deleteEvent(draft, in: calendar, scope: scope)
    }
    func save(_ draft: TaskDraft, in list: TaskListInfo) async throws -> String {
        try once()
        return try await base.save(draft, in: list)
    }
    func moveTask(_ taskID: String, subtaskIDs: [String], from home: TaskListInfo, to list: TaskListInfo) async throws -> String {
        try once()
        return try await base.moveTask(taskID, subtaskIDs: subtaskIDs, from: home, to: list)
    }
    func createTaskList(titled title: String) async throws -> TaskListInfo {
        try once()
        return try await base.createTaskList(titled: title)
    }
    func setCompleted(_ completed: Bool, taskIDs: [String], in list: TaskListInfo) async throws {
        try once()
        try await base.setCompleted(completed, taskIDs: taskIDs, in: list)
    }
    func deleteTask(_ taskID: String, in list: TaskListInfo) async throws {
        try once()
        try await base.deleteTask(taskID, in: list)
    }
}

Task { @MainActor in
    await runTests()
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
