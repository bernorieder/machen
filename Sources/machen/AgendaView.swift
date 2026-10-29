import SwiftUI

struct AgendaView: View {
    @EnvironmentObject private var store: Store
    @Binding var route: Route

    var body: some View {
        // Computed once per update: these are derived from all loaded events and tasks
        let days = store.eventsByDay
        let groups = store.taskGroups
        let listNames = store.showsListNames
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.List.stackGap) {
                    if let message = store.errorMessage {
                        ErrorBanner(message: message) { store.errorMessage = nil }
                            .padding(.bottom, Layout.ErrorBanner.bottomSpace)
                    }

                    SectionHeader(title: "Events", count: Set(days.flatMap { $0.events.map(\.id) }).count,
                                  addHelp: "New event", addDisabled: store.newEventDraft() == nil,
                                  adds: [AddAction(title: "New Event") {
                                      if let draft = store.newEventDraft() { route = .event(draft) }
                                  }],
                                  mode: Store.eventDaysLabel(store.eventDays),
                                  titleHelp: "Click to show: \(Store.eventDaysLabel(store.nextEventDays))",
                                  onTitleTap: { store.eventDays = store.nextEventDays })
                    ForEach(days) { group in
                        // A single day needs no day heading; the header already names it.
                        if store.eventDays > 1 {
                            GroupHeader(title: Self.dayLabel(group.day), color: nil, addHelp: "New event on this day",
                                        addDisabled: store.newEventDraft() == nil) {
                                if let draft = store.newEventDraft(on: group.day) { route = .event(draft) }
                            }
                        }
                        if group.events.isEmpty {
                            EmptyRow(text: store.isLoaded(group.day) ? "No events" : "Loading…")
                        }
                        ForEach(group.events) { event in
                            EventRow(event: event,
                                     startsHere: store.multiDayMode == .todayAndStart && group.isStartDay(of: event)) {
                                open(event)
                            }
                        }
                    }

                    Divider()
                        .padding(.top, Layout.SectionHeading.spaceAboveDivider)
                        .padding(.horizontal, Layout.SectionHeading.horizontalPadding)
                    SectionHeader(title: "Tasks", count: groups.reduce(0) { $0 + $1.tasks.count },
                                  addHelp: "New task or list", addDisabled: store.newTaskDraft() == nil,
                                  adds: [AddAction(title: "New Task") {
                                      if let draft = store.newTaskDraft() { route = .task(draft) }
                                  }, AddAction(title: "New List…") {
                                      if let id = store.defaultTaskListAccountID { route = .newTaskList(accountID: id) }
                                  }],
                                  mode: store.taskFilter.label,
                                  titleHelp: "Click to show: \(store.taskFilter.next.label)",
                                  onTitleTap: { store.taskFilter = store.taskFilter.next })
                    if groups.isEmpty {
                        EmptyRow(text: store.lastSync == nil ? "Loading…"
                                 : store.taskFilter == .dueOnly ? "No open tasks with a due date" : "No open tasks")
                    }
                    ForEach(groups) { group in
                        if listNames {
                            GroupHeader(title: group.title, color: group.color, addHelp: "New task in \(group.title)",
                                        onAdd: { route = .task(TaskDraft(listID: group.list.id, day: store.day)) },
                                        isCollapsed: group.isCollapsed,
                                        hiddenCount: group.tasks.count,
                                        onToggle: { withAnimation(.easeOut(duration: 0.15)) { store.toggleCollapsed(group.list) } })
                        }
                        ForEach(group.visibleTasks) { task in
                            TaskRow(task: task, color: group.color,
                                    action: { route = .task(TaskDraft(task)) },
                                    subtaskCount: task.isSubtask ? 0 : group.subtaskCounts[task.taskID] ?? 0,
                                    subtasksCollapsed: store.subtasksCollapsed(task),
                                    onToggleSubtasks: { withAnimation(.easeOut(duration: 0.15)) { store.toggleSubtasks(task) } })
                        }
                    }
                }
                .padding(Layout.List.inset)
            }
            .safeAreaInset(edge: .bottom) {
                if let completed = store.recentlyCompleted {
                    UndoBanner(completed: completed) { Task { await store.undoComplete() } }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.recentlyCompleted)
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: Layout.Footer.itemGap) {
            Group {
                if store.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                        .accessibilityLabel("Refresh")
                }
            }
            .frame(width: 14)
            if let lastSync = store.lastSync {
                Text("Synced \(Self.syncedText(lastSync))")
            }
            Spacer()
            Button { route = .settings } label: { Image(systemName: "gearshape") }
                .padding(.trailing, Layout.Footer.itemGap)
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit machen")
                .accessibilityLabel("Quit machen")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Layout.Footer.horizontalPadding)
        .padding(.vertical, Layout.Footer.verticalPadding)
    }

    /// "14:32" today; with the date when the shown data is older, for example when offline.
    static func syncedText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
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
    @Environment(\.textSizes) private var sizes
    let event: CalendarEvent
    /// Marks the start-day appearance of a multi-day event that is shown only once.
    var startsHere = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: density.lineGap) {
                    Text(event.displayTitle)
                        .font(sizes.name.font(Layout.Text.itemName))
                        .strikethrough(event.declined)
                        .lineLimit(2)
                    Text(timeText)
                        .font(sizes.detail.font(Layout.Text.detail))
                        .foregroundStyle(.secondary)
                    if !event.location.isEmpty {
                        Text(event.location)
                            .font(sizes.detail.font(Layout.Text.detail))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(event.canEdit ? "Edit event" : "Read-only calendar – opens in Google Calendar")

            if let url = event.meetingURL, event.end > Date() {
                JoinButton(url: url, start: event.start, end: event.end)
            }
        }
        .padding(.leading, Layout.Bar.textInset)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Layout.Bar.cornerRadius)
                .fill(Color(hex: event.color) ?? .accentColor)
                .frame(width: Layout.Bar.width)
        }
        .modifier(RowChrome())
        .opacity(event.declined ? Layout.Row.declinedEventOpacity : 1)
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

