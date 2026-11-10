import Testing
@testable import RuSwitcher

@Suite @MainActor
struct AutoCorrectionStatusTests {
    @Test func disabledDoesNotAskForPermissions() {
        var state = AutoCorrectionStatus()
        state.enabled = false
        state.accessibility = false
        state.keyboard = false
        #expect(state.message == taskText("Automatic correction is off", "Автоисправление выключено"))
    }

    @Test func runningChecksTriggersAndDictionaryReadiness() {
        var state = AutoCorrectionStatus()
        #expect(state.message == taskText("Choose Space, Enter or Tab in Settings", "Выберите пробел, Enter или Tab в настройках"))
        state.triggers = ["Enter"]
        #expect(state.message == taskText("Preparing dictionaries…", "Подготовка словарей…"))
        state.warmedUp = true
        #expect(state.message == taskText("Check the layout pair in Settings", "Проверьте пару раскладок в настройках"))
        state.languagesKnown = true
        state.missingDictionary = "ES"
        #expect(state.message == taskText("No dictionary: ES", "Нет словаря: ES"))
        state.missingDictionary = nil
        #expect(state.message == taskText("Checks words after: Enter", "Проверяет слова после: Enter"))
    }

    @Test func showsImmediateBlockerBeforeReadiness() {
        var state = AutoCorrectionStatus()
        state.excludedApp = "Text Editor"
        state.secureInput = true
        #expect(state.message == taskText("Paused: secure input", "Пауза: защищённый ввод"))
        state.secureInput = false
        #expect(state.message == taskText("Excluded app: Text Editor", "Исключение: Text Editor"))
        state.keyboard = false
        #expect(state.message == taskText("Keyboard monitoring is unavailable", "Обработчик клавиатуры недоступен"))
        state.accessibility = false
        #expect(state.message == taskText("Allow Accessibility access", "Нужен Универсальный доступ"))
    }
}
