import AppKit
import UserNotifications

/// A desktop notification for one reminder of one event.
struct ReminderNotification: Equatable {
    let id: String
    let fireDate: Date
    let title: String
    let body: String
    let meetingURL: URL?

    static let idPrefix = "reminder:"
    /// At most this many reminders are scheduled at a time (the soonest), well below macOS's limit
    /// on pending notifications per app.
    static let maximumScheduled = 60

    /// Notifications for the popup reminders of `events` that are still ahead (declined events skipped).
    static func upcoming(for events: [CalendarEvent], now: Date = Date()) -> [ReminderNotification] {
        events.filter { !$0.declined }.flatMap { event in
            event.reminderMinutes.compactMap { minutes -> ReminderNotification? in
                let fire = event.start.addingTimeInterval(-Double(minutes) * 60)
                guard fire > now else { return nil }
                return ReminderNotification(
                    id: "\(idPrefix)\(event.id)@\(Int(event.start.timeIntervalSince1970))-\(minutes)",
                    fireDate: fire, title: event.displayTitle, body: body(for: event, minutes: minutes),
                    meetingURL: event.meetingURL)
            }
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    /// "In 10 minutes · 14:00 – 15:00 · Room 4.12", or "Tomorrow · All day" for all-day events.
    static func body(for event: CalendarEvent, minutes: Int) -> String {
        var parts: [String] = []
        if event.isAllDay {
            let cal = Calendar.current
            let fire = event.start.addingTimeInterval(-Double(minutes) * 60)
            parts.append(cal.isDate(fire, inSameDayAs: event.start) ? "Today"
                         : cal.isDate(fire.adding(days: 1), inSameDayAs: event.start) ? "Tomorrow"
                         : event.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            parts.append("All day")
        } else {
            parts.append(minutes == 0 ? "Starting now" : "In " + duration(minutes: minutes))
            parts.append("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
        }
        if !event.location.isEmpty { parts.append(event.location) }
        return parts.joined(separator: " · ")
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f
    }()

    private static func duration(minutes: Int) -> String {
        durationFormatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) minutes"
    }
}

/// Schedules machen's reminder notifications with macOS. Notifications need an app bundle,
/// so there's none when running the bare executable (`swift run`) or the screenshot tool.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared: Notifier? = {
        #if SCREENSHOTS
        return nil
        #else
        return Bundle.main.bundleURL.pathExtension == "app" ? Notifier() : nil
        #endif
    }()

    nonisolated static let joinAction = "join"
    nonisolated static let callCategory = "event-with-call"
    nonisolated static let meetingKey = "meetingURL"

    private let center = UNUserNotificationCenter.current()
    /// What machen scheduled, by id, so unchanged reminders aren't handed to macOS again.
    private var scheduled: [String: ReminderNotification] = [:]
    /// A permission request in progress, shared by everyone asking meanwhile.
    private var authorizationRequest: Task<Bool, Never>?

    private override init() {
        super.init()
        center.delegate = self
        // Remove what's still scheduled when machen quits, so nothing outdated fires while it's
        // closed (macOS would deliver it without asking machen). Launching schedules them again.
        // Removing everything is fine: machen schedules nothing but reminders, and quitting can't
        // wait for the asynchronous list of pending ones.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.callCategory, actions: [join], intentIdentifiers: []),
        ])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Asks macOS for permission (it only shows the prompt the first time). The answer may take
    /// as long as the user does, so callers asking meanwhile share one request.
    func requestAuthorization() async -> Bool {
        if let authorizationRequest { return await authorizationRequest.value }
        let center = center
        let request = Task { (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
        authorizationRequest = request
        defer { authorizationRequest = nil }
        return await request.value
    }

    /// Makes machen's pending reminders match `reminders` (the soonest `maximumScheduled`):
    /// removes the ones no longer wanted and adds only new or changed ones.
    func schedule(_ reminders: [ReminderNotification]) async {
        let wanted = Array(reminders.prefix(ReminderNotification.maximumScheduled))
        let wantedIDs = Set(wanted.map(\.id))
        let stale = await pendingReminderIDs().filter { !wantedIDs.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        scheduled = scheduled.filter { wantedIDs.contains($0.key) }
        for reminder in wanted where scheduled[reminder.id] != reminder {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.threadIdentifier = "events"
            if let url = reminder.meetingURL {
                content.categoryIdentifier = Self.callCategory
                content.userInfo = [Self.meetingKey: url.absoluteString]
            }
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
            // The id includes the start time, so a moved event gets a new request; adding with an
            // existing id replaces it, which picks up an edited title or place
            do {
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content,
                                                           trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
                scheduled[reminder.id] = reminder
            } catch {
                scheduled[reminder.id] = nil
            }
        }
    }

    func removeAll() async {
        scheduled = [:]
        center.removePendingNotificationRequests(withIdentifiers: await pendingReminderIDs())
    }

    private func pendingReminderIDs() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(ReminderNotification.idPrefix) }
    }

    // Show notifications even while machen is the active app (it's a menu bar app, so it often is)
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.joinAction,
           let link = response.notification.request.content.userInfo[Self.meetingKey] as? String,
           let url = URL(string: link) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
