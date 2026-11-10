using System.Globalization;

namespace RuSwitcher.Win.Core;

/// <summary>
/// UI localization — the Windows counterpart of the macOS <c>Localization</c>. Resolves the UI
/// language from the OS (CurrentUICulture), falling back to English for any missing key or language.
/// English and Russian are the shipped languages for the first beta; the table is structured so more
/// languages (matching the macOS 16) can be added without touching call sites.
/// </summary>
internal static class L10n
{
    private static readonly string Lang = Resolve();

    private static string Resolve()
    {
        try
        {
            string two = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName.ToLowerInvariant();
            return Table.ContainsKey(two) ? two : "en";
        }
        catch { return "en"; }
    }

    /// <summary>Localized string for <paramref name="key"/> (English fallback), then string.Format
    /// with any arguments.</summary>
    public static string T(string key, params object[] args)
    {
        string s = Lookup(Lang, key) ?? Lookup("en", key) ?? key;
        if (args.Length == 0) return s;
        try { return string.Format(s, args); }
        catch (FormatException) { return s; }   // a malformed translation must never crash the UI
    }

    private static string? Lookup(string lang, string key) =>
        Table.TryGetValue(lang, out var d) && d.TryGetValue(key, out var v) ? v : null;

    private static readonly Dictionary<string, Dictionary<string, string>> Table = new()
    {
        ["en"] = new()
        {
            ["app.name"] = "NormalSwitcher",
            ["tray.enable"] = "Enable NormalSwitcher",
            ["tray.auto"] = "Auto-convert as you type (beta)",
            ["tray.settings"] = "Settings…",
            ["tray.update"] = "Check for updates…",
            ["tray.quit"] = "Quit",
            ["trigger.ctrl"] = "Double-tap Ctrl",
            ["trigger.shift"] = "Double-tap Shift",
            ["trigger.pause"] = "Pause/Break key",
            ["settings.layout.auto"] = "Automatic",
            ["settings.layout.first"] = "First layout:",
            ["settings.layout.second"] = "Second layout:",
            ["settings.layout.hint"] = "Choose two different layouts to limit correction to that pair.",
            ["settings.tab.general"] = "General",
            ["settings.tab.hotkeys"] = "Shortcuts",
            ["settings.tab.automatic"] = "Auto-correction",
            ["settings.tab.clipboard"] = "Clipboard",
            ["clipboard.title"] = "Clipboard history…",
            ["clipboard.enable"] = "Enable clipboard history",
            ["clipboard.persist"] = "Keep history after restart (encrypted)",
            ["clipboard.shortcut"] = "Open clipboard history:",
            ["clipboard.hint"] = "Keeps the last 30 copied text items. Choose an item to paste it into the previous window.",
            ["clipboard.empty"] = "Copy some text to add it to the history.",
            ["clipboard.clear"] = "Clear history",
            ["clipboard.storageError"] = "Could not read or save clipboard history.",
            ["clipboard.hotkeyError"] = "This keyboard shortcut is already in use.",
            ["settings.tab.advanced"] = "Advanced",
            ["settings.tab.about"] = "About",
            ["settings.title"] = "NormalSwitcher — Settings",
            ["settings.credit"] = "Based on RuSwitcher",
            ["settings.trigger"] = "Correct layout:",
            ["settings.wholeline"] = "Convert the whole line (not just the last word)",
            ["settings.smart"] = "Smart selection conversion (keep correct words)",
            ["settings.auto"] = "Auto-convert as you type (beta)",
            ["settings.sound"] = "Play a sound on layout switch",
            ["settings.startup"] = "Launch at startup",
            ["settings.perapp"] = "Remember the layout per application",
            ["settings.updates"] = "Check for updates on launch",
            ["settings.switchhotkey"] = "Switch layout:",
            ["settings.off"] = "Off",
            ["settings.exceptions"] = "Exceptions…",
            ["settings.close"] = "Close",
            ["exc.title"] = "NormalSwitcher — Exceptions",
            ["exc.never"] = "Never convert (as typed):",
            ["exc.always"] = "Always convert (target form):",
            ["exc.save"] = "Save",
            ["exc.cancel"] = "Cancel",
            ["upd.available.title"] = "NormalSwitcher — Update available",
            ["upd.available.body"] = "A new version of NormalSwitcher is available: {0} (you have {1}).",
            ["upd.open"] = "Open the download page now?",
            ["upd.install"] = "Download and install this update now? NormalSwitcher will restart.",
            ["upd.install.error"] = "Could not download, verify, or start the installer. Open the release page?",
            ["upd.uptodate"] = "You're up to date (version {0}).",
            ["upd.error"] = "Could not check for updates (network error). Please try again later, or visit the site.",
        },
        ["ru"] = new()
        {
            ["app.name"] = "NormalSwitcher",
            ["tray.enable"] = "Включить NormalSwitcher",
            ["tray.auto"] = "Исправлять раскладку автоматически (бета)",
            ["tray.settings"] = "Настройки…",
            ["tray.update"] = "Проверить обновления…",
            ["tray.quit"] = "Выход",
            ["trigger.ctrl"] = "Двойной Ctrl",
            ["trigger.shift"] = "Двойной Shift",
            ["trigger.pause"] = "Клавиша Pause/Break",
            ["settings.layout.auto"] = "Автоматически",
            ["settings.layout.first"] = "Первая раскладка:",
            ["settings.layout.second"] = "Вторая раскладка:",
            ["settings.layout.hint"] = "Выберите две разные раскладки, чтобы исправление работало только внутри этой пары.",
            ["settings.tab.general"] = "Основные",
            ["settings.tab.hotkeys"] = "Сочетания",
            ["settings.tab.automatic"] = "Автоисправление",
            ["settings.tab.clipboard"] = "Буфер обмена",
            ["clipboard.title"] = "История буфера…",
            ["clipboard.enable"] = "Включить историю буфера обмена",
            ["clipboard.persist"] = "Хранить историю после перезапуска (с шифрованием)",
            ["clipboard.shortcut"] = "Открыть историю буфера:",
            ["clipboard.hint"] = "Хранит до 30 последних текстовых записей. Выберите запись, чтобы вставить её в предыдущее окно.",
            ["clipboard.empty"] = "Скопируйте текст, чтобы добавить его в историю.",
            ["clipboard.clear"] = "Очистить историю",
            ["clipboard.storageError"] = "Не удалось прочитать или сохранить историю буфера.",
            ["clipboard.hotkeyError"] = "Это сочетание клавиш уже занято.",
            ["settings.tab.advanced"] = "Дополнительно",
            ["settings.tab.about"] = "О программе",
            ["settings.title"] = "NormalSwitcher — Настройки",
            ["settings.credit"] = "Основано на RuSwitcher",
            ["settings.trigger"] = "Исправить раскладку:",
            ["settings.wholeline"] = "Конвертировать всю строку (не только последнее слово)",
            ["settings.smart"] = "Умная конверсия выделения (сохранять верные слова)",
            ["settings.auto"] = "Исправлять раскладку автоматически (бета)",
            ["settings.sound"] = "Звук при смене раскладки",
            ["settings.startup"] = "Запускать при входе в систему",
            ["settings.perapp"] = "Запоминать раскладку для каждого приложения",
            ["settings.updates"] = "Проверять обновления при запуске",
            ["settings.switchhotkey"] = "Переключить раскладку:",
            ["settings.off"] = "Выкл.",
            ["settings.exceptions"] = "Исключения…",
            ["settings.close"] = "Закрыть",
            ["exc.title"] = "NormalSwitcher — Исключения",
            ["exc.never"] = "Никогда не конвертировать (как набрано):",
            ["exc.always"] = "Всегда конвертировать (целевая форма):",
            ["exc.save"] = "Сохранить",
            ["exc.cancel"] = "Отмена",
            ["upd.available.title"] = "NormalSwitcher — Доступно обновление",
            ["upd.available.body"] = "Доступна новая версия NormalSwitcher: {0} (у вас {1}).",
            ["upd.open"] = "Открыть страницу загрузки?",
            ["upd.install"] = "Скачать и установить обновление сейчас? NormalSwitcher перезапустится.",
            ["upd.install.error"] = "Не удалось скачать, проверить или запустить установщик. Открыть страницу релиза?",
            ["upd.uptodate"] = "У вас последняя версия ({0}).",
            ["upd.error"] = "Не удалось проверить обновления (ошибка сети). Попробуйте позже или откройте сайт.",
        },
    };
}