/// Opens an event's video call. Greyed out until 5 minutes before the start, so it isn't clicked
/// by mistake hours ahead, then prominent until the end. The editor and the notification can
/// still join earlier.
struct JoinButton: View {
    let url: URL
    let start: Date
    let end: Date

    private var liveFrom: Date { start.addingTimeInterval(-5 * 60) }

    var body: some View {
        // Redraws only when it turns prominent and when the call ends. The schedule starts now,
        // since a first draw may otherwise get the first date ahead instead of the current one.
        let now = Date()
        TimelineView(.explicit([now] + [liveFrom, end].filter { $0 > now })) { context in
            let live = context.date >= liveFrom && context.date < end
            Button("Join") { NSWorkspace.shared.open(url) }
                .buttonStyle(JoinButtonStyle(live: live))
                .disabled(!live)
                .help(live ? "Join the video call (\(url.host ?? url.absoluteString))"
                           : "Available 5 minutes before the start")
        }
    }
}

/// A small capsule: accent-coloured while the call is on, greyed out otherwise. Drawn by hand so
/// it looks the same whether or not the popover is the active window.
struct JoinButtonStyle: ButtonStyle {
    let live: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(live ? Color.white : Color.primary.opacity(0.3))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(live ? Color.accentColor : Color.primary.opacity(0.05)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: Store
    @Environment(\.rowDensity) private var density
    @Environment(\.textSizes) private var sizes
    let task: TaskItem
    let color: Color
    let action: () -> Void
    /// For a parent task: how many subtasks it has, and whether they're hidden.
    var subtaskCount = 0
    var subtasksCollapsed = false
    var onToggleSubtasks: (() -> Void)? = nil
    @ViewState private var checked = false

    private var title: String { task.title.isEmpty ? "(No title)" : task.title }

    var body: some View {
        let sub = task.isSubtask
        HStack(alignment: .firstTextBaseline, spacing: Layout.Task.checkboxGap) {
            Button {
                // A quick second click would complete it twice
                guard !checked else { return }
                checked = true
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    await store.complete(listID: task.listID, taskID: task.taskID)
                }
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: sub ? sizes.detail.points(Layout.Text.subtaskCheckbox)
                                            : sizes.name.points(Layout.Text.taskCheckbox)))
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(subtaskCount > 0 ? "Mark completed, with its subtasks" : "Mark completed")
            .accessibilityLabel("Complete “\(title)”")

            Button(action: action) {
                VStack(alignment: .leading, spacing: density.lineGap) {
                    Text(title)
                        .font(sub ? sizes.detail.font(Layout.Text.subtaskName) : sizes.name.font(Layout.Text.itemName))
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
                .font(sizes.detail.font(Layout.Text.detail))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit task")

            if subtaskCount > 0, let onToggleSubtasks {
                Button(action: onToggleSubtasks) {
                    DisclosureLabel(count: subtaskCount, collapsed: subtasksCollapsed, size: sizes.detail)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Layout.Task.disclosurePadding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(subtasksCollapsed ? "Show subtasks" : "Hide subtasks")
                .accessibilityLabel(subtasksCollapsed ? "Show \(subtaskCount) subtasks" : "Hide \(subtaskCount) subtasks")
            }
        }
        .padding(.leading, sub ? Layout.Bar.subtaskInset : Layout.Bar.textInset)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Layout.Bar.cornerRadius)
                .fill(color.opacity(sub ? Layout.Bar.subtaskOpacity : 1))
                .frame(width: Layout.Bar.width)
        }
        // Subtasks sit close together and close to their parent
        .modifier(RowChrome(topScale: sub ? Layout.Row.subtaskTopShare : 1,
                            bottomScale: sub ? Layout.Row.subtaskBottomShare
                                : (subtaskCount > 0 && !subtasksCollapsed ? Layout.Row.openParentBottomShare : 1)))
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

/// Something a section's add button creates.
struct AddAction: Identifiable {
    /// As shown in the add button's menu, for example "New Event".
    let title: String
    let action: () -> Void

    var id: String { title }
}

/// The menu of an add button that offers several things. From AppKit, because SwiftUI's `Menu`
/// draws its button darker and further left than the other add buttons.
private enum AddMenu {
    static func show(_ adds: [AddAction]) {
        let menu = NSMenu()
        adds.forEach { menu.addItem(Item($0)) }
        // At the pointer, which is on the button
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private final class Item: NSMenuItem {
        private let run: () -> Void

        init(_ add: AddAction) {
            run = add.action
            super.init(title: add.title, action: #selector(choose), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError("Not used") }

        @objc private func choose() { run() }
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int
    let addHelp: String
    /// The add button does nothing yet, for example before anything has loaded.
    var addDisabled = false
    /// One is done right away; several are offered in a menu.
    let adds: [AddAction]
    /// Shown after the title, for example "· Today".
    var mode: String? = nil
    var titleHelp = ""
    /// When set, the title becomes a button.
    var onTitleTap: (() -> Void)? = nil
    @Environment(\.textSizes) private var sizes

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
            Button {
                if adds.count > 1 { AddMenu.show(adds) } else { adds.first?.action() }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(addDisabled)
            .help(addDisabled ? "Available once machen has loaded your data" : addHelp)
            .accessibilityLabel(addHelp)
        }
        .padding(.horizontal, Layout.SectionHeading.horizontalPadding)
        .padding(.top, Layout.SectionHeading.topPadding)
        .padding(.bottom, Layout.SectionHeading.bottomPadding)
    }

    private var titleLabel: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(sizes.heading.font(Layout.Text.heading, weight: .semibold))
            if count > 0 {
                Text("\(count)")
                    .font(sizes.heading.font(Layout.Text.heading))
            }
            if let mode {
                Text("· \(mode)")
                    .font(sizes.heading.font(Layout.Text.heading))
            }
        }
        .foregroundStyle(.secondary)
    }
}

struct EmptyRow: View {
    @Environment(\.textSizes) private var sizes
    let text: String

    var body: some View {
        Text(text)
            .font(sizes.name.font(Layout.Text.itemName))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Layout.EmptyRow.horizontalPadding)
            .padding(.vertical, Layout.EmptyRow.verticalPadding)
    }
}

/// "Completed … · Undo", shown for a few seconds after completing a task.
struct UndoBanner: View {
    let completed: CompletedTasks
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            // Only the title gets shortened; "and 2 subtasks" always stays visible
            HStack(spacing: 0) {
                Text(title).lineLimit(1).truncationMode(.tail)
                if let subtasks { Text(subtasks).lineLimit(1).fixedSize() }
            }
            Spacer(minLength: 4)
            Button("Undo", action: onUndo)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .fontWeight(.semibold)
                .keyboardShortcut("z", modifiers: .command)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        .padding(.horizontal, Layout.List.inset)
        .padding(.bottom, Layout.List.inset)
    }

    private var title: String {
        completed.title.isEmpty ? "Completed task" : "Completed “\(completed.title)”"
    }

    private var subtasks: String? {
        switch completed.taskIDs.count - 1 {
        case 0: nil
        case 1: " and 1 subtask"
        case let n: " and \(n) subtasks"
        }
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
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
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
    var addDisabled = false
    let onAdd: () -> Void
    /// When set, clicking the title collapses or expands the group, shown with a disclosure arrow.
    var isCollapsed: Bool? = nil
    /// Shown next to the arrow while collapsed.
    var hiddenCount = 0
    var onToggle: (() -> Void)? = nil
    @Environment(\.textSizes) private var sizes

    var body: some View {
        HStack(spacing: 6) {
            if let onToggle {
                Button(action: onToggle) { titleLabel.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(isCollapsed == true ? "Show tasks" : "Hide tasks")
            } else {
                titleLabel
            }
            Spacer()
            Button(action: onAdd) { Image(systemName: "plus").font(.caption) }
                .buttonStyle(.borderless)
                .disabled(addDisabled)
                .help(addHelp)
                .accessibilityLabel(addHelp)
        }
        .padding(.horizontal, Layout.GroupHeading.horizontalPadding)
        .padding(.top, Layout.GroupHeading.topPadding)
        .padding(.bottom, Layout.GroupHeading.bottomPadding)
    }

    private var titleLabel: some View {
        HStack(spacing: Layout.GroupHeading.dotGap) {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: Layout.GroupHeading.dotSize, height: Layout.GroupHeading.dotSize)
            }
            Text(title)
                .font(sizes.heading.font(Layout.Text.heading, weight: .medium))
                .lineLimit(1)
            if let isCollapsed {
                DisclosureLabel(count: isCollapsed ? hiddenCount : nil, collapsed: isCollapsed,
                                size: sizes.heading, base: Layout.Text.heading)
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// Arrow pointing right when collapsed and down when expanded, with an optional count before it.
struct DisclosureLabel: View {
    let count: Int?
    let collapsed: Bool
    var size = TextSize.medium
    /// Point size of the text it sits next to at Medium; the arrow is a bit smaller.
    var base = Layout.Text.detail

    var body: some View {
        HStack(spacing: Layout.Disclosure.countGap) {
            if let count, count > 0 {
                Text("\(count)").font(size.font(base))
            }
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: size.points(base * Layout.Disclosure.arrowShare), weight: .bold))
        }
    }
}

/// Shared row padding and hover highlight.
struct RowChrome: ViewModifier {
    /// Fractions of the spacing setting's row padding to use above and below; subtask rows,
    /// and parents with their subtasks showing, use less.
    let topScale: CGFloat
    let bottomScale: CGFloat
    @Environment(\.rowDensity) private var density
    @ViewState private var hovering = false

    init(topScale: CGFloat = 1, bottomScale: CGFloat = 1) {
        self.topScale = topScale
        self.bottomScale = bottomScale
    }

    func body(content: Content) -> some View {
        content
            .lineSpacing(density.lineSpacing)
            .padding(.top, density.rowPadding * topScale)
            .padding(.bottom, density.rowPadding * bottomScale)
            .padding(.horizontal, Layout.Row.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Layout.Row.hoverCornerRadius)
                    .fill(Color.primary.opacity(hovering ? Layout.Row.hoverOpacity : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
