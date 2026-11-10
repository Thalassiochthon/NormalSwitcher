using System.Runtime.InteropServices;
using System.Windows.Forms;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

public enum ClipboardShortcut { CtrlShiftV, AltShiftV, CtrlAltV }

/// <summary>Tracks text copied explicitly by the user. All clipboard access runs on the STA UI thread.</summary>
internal sealed class ClipboardHistory(IntPtr window) : IDisposable
{
    private const int HotkeyId = 1;
    private const int ClearCommand = 100;
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
        Register(Settings.Current.ClipboardHistoryShortcut);
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
            Register(settings.ClipboardHistoryShortcut);
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

    public bool SetShortcut(ClipboardShortcut shortcut)
    {
        var settings = Settings.Current;
        Unregister();
        if (settings.ClipboardHistoryEnabled && !Register(shortcut))
        {
            Register(settings.ClipboardHistoryShortcut);
            return false;
        }
        settings.ClipboardHistoryShortcut = shortcut;
        settings.Save();
        return true;
    }

    private bool Register(ClipboardShortcut shortcut)
    {
        uint keys = shortcut switch
        {
            ClipboardShortcut.AltShiftV => MOD_ALT | MOD_SHIFT,
            ClipboardShortcut.CtrlAltV => MOD_CONTROL | MOD_ALT,
            _ => MOD_CONTROL | MOD_SHIFT
        };
        return _registered = RegisterHotKey(window, HotkeyId, keys | MOD_NOREPEAT, VK_V);
    }

    private void Unregister()
    {
        if (_registered) UnregisterHotKey(window, HotkeyId);
        _registered = false;
    }

    public void HandleHotkey(IntPtr id)
    {
        if ((int)id == HotkeyId) Show();
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
        var items = _items.ToArray();
        IntPtr menu = CreatePopupMenu();
        if (menu == IntPtr.Zero) return;
        uint command;
        _open = true;
        try
        {
            for (int i = 0; i < items.Length; i++)
            {
                string preview = items[i].ReplaceLineEndings(" ").Replace('\t', ' ');
                if (preview.Length > 80) preview = preview[..80] + "…";
                AppendMenuW(menu, MF_STRING, (uint)i + 1, preview.Replace("&", "&&"));
            }
            if (items.Length == 0)
                AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, L10n.T("clipboard.empty"));
            if (HasError)
                AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, L10n.T("clipboard.storageError"));
            AppendMenuW(menu, MF_SEPARATOR, 0, null);
            AppendMenuW(menu, MF_STRING, ClearCommand, L10n.T("clipboard.clear"));
            GetCursorPos(out POINT point);
            SetForegroundWindow(window);
            command = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD, point.X, point.Y, 0, window, IntPtr.Zero);
            PostMessageW(window, 0, IntPtr.Zero, IntPtr.Zero);
        }
        finally { DestroyMenu(menu); _open = false; }

        if (target is { } original) SetForegroundWindow(original.Foreground);
        if (command == ClearCommand) Clear();
        else if (command > 0 && command <= items.Length && target is { } expected
            && InputTarget.Capture() is { IsPasswordEdit: false } current && expected.SameControl(current))
        {
            try
            {
                Clipboard.SetText(items[command - 1], TextDataFormat.UnicodeText);
                SkipCurrent();
                Pasted?.Invoke();
                TextInjector.SendCtrl(VK_V);
            }
            catch (ExternalException) { /* An app may still have the clipboard open. */ }
        }
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
