using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using RuSwitcher.Win.UI;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

public enum ClipboardShortcut { CtrlShiftV, AltShiftV, CtrlAltV }

/// <summary>Tracks text and images copied explicitly by the user. All clipboard access runs on the STA UI thread.</summary>
internal sealed class ClipboardHistory(IntPtr window, Action<string> log) : IDisposable
{
    private const int HotkeyId = 1;
    private readonly ClipboardHistoryStore _store = new(Path.Combine(Settings.DataDirectory, "clipboard-history.dat"));
    private readonly List<ClipboardEntry> _items = [];
    private readonly List<ClipboardEntry> _pending = [];
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
            if (enabled && !RetryStorage(includeCurrent: true)) return false;
            if (!enabled) _store.Clear();
            _storageReady = enabled;
            if (!enabled) _pending.Clear();
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
            var entry = ReadAllowedEntry();
            if (GetClipboardSequenceNumber() != sequence) return;
            _sequence = sequence;
            if (entry is null || _items.FirstOrDefault()?.Key == entry.Key) return;
            Insert(_items, entry);
            if (Settings.Current.ClipboardHistoryPersistent)
            {
                Insert(_pending, entry);
                if (_storageReady && !HasError)
                {
                    try { _store.Write(_items); _pending.Clear(); }
                    catch { HasError = true; }
                }
            }
        }
        catch (ExternalException) { /* The clipboard owner may still have it open. Retry on the next tick. */ }
        catch (Exception error) when (error is ArgumentException or OutOfMemoryException)
        {
            _sequence = sequence;
            log("Clipboard image unavailable");
        }
    }

    private static void Insert(List<ClipboardEntry> entries, ClipboardEntry entry)
    {
        var next = ClipboardEntry.Trim(entries.Prepend(entry), Settings.Current.ClipboardImageLimit);
        entries.Clear();
        entries.AddRange(next);
    }

    public void SetImageLimit(int limit)
    {
        var settings = Settings.Current;
        settings.ClipboardImageLimit = Math.Clamp(limit, 0, 50);
        settings.Save();
        foreach (var entries in new[] { _items, _pending })
        {
            var next = ClipboardEntry.Trim(entries, settings.ClipboardImageLimit);
            entries.Clear();
            entries.AddRange(next);
        }
        if (settings.ClipboardHistoryPersistent && _storageReady && !HasError)
        {
            try { _store.Write(_items); }
            catch { HasError = true; }
        }
    }

    private static ClipboardEntry? ReadAllowedEntry()
    {
        var data = AllowedClipboardData();
        if (data == null) return null;
        if (Settings.Current.ClipboardImageLimit > 0)
        {
            if (data.GetDataPresent("PNG", false) && data.GetData("PNG", false) is MemoryStream png)
            {
                using (png)
                {
                    if (png.Length <= ClipboardEntry.MaxImageBytes)
                    {
                        png.Position = 0;
                        using var original = Image.FromStream(png);
                        if (ClipboardEntry.FromImage(original) is { } entry) return entry;
                    }
                }
            }
            if (data.GetDataPresent(DataFormats.Bitmap))
            {
                using var image = data.GetData(DataFormats.Bitmap) as Image;
                if (image is not null && ClipboardEntry.FromImage(image) is { } entry) return entry;
            }
        }
        return ReadText(data) is { } text && ClipboardHistoryStore.IsValid(text) ? new ClipboardEntry(text) : null;
    }

    internal static string? ReadAllowedText() => AllowedClipboardData() is { } data ? ReadText(data) : null;

    private static string? ReadText(IDataObject data) => data.GetDataPresent(DataFormats.UnicodeText, false)
        ? data.GetData(DataFormats.UnicodeText, false) as string : null;

    private static IDataObject? AllowedClipboardData()
    {
        var data = Clipboard.GetDataObject();
        return data != null
            && !data.GetDataPresent(DataFormats.FileDrop, false)
            && !data.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing", false)
            && !Disallows(data, "CanIncludeInClipboardHistory")
            && !Disallows(data, "CanUploadToCloudClipboard")
            && !data.GetDataPresent("Clipboard Viewer Ignore", false)
            && InputTarget.Capture() is not { IsPasswordEdit: true } ? data : null;
    }

    private static bool Disallows(IDataObject data, string format)
    {
        if (!data.GetDataPresent(format, false)) return false;
        return data.GetData(format, false) switch
        {
            int value => value != 1,
            uint value => value != 1,
            byte[] bytes => bytes.Length < 4 || BitConverter.ToUInt32(bytes) != 1,
            MemoryStream stream => stream.Length < 4 || BitConverter.ToUInt32(stream.ToArray()) != 1,
            _ => true
        };
    }

    public Action<string>? TaskRequested { get; set; }
    public bool IsOpen => _open;
    public bool ShortcutRegistered => _registered;

    public void Show()
    {
        if (_open || Form.ActiveForm?.Modal == true || !Settings.Current.ClipboardHistoryEnabled) return;
        Poll();
        var target = InputTarget.Capture();
        if (target is { IsPasswordEdit: true }) return;
        log($"Clipboard history popup opened (has target: {target != null})");
        using var menu = new ClipboardHistoryMenu(_items.ToArray(), HasError, () =>
        {
            if (Settings.Current.ClipboardHistoryPersistent)
            {
                if (!RetryStorage()) return null;
            }
            else
            {
                try { _store.Clear(); HasError = false; }
                catch { return null; }
            }
            return _items.ToArray();
        }, Clear, TaskRequested != null);
        _open = true;
        try { menu.ShowDialog(); }
        finally { _open = false; }

        if (target is { } original) SetForegroundWindow(original.Foreground);
        if (menu.TaskText is { } task) TaskRequested?.Invoke(task);
        else if (menu.Selection is { } selected && target is { } expected)
            _ = PasteAsync(selected, expected);
    }

    private async Task PasteAsync(ClipboardEntry entry, InputTarget expected)
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
            if (entry.Text is { } text) Clipboard.SetText(text, TextDataFormat.UnicodeText);
            else
            {
                using var bitmap = entry.OpenImage();
                if (bitmap is null) return;
                using var png = new MemoryStream(entry.Png!, writable: false);
                var data = new DataObject();
                data.SetImage(bitmap);
                data.SetData("PNG", false, png);
                Clipboard.SetDataObject(data, copy: true);
            }
            SkipCurrent();
            Pasted?.Invoke();
            TextInjector.SendCtrl(VK_V);
        }
        catch (ExternalException) { /* An app may still have the clipboard open. */ }
    }

    private void Load()
    {
        try { _items.AddRange(_store.Read(Settings.Current.ClipboardImageLimit)); _storageReady = true; }
        catch (FileNotFoundException) { _storageReady = true; }
        catch (DirectoryNotFoundException) { _storageReady = true; }
        catch { HasError = true; }
    }

    private bool RetryStorage(bool includeCurrent = false)
    {
        try
        {
            ClipboardEntry[] saved;
            try { saved = _store.Read(Settings.Current.ClipboardImageLimit); }
            catch (FileNotFoundException) { saved = []; }
            catch (DirectoryNotFoundException) { saved = []; }

            var merged = ClipboardEntry.Trim(_pending.Concat(includeCurrent ? _items : []).Concat(saved),
                Settings.Current.ClipboardImageLimit);
            _store.Write(merged);
            _items.Clear();
            _items.AddRange(merged);
            _pending.Clear();
            _storageReady = true;
            HasError = false;
            return true;
        }
        catch { HasError = true; return false; }
    }

    private bool Clear()
    {
        try { _store.Clear(); }
        catch { HasError = true; return false; }
        _items.Clear();
        _pending.Clear();
        SkipCurrent();
        _storageReady = true;
        HasError = false;
        return true;
    }

    public void Dispose() => Unregister();
}
