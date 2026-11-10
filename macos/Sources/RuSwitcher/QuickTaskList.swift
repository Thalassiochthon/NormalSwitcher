import SwiftUI

struct QuickTaskList: View {
    @ObservedObject var model: QuickTasks
    @State private var completed = false
    @State private var query = ""
    @State private var selection: UUID?
    @State private var editing: QuickTask?
    @State private var editingIsNew = false

    private var visibleTasks: [QuickTask] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.tasks.filter {
            $0.completed == completed && (search.isEmpty ||
                $0.title.localizedStandardContains(search) || $0.text.localizedStandardContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker(taskText("Status", "Статус"), selection: $completed) {
                    Text(taskText("Active", "Активные")).tag(false)
                    Text(taskText("Completed", "Выполненные")).tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Spacer()
                Button {
                    editingIsNew = true
                    editing = QuickTask(text: "")
                } label: {
                    Label(taskText("New Task", "Новая задача"), systemImage: "plus")
                }
            }
            TextField(taskText("Search tasks", "Поиск по задачам"), text: $query)
            if let message = model.errorMessage {
                HStack(alignment: .top) {
                    Text(message).font(.caption).foregroundStyle(.red)
                    Button(taskText("Retry", "Повторить")) { model.reload() }
                }
            }
            List(visibleTasks, selection: $selection) { task in
                HStack {
                    Button {
                        model.setCompleted(task.id, to: !task.completed)
                    } label: {
                        Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(task.completed ? taskText("Reopen", "Вернуть в активные") :
                        taskText("Complete", "Завершить"))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).lineLimit(1)
                        if task.text != task.title, !task.text.isEmpty {
                            Text(String(task.text.prefix(160)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        editingIsNew = false
                        editing = task
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(taskText("Open task", "Открыть задачу"))
                }
                .tag(task.id)
            }
            .overlay {
                if visibleTasks.isEmpty && model.errorMessage == nil {
                    Text(query.isEmpty ? taskText("No tasks here yet", "Здесь пока нет задач") :
                        taskText("No matching tasks", "Ничего не найдено"))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(14)
        .sheet(item: $editing) { task in
            QuickTaskEditor(task: task, isNew: editingIsNew, model: model) { saved in
                if let saved {
                    completed = model.tasks.first(where: { $0.id == saved.id })?.completed ?? saved.completed
                    query = ""
                    selection = saved.id
                }
                editing = nil
            }
        }
    }
}

private struct QuickTaskEditor: View {
    @State private var task: QuickTask
    private let original: QuickTask
    private let isNew: Bool
    @ObservedObject var model: QuickTasks
    let close: (QuickTask?) -> Void
    @State private var confirmDelete = false
    @State private var confirmDiscard = false

    init(task: QuickTask, isNew: Bool, model: QuickTasks, close: @escaping (QuickTask?) -> Void) {
        _task = State(initialValue: task)
        original = task
        self.isNew = isNew
        self.model = model
        self.close = close
    }

    private var isDirty: Bool { task.title != original.title || task.text != original.text }


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(taskText("Title", "Название"), text: $task.title)
            TextEditor(text: $task.text)
                .accessibilityLabel(taskText("Task text", "Текст задачи"))
                .frame(height: 150)
                .border(.secondary.opacity(0.3))
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
                Button(taskText("Reload saved tasks", "Обновить сохранённые задачи")) { model.reload() }
            }
            HStack {
                if model.tasks.contains(where: { $0.id == task.id }) {
                    Button(taskText("Delete", "Удалить"), role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button(L10n.commonCancel) {
                    if isDirty { confirmDiscard = true } else { close(nil) }
                }.keyboardShortcut(.cancelAction)
                Button(taskText("Save", "Сохранить")) {
                    task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isNew ? model.add(task) : model.edit(task) { close(task) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 420)
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog(taskText("Discard changes?", "Закрыть без сохранения?"),
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(taskText("Discard", "Не сохранять"), role: .destructive) { close(nil) }
            Button(taskText("Keep Editing", "Продолжить редактирование"), role: .cancel) {}
        }
        .confirmationDialog(taskText("Delete this task?", "Удалить эту задачу?"),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(taskText("Delete", "Удалить"), role: .destructive) {
                if model.delete(task.id) { close(nil) }
            }
        }
    }
}
