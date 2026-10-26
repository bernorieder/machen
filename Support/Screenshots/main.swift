// Renders the README screenshots from the app's real views, filled with sample data.
// Built and run by Support/make-screenshots.sh: arguments are the output folder and the app icon.
import AppKit
import SwiftUI

let outputFolder = URL(fileURLWithPath: CommandLine.arguments[1])
// Never touch the real app's settings, and start from the defaults every time
guard let bundleID = Bundle.main.bundleIdentifier, bundleID != "io.github.bernorieder.machen" else {
    fatalError("The screenshot tool must not use machen's own bundle ID")
}
UserDefaults.standard.removePersistentDomain(forName: bundleID)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
// The tool isn't an app bundle, so give it the app's icon (shown in Settings)
app.applicationIconImage = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))

// MARK: - Sample data (relative to now, so it always looks current)

let today = Date().startOfDay
let hour = Calendar.current.dateInterval(of: .hour, for: Date())!.start

let personalAccount = (id: "google-sample1", email: "sam@example.com")
let workAccount = (id: "google-sample2", email: "sam@university.example.org")

func calendar(_ id: String, _ name: String, _ color: String, account: String = personalAccount.id,
              primary: Bool = false) -> CalendarInfo {
    CalendarInfo(accountID: account, remoteID: id, name: name, color: color, canEdit: true, isPrimary: primary,
                 shownByDefault: true, defaultReminderMinutes: [])
}

func event(_ title: String, _ cal: CalendarInfo, start: Date, hours: Double = 1, location: String = "",
           meeting: String? = nil) -> CalendarEvent {
    CalendarEvent(eventID: title, calendarID: cal.id, accountID: cal.accountID, title: title, start: start,
                  end: start.addingTimeInterval(hours * 3600), isAllDay: false, location: location, notes: "",
                  color: cal.color, canEdit: true, declined: false, link: nil, meetingURL: meeting.flatMap(URL.init),
                  recurringEventID: nil, reminderMinutes: [])
}

func allDay(_ title: String, _ cal: CalendarInfo, from: Int, days: Int) -> CalendarEvent {
    CalendarEvent(eventID: title, calendarID: cal.id, accountID: cal.accountID, title: title,
                  start: today.adding(days: from), end: today.adding(days: from + days), isAllDay: true,
                  location: "", notes: "", color: cal.color, canEdit: true, declined: false, link: nil,
                  meetingURL: nil, recurringEventID: nil, reminderMinutes: [])
}

func task(_ id: String, _ title: String, in list: TaskListInfo, parent: String? = nil, dueIn days: Int? = nil,
          notes: String = "") -> TaskItem {
    TaskItem(taskID: id, listID: list.id, accountID: list.accountID, title: title, notes: notes,
             due: days.map { today.adding(days: $0) }, position: id, parentID: parent)
}

let personal = calendar("personal", "Personal", "#039BE5", primary: true)
let work = calendar("work", "Work", "#0B8043", account: workAccount.id, primary: true)
let holidays = calendar("holidays", "Holidays", "#8E24AA")

let events = [
    event("Team stand-up", work, start: hour.addingTimeInterval(-2 * 3600), hours: 0.25),
    event("Project call", work, start: Date().addingTimeInterval(5 * 60), hours: 0.5, meeting: "https://meet.google.com/abc-defg-hij"),
    event("Lunch with Sam", personal, start: hour.addingTimeInterval(1.5 * 3600), location: "Café Central"),
    event("Seminar: platform studies", work, start: hour.addingTimeInterval(4 * 3600), hours: 2, location: "Room 4.12"),
    allDay("Conference in Lisbon", work, from: 1, days: 3),
    event("Dentist", personal, start: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: today.adding(days: 1))!),
    allDay("Public holiday", holidays, from: 2, days: 1),
    event("Book club", personal, start: Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: today.adding(days: 2))!, hours: 2),
]

let todo = TaskListInfo(accountID: personalAccount.id, remoteID: "todo", title: "To do")
let workList = TaskListInfo(accountID: workAccount.id, remoteID: "worklist", title: "Work")
let home = TaskListInfo(accountID: personalAccount.id, remoteID: "home", title: "Home")

let tasks = TaskItem.arranged([
    task("a", "Renew passport", in: todo, dueIn: -2),
    task("b", "Call the bank", in: todo, dueIn: 0),
    task("c", "Send birthday card", in: todo),
]) + TaskItem.arranged([
    task("d", "Prepare workshop slides", in: workList, dueIn: 1),
    task("d1", "Collect figures", in: workList, parent: "d"),
    task("d2", "Ask Maria for the dataset", in: workList, parent: "d", dueIn: 0),
    task("e", "Review paper draft", in: workList, dueIn: 4, notes: "Sections 3 and 4"),
    task("f", "Update website", in: workList),
]) + TaskItem.arranged([
    task("g", "Groceries", in: home, dueIn: 1),
    task("g1", "Coffee beans", in: home, parent: "g"),
    task("h", "Fix the bike light", in: home),
])

// MARK: - Rendering

/// Renders a view at popover size through AppKit (so real controls draw) and frames it like the popover.
@MainActor
func screenshot<V: View>(_ view: V, store: Store, dark: Bool, name: String) {
    let size = NSSize(width: Layout.Popover.width, height: PanelHeight.standard.points)
    let content = view
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(store.accounts)
        .environmentObject(store.accounts.googleAuth)
        .environmentObject(store)
        .environment(\.rowDensity, store.density)
        .environment(\.textSizes, store.textSizes)
        .environment(\.colorScheme, dark ? .dark : .light)
    let hosting = NSHostingView(rootView: content)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
    hosting.cacheDisplay(in: hosting.bounds, to: rep)

    // Rounded corners, a hairline border and a soft shadow, at 2x
    let margin: CGFloat = 24, radius: CGFloat = 12
    let canvas = NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    let frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
    let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.shadowBlurRadius = 18
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    rep.draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
    (dark ? NSColor.white.withAlphaComponent(0.15) : NSColor.black.withAlphaComponent(0.12)).setStroke()
    path.lineWidth = 1
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let url = outputFolder.appendingPathComponent(name)
    try! out.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote", url.path)
}

MainActor.assumeIsolated {
    let accounts = Accounts()
    accounts.loadSample([personalAccount, workAccount])
    let store = Store(accounts: accounts)
    store.eventDays = 1
    store.menuBarIcon = "calendar"
    store.loadSample(calendars: [personal, work, holidays], events: events, taskLists: [todo, workList, home],
                     tasks: tasks, collapsedLists: [home.id],
                     lastSync: Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: today)!)

    screenshot(AgendaView(route: .constant(.agenda)), store: store, dark: false, name: "agenda-light.png")
    screenshot(AgendaView(route: .constant(.agenda)), store: store, dark: true, name: "agenda-dark.png")
    for panel in SettingsPanel.allCases {
        screenshot(SettingsView(panel: panel, onClose: {}), store: store, dark: false, name: "settings-\(panel.rawValue).png")
    }
    // For the website in dark mode
    screenshot(SettingsView(panel: .sources, onClose: {}), store: store, dark: true, name: "settings-sources-dark.png")
}
