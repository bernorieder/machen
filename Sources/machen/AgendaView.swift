import SwiftUI

struct AgendaView: View {
    @EnvironmentObject private var store: Store
    @Binding var route: Route

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let message = store.errorMessage {
                        ErrorBanner(message: message) { store.errorMessage = nil }
                            .padding(.bottom, 6)
                    }

                    SectionHeader(title: "Events", count: store.shownEventCount, addHelp: "New event",
                                  onAdd: { if let draft = store.newEventDraft() { route = .event(draft) } },
                                  mode: Store.eventDaysLabel(store.eventDays),
                                  titleHelp: "Click to show: \(Store.eventDaysLabel(store.nextEventDays))",
                                  onTitleTap: { store.eventDays = store.nextEventDays })
                    ForEach(store.eventsByDay) { group in
                        // A single day needs no day heading; the header already names it.
                        if store.eventDays > 1 {
                            GroupHeader(title: Self.dayLabel(group.day), color: nil, addHelp: "New event on this day") {
                                if let draft = store.newEventDraft(on: group.day) { route = .event(draft) }
                            }
                        }
                        if group.events.isEmpty {
                            EmptyRow(text: store.isLoading ? "Loading…" : "No events")
                        }
                        ForEach(group.events) { event in
                            EventRow(event: event,
                                     startsHere: store.multiDayMode == .todayAndStart && group.isStartDay(of: event)) {
                                open(event)
                            }
                        }
                    }

                    SectionHeader(title: "Tasks", count: store.shownTaskCount, addHelp: "New task",
                                  onAdd: { if let draft = store.newTaskDraft() { route = .task(draft) } },
                                  mode: store.taskFilter.label,
                                  titleHelp: "Click to show: \(store.taskFilter.next.label)",
                                  onTitleTap: { store.taskFilter = store.taskFilter.next })
                    .padding(.top, 10)
                    if store.taskGroups.isEmpty {
                        EmptyRow(text: store.isLoading ? "Loading…"
                                 : store.taskFilter == .dueOnly ? "No open tasks with a due date" : "No open tasks")
                    }
                    ForEach(store.taskGroups) { group in
                        if store.showsListNames {
                            GroupHeader(title: group.list.title, color: group.color, addHelp: "New task in \(group.list.title)") {
                                route = .task(TaskDraft(listID: group.list.id, day: store.day))
                            }
                        }
                        ForEach(group.tasks) { task in
                            TaskRow(task: task, color: group.color) {
                                route = .task(TaskDraft(task))
                            }
                        }
                    }
                }
                .padding(8)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        // Same grey as the section headings below, one size up.
        HStack {
            Text("machen")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Group {
                if store.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                }
            }
            .frame(width: 14)
            if let lastSync = store.lastSync {
                Text("Synced \(lastSync.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            Button { route = .settings } label: { Image(systemName: "gearshape") }
                .padding(.trailing, 6)
                .buttonStyle(.borderless)
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit machen")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func open(_ event: CalendarEvent) {
        if event.canEdit {
            route = .event(EventDraft(event))
        } else if let link = event.link {
            NSWorkspace.shared.open(link)
        }
    }
}

// MARK: - Rows

struct EventRow: View {
    @Environment(\.rowDensity) private var density
    let event: CalendarEvent
    /// Marks the start-day appearance of a multi-day event that is shown only once.
    var startsHere = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: density.lineGap) {
                Text(event.title)
                    .strikethrough(event.declined)
                    .lineLimit(2)
                Text(timeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !event.location.isEmpty {
                    Text(event.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: event.color) ?? .accentColor)
                    .frame(width: 4)
            }
        }
        .buttonStyle(RowButtonStyle())
        .opacity(event.end < Date() || event.declined ? 0.5 : 1)
        .help(event.canEdit ? "Edit event" : "Read-only calendar – opens in Google Calendar")
    }

    private var timeText: String {
        startsHere ? "Starts · " + spanText : spanText
    }

    private var spanText: String {
        if event.isAllDay {
            let days = Calendar.current.dateComponents([.day], from: event.start, to: event.end).day ?? 1
            return days > 1 ? "All day · \(days) days" : "All day"
        }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: Calendar.current.isDate(event.start, inSameDayAs: event.end) ? .omitted : .abbreviated,
                                      time: .shortened)
        return "\(start) – \(end)"
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: Store
    @Environment(\.rowDensity) private var density
    let task: TaskItem
    let color: Color
    let action: () -> Void
    @ViewState private var checked = false

    var body: some View {
        let sub = task.isSubtask
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button {
                checked = true
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    await store.complete(listID: task.listID, taskID: task.taskID)
                }
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: sub ? 12 : 14))
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(sub ? "Mark completed" : "Mark completed (with its subtasks)")

            Button(action: action) {
                VStack(alignment: .leading, spacing: density.lineGap) {
                    Text(task.title.isEmpty ? "(No title)" : task.title)
                        .font(sub ? .subheadline : .body)
                        .strikethrough(checked)
                        .lineLimit(2)
                    if !task.notes.isEmpty {
                        Text(task.notes)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let due = task.due {
                        let label = Self.dueLabel(due)
                        Text(label.text).foregroundStyle(label.color)
                    }
                }
                .font(sub ? .caption2 : .caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit task")
        }
        .padding(.leading, sub ? 28 : 10)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(sub ? 0.5 : 1))
                .frame(width: 4)
        }
        .modifier(RowChrome())
    }

    static func dueLabel(_ due: Date) -> (text: String, color: Color) {
        let cal = Calendar.current
        let today = Date().startOfDay
        if due < today {
            return ("Overdue · \(due.formatted(.dateTime.month(.abbreviated).day()))", .red)
        }
        if cal.isDateInToday(due) { return ("Today", .orange) }
        if cal.isDateInTomorrow(due) { return ("Tomorrow", .secondary) }
        let sameYear = cal.component(.year, from: due) == cal.component(.year, from: today)
        let format: Date.FormatStyle = sameYear
            ? .dateTime.weekday(.abbreviated).month(.abbreviated).day()
            : .dateTime.month(.abbreviated).day().year()
        return (due.formatted(format), .secondary)
    }
}

// MARK: - Small pieces

struct SectionHeader: View {
    let title: String
    let count: Int
    let addHelp: String
    let onAdd: () -> Void
    /// When set, the title becomes a button showing this mode; clicking it calls `onTitleTap`.
    var mode: String? = nil
    var titleHelp = ""
    var onTitleTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let onTitleTap {
                Button(action: onTitleTap) { titleLabel.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(titleHelp)
            } else {
                titleLabel
            }
            Spacer()
            Button(action: onAdd) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help(addHelp)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var titleLabel: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
            if count > 0 {
                Text("\(count)")
                    .font(.caption2)
            }
            if let mode {
                Text("· \(mode)")
                    .font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
    }
}

struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }
}

/// Sub-header for a day of events or a task list, with its own add button.
struct GroupHeader: View {
    let title: String
    let color: Color?
    let addHelp: String
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: onAdd) { Image(systemName: "plus").font(.caption) }
                .buttonStyle(.borderless)
                .help(addHelp)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(RowChrome(pressed: configuration.isPressed))
    }
}

/// Shared row padding and hover highlight.
struct RowChrome: ViewModifier {
    let pressed: Bool
    @Environment(\.rowDensity) private var density
    @ViewState private var hovering = false

    init(pressed: Bool = false) {
        self.pressed = pressed
    }

    func body(content: Content) -> some View {
        content
            .lineSpacing(density.lineSpacing)
            .padding(.vertical, density.rowPadding)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(pressed ? 0.12 : hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
