import SwiftUI

struct EditorHeader: View {
    let title: String
    let canSave: Bool
    let saving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack {
            // Locked while saving, so a save that finishes later can't close whatever was opened next
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
            Spacer()
            Text(title).font(.headline)
            Spacer()
            if saving { ProgressView().controlSize(.small) }
            Button("Save", action: onSave)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || saving)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Inline confirmation (alerts and dialogs tend to dismiss menu bar windows). Give it an `.id`
/// that changes with what it deletes, so a pending confirmation doesn't carry over.
struct DeleteRow: View {
    let label: String
    /// The question asked before deleting, naming what goes.
    let prompt: String
    var disabled = false
    let onDelete: () -> Void
    @ViewState private var confirming = false

    var body: some View {
        if confirming {
            HStack {
                Text(prompt)
                Spacer()
                Button("Cancel") { confirming = false }
                Button("Delete", role: .destructive, action: onDelete)
                    .disabled(disabled)
            }
        } else {
            Button(label, role: .destructive) { confirming = true }
                .disabled(disabled)
        }
    }
}

struct EventEditor: View {
    @EnvironmentObject private var store: Store
    @ViewState private var draft: EventDraft
    @ViewState private var saving = false
    @ViewState private var error: String?
    /// For an occurrence of a recurring event: change just it, or the whole series.
    @ViewState private var scope = EditScope.thisEvent
    let onClose: () -> Void

    init(draft: EventDraft, onClose: @escaping () -> Void) {
        _draft = ViewState(wrappedValue: draft)
        self.onClose = onClose
    }

