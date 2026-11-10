using System.Runtime.InteropServices;
using System.Windows.Forms;
using RuSwitcher.Win.UI;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

public enum ClipboardShortcut { CtrlShiftV, AltShiftV, CtrlAltV }

/// <summary>Tracks text copied explicitly by the user. All clipboard access runs on the STA UI thread.</summary>
internal sealed class ClipboardHistory(IntPtr window, Action<string> log) : IDisposable
{
    private const int HotkeyId = 1;
    private readonly ClipboardHistoryStore _store = new(Path.Combine(Settings.DataDirectory, "clipboard-history.dat"));
    private readonly List<string> _items = [];
    private uint _sequence = GetClipboardSequenceNumber();
    private bool _registered;
    private bool _open;
    private bool _storageReady;
    public event Action? Pasted;
    public bool HasError { get; private set; }

    public void Initialize()
    {
        if (!Settings.Current.ClipboardHistoryEnabled) return;
        Register(DisplayShortcut);
        if (Settings.Current.ClipboardHistoryPersistent) Load();
    }

    public bool SetEnabled(bool enabled)
    {
        var settings = Settings.Current;
        if (!enabled && !Clear()) return false;
        settings.ClipboardHistoryEnabled = enabled;
        settings.Save();
        SkipCurrent();
        if (enabled)
        {
            Register(DisplayShortcut);
            _storageReady = true;
        }
        else Unregister();
        return true;
    }

    public bool SetPersistence(bool enabled)
    {
        try
        {
            if (enabled) _store.Write(_items);
            else _store.Clear();
            _storageReady = enabled;
            HasError = false;
            Settings.Current.ClipboardHistoryPersistent = enabled;
            Settings.Current.Save();
            return true;
        }
        catch { HasError = true; return false; }
    }

    private KeyChord DefaultShortcut => new(VK_V, Settings.Current.ClipboardHistoryShortcut switch
    {
        ClipboardShortcut.AltShiftV => MOD_ALT | MOD_SHIFT,
        ClipboardShortcut.CtrlAltV => MOD_CONTROL | MOD_ALT,
        _ => MOD_CONTROL | MOD_SHIFT
    });

    public KeyChord DisplayShortcut => Settings.Current.ClipboardCustomShortcut ?? DefaultShortcut;

    public bool SetCustomShortcut(KeyChord? shortcut)
    {
        var settings = Settings.Current;
        KeyChord previous = DisplayShortcut;
        Unregister();
        if (settings.ClipboardHistoryEnabled && !Register(shortcut ?? DefaultShortcut))
        {
            Register(previous);
            return false;
        }
        settings.ClipboardCustomShortcut = shortcut;
        settings.Save();
        return true;
    }

    private bool Register(KeyChord chord)
    {
        _registered = chord.IsValid && RegisterHotKey(window, HotkeyId, chord.Modifiers | MOD_NOREPEAT, chord.Key);
        if (!_registered) log($"Clipboard hotkey registration failed ({Marshal.GetLastWin32Error()})");
        return _registered;
    }

    private void Unregister()
    {
        if (_registered) UnregisterHotKey(window, HotkeyId);
        _registered = false;
    }

    public void HandleHotkey(IntPtr id)
    {
        if ((int)id != HotkeyId) return;
        log("Clipboard hotkey received");
        Show();
    }

    public void SkipCurrent() => _sequence = GetClipboardSequenceNumber();

    public void Poll()
    {
        if (!Settings.Current.ClipboardHistoryEnabled) return;
        uint sequence = GetClipboardSequenceNumber();
        if (sequence == 0 || sequence == _sequence) return;
        try
        {
            var data = Clipboard.GetDataObject();
            string? text = data != null
                && !data.GetDataPresent(DataFormats.FileDrop, false)
                && !data.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing", false)
                && !data.GetDataPresent("CanIncludeInClipboardHistory", false)
                && !data.GetDataPresent("CanUploadToCloudClipboard", false)
                && !data.GetDataPresent("Clipboard Viewer Ignore", false)
                && InputTarget.Capture() is not { IsPasswordEdit: true }
                && data.GetDataPresent(DataFormats.UnicodeText, false)
                ? data.GetData(DataFormats.UnicodeText, false) as string : null;
            if (GetClipboardSequenceNumber() != sequence) return;
            _sequence = sequence;
            if (!ClipboardHistoryStore.IsValid(text) || _items.FirstOrDefault() == text) return;
            _items.Remove(text!);
            _items.Insert(0, text!);
            if (_items.Count > ClipboardHistoryStore.Limit) _items.RemoveAt(_items.Count - 1);
            if (Settings.Current.ClipboardHistoryPersistent && _storageReady)
            {
                try { _store.Write(_items); HasError = false; }
                catch { HasError = true; }
            }
        }
        catch (ExternalException) { /* The clipboard owner may still have it open. Retry on the next tick. */ }
    }

    public void Show()
    {
        if (_open || !Settings.Current.ClipboardHistoryEnabled) return;
        Poll();
        var target = InputTarget.Capture();
        if (target is { IsPasswordEdit: true }) return;
        log($"Clipboard history popup opened (has target: {target != null})");
        using var menu = new ClipboardHistoryMenu(_items.ToArray(), HasError);
        _open = true;
        try { menu.ShowDialog(); }
        finally { _open = false; }

        if (target is { } original) SetForegroundWindow(original.Foreground);
        if (menu.ClearRequested) Clear();
        else if (menu.Selection is { } selected && target is { } expected)
            _ = PasteAsync(selected, expected);
    }

    private async Task PasteAsync(string text, InputTarget expected)
    {
        // Activation of another process may complete after the menu closes.
        if (InputTarget.Capture() is not { } current || !expected.SameControl(current))
            await Task.Delay(75);
        if (!Settings.Current.ClipboardHistoryEnabled
            || InputTarget.Capture() is not { IsPasswordEdit: false } focused || !expected.SameControl(focused))
        {
            log("Clipboard paste skipped because focus changed");
            return;
        }

        try
        {
            Clipboard.SetText(text, TextDataFormat.UnicodeText);
            SkipCurrent();
            Pasted?.Invoke();
            TextInjector.SendCtrl(VK_V);
        }
        catch (ExternalException) { /* An app may still have the clipboard open. */ }
    }

    private void Load()
    {
        try { _items.AddRange(_store.Read()); _storageReady = true; }
        catch (FileNotFoundException) { _storageReady = true; }
        catch (DirectoryNotFoundException) { _storageReady = true; }
        catch { HasError = true; }
    }

    private bool Clear()
    {
        _items.Clear();
        SkipCurrent();
        try { _store.Clear(); _storageReady = true; HasError = false; return true; }
        catch { HasError = true; return false; }
    }

    public void Dispose() => Unregister();
}
