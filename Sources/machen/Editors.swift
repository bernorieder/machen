import SwiftUI

struct EditorHeader: View {
    let title: String
    let canSave: Bool
    let saving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
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

/// Inline confirmation (alerts and dialogs tend to dismiss menu bar windows).
struct DeleteRow: View {
    let label: String
    let onDelete: () -> Void
    @ViewState private var confirming = false

    var body: some View {
        if confirming {
            HStack {
                Text("Delete permanently?")
                Spacer()
                Button("Cancel") { confirming = false }
                Button("Delete", role: .destructive, action: onDelete)
            }
        } else {
            Button(label, role: .destructive) { confirming = true }
        }
    }
}

struct EventEditor: View {
    @EnvironmentObject private var store: Store
    @ViewState private var draft: EventDraft
    @ViewState private var saving = false
    @ViewState private var error: String?
    let onClose: () -> Void

    init(draft: EventDraft, onClose: @escaping () -> Void) {
        _draft = ViewState(wrappedValue: draft)
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(title: draft.isNew ? "New Event" : "Edit Event",
                         canSave: !draft.title.trimmingCharacters(in: .whitespaces).isEmpty,
                         saving: saving, onCancel: onClose, onSave: save)
            Divider()
            Form {
                Section {
                    TextField("Title", text: $draft.title, prompt: Text("Event title"))
                    Picker("Calendar", selection: $draft.calendarID) {
                        ForEach(store.writableCalendars) { cal in
                            Text(cal.name).tag(cal.id)
                        }
                    }
                    .disabled(!draft.isNew)
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
                        DeleteRow(label: "Delete Event", onDelete: delete)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: draft.isAllDay) { _, allDay in
            guard !allDay else { return }
            // Coming from all-day, give the event a sensible time slot.
            if draft.start == draft.start.startOfDay {
                draft.start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: draft.start) ?? draft.start
            }
            if draft.end <= draft.start {
                draft.end = draft.start.addingTimeInterval(3600)
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
                try await store.save(draft)
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
                try await store.deleteEvent(draft)
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
                        .lineLimit(3...8)
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
                if let taskID = draft.taskID {
                    Section {
                        Button(draft.isSubtask ? "Mark Completed" : "Mark Completed (with Subtasks)") {
                            Task {
                                await store.complete(listID: draft.listID, taskID: taskID)
                                onClose()
                            }
                        }
                        DeleteRow(label: "Delete Task", onDelete: delete)
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
