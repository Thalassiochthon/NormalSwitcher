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
            ["app.name"] = "RuSwitcher",
            ["tray.enable"] = "Enable RuSwitcher",
            ["tray.trigger"] = "Trigger: {0}",
            ["tray.wholeline"] = "Convert whole line",
            ["tray.auto"] = "Auto-convert as you type (beta)",
            ["tray.settings"] = "Settings…",
            ["tray.update"] = "Check for updates…",
            ["tray.quit"] = "Quit",
            ["trigger.ctrl"] = "Double-tap Ctrl",
            ["trigger.shift"] = "Double-tap Shift",
            ["trigger.pause"] = "Pause/Break key",
            ["settings.title"] = "RuSwitcher — Settings",
            ["settings.trigger"] = "Trigger:",
            ["settings.wholeline"] = "Convert the whole line (not just the last word)",
            ["settings.smart"] = "Smart selection conversion (keep correct words)",
            ["settings.auto"] = "Auto-convert as you type (beta)",
            ["settings.sound"] = "Play a sound on layout switch",
            ["settings.startup"] = "Launch at startup",
            ["settings.perapp"] = "Remember the layout per application",
            ["settings.updates"] = "Check for updates on launch",
            ["settings.switchhotkey"] = "Layout-switch hotkey:",
            ["settings.off"] = "Off",
            ["settings.exceptions"] = "Exceptions…",
            ["settings.close"] = "Close",
            ["exc.title"] = "RuSwitcher — Exceptions",
            ["exc.never"] = "Never convert (as typed):",
            ["exc.always"] = "Always convert (target form):",
            ["exc.save"] = "Save",
            ["exc.cancel"] = "Cancel",
            ["upd.available.title"] = "RuSwitcher — Update available",
            ["upd.available.body"] = "A new version of RuSwitcher is available: {0} (you have {1}).",
            ["upd.open"] = "Open the download page now?",
            ["upd.uptodate"] = "You're up to date (version {0}).",
            ["upd.error"] = "Could not check for updates (network error). Please try again later, or visit the site.",
        },
        ["ru"] = new()
        {
            ["app.name"] = "RuSwitcher",
            ["tray.enable"] = "Включить RuSwitcher",
            ["tray.trigger"] = "Триггер: {0}",
            ["tray.wholeline"] = "Конвертировать всю строку",
            ["tray.auto"] = "Автоконверсия при наборе (бета)",
            ["tray.settings"] = "Настройки…",
            ["tray.update"] = "Проверить обновления…",
            ["tray.quit"] = "Выход",
            ["trigger.ctrl"] = "Двойной Ctrl",
            ["trigger.shift"] = "Двойной Shift",
            ["trigger.pause"] = "Клавиша Pause/Break",
            ["settings.title"] = "RuSwitcher — Настройки",
            ["settings.trigger"] = "Триггер:",
            ["settings.wholeline"] = "Конвертировать всю строку (не только последнее слово)",
            ["settings.smart"] = "Умная конверсия выделения (сохранять верные слова)",
            ["settings.auto"] = "Автоконверсия при наборе (бета)",
            ["settings.sound"] = "Звук при смене раскладки",
            ["settings.startup"] = "Запускать при входе в систему",
            ["settings.perapp"] = "Запоминать раскладку для каждого приложения",
            ["settings.updates"] = "Проверять обновления при запуске",
            ["settings.switchhotkey"] = "Хоткей смены раскладки:",
            ["settings.off"] = "Выкл.",
            ["settings.exceptions"] = "Исключения…",
            ["settings.close"] = "Закрыть",
            ["exc.title"] = "RuSwitcher — Исключения",
            ["exc.never"] = "Никогда не конвертировать (как набрано):",
            ["exc.always"] = "Всегда конвертировать (целевая форма):",
            ["exc.save"] = "Сохранить",
            ["exc.cancel"] = "Отмена",
            ["upd.available.title"] = "RuSwitcher — Доступно обновление",
            ["upd.available.body"] = "Доступна новая версия RuSwitcher: {0} (у вас {1}).",
            ["upd.open"] = "Открыть страницу загрузки?",
            ["upd.uptodate"] = "У вас последняя версия ({0}).",
            ["upd.error"] = "Не удалось проверить обновления (ошибка сети). Попробуйте позже или откройте сайт.",
        },
    };
}
