using System.Windows.Forms;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

public enum ShortcutAction { Correct, Switch, FirstLayout, SecondLayout, ChangeCase, AddException, OpenTasks, CaptureTask }

public readonly record struct KeyChord(uint Key, uint Modifiers)
{
    internal bool IsValid => (Modifiers & (MOD_CONTROL | MOD_ALT)) != 0
        && (Modifiers & ~(MOD_CONTROL | MOD_ALT | MOD_SHIFT)) == 0
        && Key is (>= 0x30 and <= 0x39) or (>= 0x41 and <= 0x5A) or (>= 0x70 and <= 0x7B);

    public override string ToString()
    {
        var keys = new List<string>();
        if ((Modifiers & MOD_CONTROL) != 0) keys.Add("Ctrl");
        if ((Modifiers & MOD_ALT) != 0) keys.Add("Alt");
        if ((Modifiers & MOD_SHIFT) != 0) keys.Add("Shift");
        keys.Add(((Keys)Key).ToString());
        return string.Join(" + ", keys);
    }
}

/// <summary>Windows registration and deferred dispatch. SendInput must run after the chord is released.</summary>
internal sealed class GlobalShortcuts(IntPtr window) : IDisposable
{
    private const int BaseId = 20;
    private readonly Dictionary<ShortcutAction, KeyChord> _active = [];
    private (ShortcutAction Action, KeyChord Chord, InputTarget? Target)? _pending;

    public event Action<ShortcutAction>? Activated;

    public void Initialize()
    {
        var settings = Settings.Current;
        if (!settings.TaskShortcutsInitialized)
        {
            settings.GlobalShortcuts.TryAdd(ShortcutAction.OpenTasks, new(0x54, MOD_CONTROL | MOD_SHIFT));
            settings.GlobalShortcuts.TryAdd(ShortcutAction.CaptureTask, new(0x56, MOD_CONTROL | MOD_ALT | MOD_SHIFT));
            settings.TaskShortcutsInitialized = true;
            settings.Save();
        }
        foreach (var (action, chord) in Settings.Current.GlobalShortcuts)
            if (Enum.IsDefined(action)) TryRegister(action, chord);
    }

    public bool IsRegistered(ShortcutAction action) => _active.ContainsKey(action);

    public KeyChord? Get(ShortcutAction action) =>
        Settings.Current.GlobalShortcuts.TryGetValue(action, out var chord) ? chord : null;

    public bool Set(ShortcutAction action, KeyChord? chord)
    {
        if (_pending?.Action == action) _pending = null;
        if (_active.TryGetValue(action, out var previous) && previous == chord) return true;
        if (_active.Remove(action)) UnregisterHotKey(window, BaseId + (int)action);
        if (chord is { } selected && !TryRegister(action, selected))
        {
            if (previous.IsValid) TryRegister(action, previous);
            return false;
        }
        if (chord is { } next) Settings.Current.GlobalShortcuts[action] = next;
        else Settings.Current.GlobalShortcuts.Remove(action);
        Settings.Current.Save();
        return true;
    }

    private bool TryRegister(ShortcutAction action, KeyChord chord)
    {
        if (!chord.IsValid || !RegisterHotKey(window, BaseId + (int)action, chord.Modifiers | MOD_NOREPEAT, chord.Key))
            return false;
        _active[action] = chord;
        return true;
    }

    public bool IsRegisteredPress(uint key) =>
        _active.Values.Any(chord => chord.Key == key && chord.Modifiers == HeldModifiers());

    public bool HasPending => _pending != null;

    public void CancelPending() => _pending = null;

    public void Handle(IntPtr id)
    {
        var action = (ShortcutAction)(id.ToInt64() - BaseId);
        if (!_active.TryGetValue(action, out var chord)) return;
        if (action is ShortcutAction.OpenTasks or ShortcutAction.CaptureTask)
        {
            _pending = (action, chord, null);
            return;
        }
        if (InputTarget.Capture() is not { } target) return;
        GetWindowThreadProcessId(target.Foreground, out uint pid);
        if (pid != Environment.ProcessId) _pending = (action, chord, target);
    }

    public void Poll()
    {
        if (_pending is not { } request || HeldModifiers() != 0 || IsDown((int)request.Chord.Key)) return;
        _pending = null;
        if (request.Target == null || InputTarget.Capture() is { } current && request.Target.Value.SameControl(current))
            Activated?.Invoke(request.Action);
    }

    private static uint HeldModifiers() =>
        (IsDown(VK_CONTROL) ? MOD_CONTROL : 0) | (IsDown(0x12) ? MOD_ALT : 0) | (IsDown(VK_SHIFT) ? MOD_SHIFT : 0)
        | (IsDown(0x5B) || IsDown(0x5C) ? 0x0008u : 0);

    private static bool IsDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    public void Dispose()
    {
        foreach (var action in _active.Keys) UnregisterHotKey(window, BaseId + (int)action);
    }
}