    private var editsSeries: Bool { draft.isRecurring && scope == .allEvents }
    /// Google moves only whole series to another calendar, not single occurrences.
    private var canChangeCalendar: Bool { draft.isNew || !draft.isRecurring || editsSeries }

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(title: draft.isNew ? "New Event" : "Edit Event",
                         canSave: !draft.title.trimmingCharacters(in: .whitespaces).isEmpty,
                         saving: saving, onCancel: onClose, onSave: save)
            Divider()
            Form {
                if draft.isRecurring && !draft.isNew {
                    Section {
                        Picker("Apply changes to", selection: $scope) {
                            ForEach(EditScope.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(editsSeries
                             ? "Changes the whole series. A new time moves every event by the same amount; to move the series to other days, use Google Calendar."
                             : "This is a repeating event. Changes apply only to this one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Title", text: $draft.title, prompt: Text("Event title"))
                    Picker("Calendar", selection: $draft.calendarID) {
                        ForEach(store.writableCalendars) { cal in
                            Text(cal.name).tag(cal.id)
                        }
                    }
                    .disabled(!canChangeCalendar)
                    .help(canChangeCalendar ? "" : "To move a repeating event, choose All events: Google moves whole series only.")
                    if let url = draft.meetingURL {
                        LabeledContent("Video call") {
                            Button("Join") { NSWorkspace.shared.open(url) }
                                .help(url.absoluteString)
                        }
                    }
                }
                Section {
                    Toggle("All day", isOn: $draft.isAllDay)
                    DatePicker("Starts", selection: startBinding, displayedComponents: components)
                        .datePickerStyle(.field)
                    DatePicker("Ends", selection: $draft.end,
                               in: (draft.isAllDay ? draft.start.startOfDay : draft.start)...,
                               displayedComponents: components)
                        .datePickerStyle(.field)
                }
                Section {
                    TextField("Location", text: $draft.location, prompt: Text("Optional"))
                    TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(3...6)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
                if !draft.isNew {
                    Section {
                        DeleteRow(label: editsSeries ? "Delete All Events" : "Delete Event",
                                  prompt: editsSeries ? "Delete every event in this series?" : "Delete this event?",
                                  disabled: saving, onDelete: delete)
                            .id(scope)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: scope) { _, newScope in
            // A single occurrence can't change calendar, so undo a pending move
            if newScope == .thisEvent, let original = draft.originalCalendarID {
                draft.calendarID = original
            }
        }
        .onChange(of: draft.isAllDay) { _, allDay in
            // An all-day event's end is its last day; a timed event's end is the exact time it ends
            if allDay {
                // 22:00 to midnight stays on its first day
                draft.end = max(draft.start.startOfDay, draft.end.addingTimeInterval(-1).startOfDay)
            } else {
                // Give it a sensible slot: 9:00 on the first day, one hour, ending on the last day
                if draft.start == draft.start.startOfDay {
                    draft.start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: draft.start) ?? draft.start
                }
                let timeOfDay = draft.start.timeIntervalSince(draft.start.startOfDay)
                draft.end = draft.end.startOfDay.addingTimeInterval(timeOfDay + 3600)
            }
        }
    }

    private var components: DatePickerComponents {
        draft.isAllDay ? [.date] : [.date, .hourAndMinute]
    }

    /// Moving the start keeps the event's duration.
    private var startBinding: Binding<Date> {
        Binding {
            draft.start
        } set: { newValue in
            let delta = newValue.timeIntervalSince(draft.start)
            draft.start = newValue
            draft.end = draft.end.addingTimeInterval(delta)
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                try await store.save(draft, scope: editsSeries ? .allEvents : .thisEvent)
                onClose()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    private func delete() {
        saving = true
        Task {
            do {
                try await store.deleteEvent(draft, scope: editsSeries ? .allEvents : .thisEvent)
                onClose()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

struct TaskEditor: View {
    @EnvironmentObject private var store: Store
    @ViewState private var draft: TaskDraft
    @ViewState private var saving = false
    @ViewState private var error: String?
    private let original: TaskDraft
    let onClose: () -> Void
    /// Switches the popover to another task editor (used for "Add Subtask").
    let onOpen: (TaskDraft) -> Void

    init(draft: TaskDraft, onClose: @escaping () -> Void, onOpen: @escaping (TaskDraft) -> Void) {
        _draft = ViewState(wrappedValue: draft)
        original = draft
        self.onClose = onClose
        self.onOpen = onOpen
    }

    private var title: String {
        if draft.isSubtask { return draft.isNew ? "New Subtask" : "Edit Subtask" }
        return draft.isNew ? "New Task" : "Edit Task"
    }

    private var hasSubtasks: Bool {
        draft.taskID.map { id in store.tasks.contains { $0.listID == draft.listID && $0.parentID == id } } ?? false
    }

    private var parentTitle: String {
        let parent = store.tasks.first { $0.listID == draft.listID && $0.taskID == draft.parentID }
        return parent.map { $0.title.isEmpty ? "(No title)" : $0.title } ?? "Another task"
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(title: title,
                         canSave: !draft.title.trimmingCharacters(in: .whitespaces).isEmpty,
                         saving: saving, onCancel: onClose, onSave: save)
            Divider()
            Form {
                Section {
                    TextField("Title", text: $draft.title, prompt: Text(draft.isSubtask ? "Subtask title" : "Task title"))
                    if draft.isSubtask {
                        LabeledContent("Subtask of", value: parentTitle)
                    } else {
                        Picker("List", selection: $draft.listID) {
                            ForEach(store.taskLists) { list in
                                Text(list.title).tag(list.id)
                            }
                        }
                        .disabled(!draft.isNew)
                    }
                }
                Section {
                    Toggle("Due date", isOn: $draft.hasDue)
                    if draft.hasDue {
                        DatePicker("Due", selection: $draft.due, displayedComponents: [.date])
                            .datePickerStyle(.field)
                    }
                }
                Section {
                    TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(3...6)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
                if !draft.isNew && !draft.isSubtask {
                    Section {
                        Button(action: addSubtask) { Label("Add Subtask", systemImage: "plus") }
                            .disabled(saving)
                    }
                }
                if !draft.isNew {
                    Section {
                        Button(hasSubtasks ? "Mark Completed (with Subtasks)" : "Mark Completed", action: complete)
                            .disabled(saving)
                        DeleteRow(label: "Delete Task",
                                  prompt: hasSubtasks ? "Delete this task and its subtasks?" : "Delete this task?",
                                  disabled: saving, onDelete: delete)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                try await store.save(draft)
                onClose()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    /// Saves pending edits first, so they aren't lost, then completes the task.
    private func complete() {
        guard let taskID = draft.taskID else { return }
        saving = true
        error = nil
        Task {
            do {
                if draft != original { try await store.save(draft) }
                await store.complete(listID: draft.listID, taskID: taskID)
                onClose()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    /// Saves pending edits to the parent first, so they aren't lost when the editor switches.
    private func addSubtask() {
        guard let taskID = draft.taskID else { return }
        let subtask = TaskDraft(subtaskOf: taskID, listID: draft.listID)
        guard draft != original else { return onOpen(subtask) }
        saving = true
        error = nil
        Task {
            do {
                try await store.save(draft)
                onOpen(subtask)
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    private func delete() {
        saving = true
        Task {
            do {
                try await store.deleteTask(draft)
                onClose()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
