import Foundation

/// A readiness snapshot, not a claim that every word will be converted.
struct AutoCorrectionStatus {
    var masterEnabled = true
    var enabled = true
    var accessibility = true
    var keyboard = true
    var secureInput = false
    var excludedApp: String?
    var remoteClient = false
    var triggers: [String] = []
    var warmedUp = false
    var languagesKnown = false
    var missingDictionary: String?
    var editorNotice: String?

    var message: String {
        if !masterEnabled { return taskText("NormalSwitcher is paused", "NormalSwitcher приостановлен") }
        if !enabled { return taskText("Automatic correction is off", "Автоисправление выключено") }
        if !accessibility { return taskText("Allow Accessibility access", "Нужен Универсальный доступ") }
        if !keyboard { return taskText("Keyboard monitoring is unavailable", "Обработчик клавиатуры недоступен") }
        if secureInput { return taskText("Paused: secure input", "Пауза: защищённый ввод") }
        if let excludedApp { return taskText("Excluded app: \(excludedApp)", "Исключение: \(excludedApp)") }
        if remoteClient { return taskText("Handled by the remote Mac", "Обрабатывается на удалённом Mac") }
        if triggers.isEmpty { return taskText("Choose Space, Enter or Tab in Settings", "Выберите пробел, Enter или Tab в настройках") }
        if !warmedUp { return taskText("Preparing dictionaries…", "Подготовка словарей…") }
        if !languagesKnown { return taskText("Check the layout pair in Settings", "Проверьте пару раскладок в настройках") }
        if let missingDictionary { return taskText("No dictionary: \(missingDictionary)", "Нет словаря: \(missingDictionary)") }
        if let editorNotice { return editorNotice }
        let keys = triggers.joined(separator: " · ")
        return taskText("Checks words after: \(keys)", "Проверяет слова после: \(keys)")
    }
}
