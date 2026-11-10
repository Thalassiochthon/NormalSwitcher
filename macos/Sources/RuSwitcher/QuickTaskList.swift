import SwiftUI

struct QuickTaskList: View {
    @ObservedObject var model: QuickTasks
    @State private var completed = false
    @State private var query = ""
    @State private var selection: UUID?
    @State private var editing: QuickTask?

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
                    editing = QuickTask(text: "")
                } label: {
                    Label(taskText("New Task", "Новая задача"), systemImage: "plus")
                }
            }
            TextField(taskText("Search tasks", "Поиск по задачам"), text: $query)
            if model.storageError {
                Text(taskText("Could not read or save tasks. Check storage and Keychain access.",
                              "Не удалось прочитать или сохранить задачи. Проверьте доступ к хранилищу и Связке ключей."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            List(visibleTasks, selection: $selection) { task in
                HStack {
                    Button {
                        var updated = task
                        updated.completed.toggle()
                        model.update(updated)
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
                if visibleTasks.isEmpty {
                    Text(query.isEmpty ? taskText("No tasks here yet", "Здесь пока нет задач") :
                        taskText("No matching tasks", "Ничего не найдено"))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(14)
        .sheet(item: $editing) { task in
            QuickTaskEditor(task: task, model: model) { saved in
                if let saved {
                    completed = saved.completed
                    query = ""
                    selection = saved.id
                }
                editing = nil
            }
        }
    }
}

private struct QuickTaskEditor: View {
    @State var task: QuickTask
    @ObservedObject var model: QuickTasks
    let close: (QuickTask?) -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(taskText("Title", "Название"), text: $task.title)
            TextEditor(text: $task.text)
                .accessibilityLabel(taskText("Task text", "Текст задачи"))
                .frame(height: 150)
                .border(.secondary.opacity(0.3))
            if model.storageError {
                Text(taskText("Could not save changes", "Не удалось сохранить изменения"))
                    .foregroundStyle(.red)
            }
            HStack {
                if model.tasks.contains(where: { $0.id == task.id }) {
                    Button(taskText("Delete", "Удалить"), role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button(L10n.commonCancel) { close(nil) }.keyboardShortcut(.cancelAction)
                Button(taskText("Save", "Сохранить")) {
                    task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if model.update(task) { close(task) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 420)
        .confirmationDialog(taskText("Delete this task?", "Удалить эту задачу?"),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(taskText("Delete", "Удалить"), role: .destructive) {
                if model.delete(task.id) { close(nil) }
            }
        }
    }
}
