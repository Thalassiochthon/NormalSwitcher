import SwiftUI

enum QuickTaskEditingSession: Identifiable {
    case new(QuickTask)
    case existing(QuickTask)

    var id: UUID { task.id }

    var task: QuickTask {
        switch self {
        case .new(let task), .existing(let task): task
        }
    }

    @MainActor func save(_ draft: QuickTask, in model: QuickTasks) -> Bool {
        switch self {
        case .new: model.add(draft)
        case .existing: model.edit(draft)
        }
    }
}

struct QuickTaskList: View {
    @ObservedObject var model: QuickTasks
    @State private var completed = false
    @State private var query = ""
    @State private var selection: UUID?
    @State private var editing: QuickTaskEditingSession?

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
                    editing = .new(QuickTask(text: ""))
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
                    Button {
                        open(task)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).lineLimit(1)
                            if !task.detailPreview.isEmpty {
                                Text(task.detailPreview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(taskText("Open task", "Открыть задачу"))
                }
                .tag(task.id)
            }
            .overlay {
                if visibleTasks.isEmpty && model.errorMessage == nil {
                    VStack(spacing: 6) {
                        Text(query.isEmpty ? (completed ? taskText("No completed tasks", "Нет выполненных задач") :
                            taskText("No tasks yet", "Пока нет задач")) : taskText("No matching tasks", "Ничего не найдено"))
                        if query.isEmpty && !completed {
                            Text(taskText("Copy text, then choose Add to Tasks in clipboard history. Or create a new task here.",
                                          "Скопируйте текст и нажмите «В задачи» в истории буфера. Или создайте новую задачу здесь."))
                                .font(.caption).multilineTextAlignment(.center).frame(maxWidth: 300)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                }
            }
            HStack {
                Text(taskText("Click a task to edit", "Нажмите на задачу, чтобы изменить её"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(taskText("Open", "Открыть")) {
                    if let task = visibleTasks.first(where: { $0.id == selection }) { open(task) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!visibleTasks.contains(where: { $0.id == selection }))
            }
        }
        .padding(14)
        .sheet(item: $editing) { session in
            QuickTaskEditor(session: session, model: model) { saved in
                if let saved {
                    completed = model.tasks.first(where: { $0.id == saved.id })?.completed ?? saved.completed
                    query = ""
                    selection = saved.id
                }
                editing = nil
            }
        }
    }

    private func open(_ task: QuickTask) {
        selection = task.id
        editing = .existing(task)
    }
}

private struct QuickTaskEditor: View {
    @State private var task: QuickTask
    private let original: QuickTask
    private let session: QuickTaskEditingSession
    @ObservedObject var model: QuickTasks
    let close: (QuickTask?) -> Void
    @State private var confirmDelete = false
    @State private var confirmDiscard = false

    init(session: QuickTaskEditingSession, model: QuickTasks, close: @escaping (QuickTask?) -> Void) {
        _task = State(initialValue: session.task)
        original = session.task
        self.session = session
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
                    if session.save(task, in: model) { close(task) }
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
