using System.Drawing;
using RuSwitcher.Win.Core;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Tray;

/// <summary>
/// Shows the active keyboard layout and the app menu in the notification area.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    internal const string WindowClass = "NormalSwitcherTrayWindow";
    private const uint ID_ENABLE = 1;
    private const uint ID_QUIT = 2;
    private const uint ID_SETTINGS = 14;
    private const uint ID_AUTO = 15;
    private const uint ID_UPDATE = 16;
    private const uint ID_TASKS = 18;
    private const uint ID_CLIPBOARD = 17;
    private const uint ID_LAYOUT_FIRST = 100;

    private readonly WndProc _wndProc;
    private IntPtr _hwnd;
    private NOTIFYICONDATA _nid;
    private readonly System.Windows.Forms.Timer _layoutTimer = new() { Interval = 250 };
    private Icon? _icon;
    private CaretBadge? _badge;
    private bool _visible;
    private bool _monochrome;
    private IntPtr _shownLayout;
    private bool _menuOpen;
    private string _tooltip = "";
    private uint _taskbarCreated;
    private bool _enabled = Settings.Current.KeyboardEnabled;

    public GlobalShortcuts Shortcuts { get; private set; } = null!;
    public Func<string>? AutoStatus { get; set; }
    public event Action? TasksRequested;
    public ClipboardHistory ClipboardHistory { get; private set; } = null!;
    public event Action<string>? Diagnostic;
    public event Action<bool>? EnabledChanged;
    public event Action? SettingsRequested;
    public event Action? UpdateRequested;
    public event Action? QuitRequested;
    /// <summary>Fired on the message-loop thread when a trigger was posted from the hook.</summary>
    public event Action? TriggerActivated;
    /// <summary>Fired on the message-loop thread when an as-you-type auto-convert was posted from the hook.</summary>
    public event Action? AutoConvertActivated;

    public TrayIcon() => _wndProc = WindowProc;

    /// <summary>Called from the LL hook callback: posts a message so the actual (possibly slow,
    /// clipboard-touching) conversion runs on the message loop, NOT inside the hook callback —
    /// keeping the callback fast so Windows never drops the low-level hook (300ms timeout).</summary>
    public void PostTrigger()
    {
        if (_hwnd != IntPtr.Zero) PostMessageW(_hwnd, WM_APP, IntPtr.Zero, IntPtr.Zero);
    }

    /// <summary>Called from the LL hook callback on a word boundary when auto-convert is armed: posts a
    /// message so the dictionary check + retype run on the message loop, never inside the callback.</summary>
    public bool PostAutoConvert() =>
        _hwnd != IntPtr.Zero && PostMessageW(_hwnd, WM_AUTOCONVERT, IntPtr.Zero, IntPtr.Zero) != IntPtr.Zero;

    public void Show(string tooltip)
    {
        IntPtr hInstance = GetModuleHandleW(null);
        var wc = new WNDCLASS
        {
            lpfnWndProc = _wndProc,
            hInstance = hInstance,
            lpszClassName = WindowClass,
        };
        RegisterClassW(ref wc);

        _hwnd = CreateWindowExW(0, WindowClass, "NormalSwitcher",
            0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);

        Shortcuts = new GlobalShortcuts(_hwnd);
        Shortcuts.Initialize();
        ClipboardHistory = new ClipboardHistory(_hwnd, message => Diagnostic?.Invoke(message));
        ClipboardHistory.Initialize();
        _tooltip = tooltip;
        _taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
        _shownLayout = LayoutSwitcher.Current();
        _monochrome = Settings.Current.MonochromeTray;
        _icon = LayoutIcon.Create(_shownLayout, _monochrome);
        _nid = new NOTIFYICONDATA
        {
            cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<NOTIFYICONDATA>(),
            hWnd = _hwnd,
            uID = 1,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage = WM_TRAYICON,
            hIcon = _icon.Handle,
            szTip = LayoutTooltip(_shownLayout),
        };
        RefreshAppearance();
        _layoutTimer.Tick += (_, _) =>
        {
            RefreshLayout();
            ClipboardHistory.Poll();
            Shortcuts.Poll();
        };
        _layoutTimer.Start();
    }

    private string LayoutTooltip(IntPtr layout)
    {
        string text = $"{_tooltip} · {LayoutIcon.Name(layout)}";
        return text.Length <= 127 ? text : text[..127];
    }

    public void PostShortcutPoll() => PostMessageW(_hwnd, WM_SHORTCUTREADY, IntPtr.Zero, IntPtr.Zero);

    public void RefreshAppearance()
    {
        bool show = !Settings.Current.HideTrayIcon;
        if (show != _visible)
        {
            if (show) _visible = Shell_NotifyIconW(NIM_ADD, ref _nid);
            else { Shell_NotifyIconW(NIM_DELETE, ref _nid); _visible = false; }
        }
        if (!Settings.Current.CaretIndicator)
        {
            _badge?.Dispose();
            _badge = null;
        }
        RefreshLayout();
    }

    private void RefreshLayout()
    {
        if (_menuOpen) return;
        IntPtr layout = LayoutSwitcher.Current();
        bool changed = layout != _shownLayout;
        bool monochrome = Settings.Current.MonochromeTray;
        if (!changed && monochrome == _monochrome) return;

        var next = LayoutIcon.Create(layout, monochrome);
        var data = _nid;
        data.hIcon = next.Handle;
        data.szTip = LayoutTooltip(layout);
        if (_visible && !Shell_NotifyIconW(NIM_MODIFY, ref data))
        {
            next.Dispose();
            return;
        }
        _icon?.Dispose();
        _icon = next;
        _nid = data;
        _shownLayout = layout;
        _monochrome = monochrome;
        if (changed) Sound.Switch(layout);
        if (changed && Settings.Current.CaretIndicator)
            (_badge ??= new CaretBadge()).ShowAtCaret(layout);
    }

    internal static string TriggerName(TriggerKind t) => t switch
    {
        TriggerKind.CtrlDoubleTap => L10n.T("trigger.ctrl"),
        TriggerKind.ShiftDoubleTap => L10n.T("trigger.shift"),
        TriggerKind.PauseBreak => L10n.T("trigger.pause"),
        TriggerKind.AltDoubleTap => L10n.T("trigger.double", "Alt"),
        TriggerKind.LeftCtrlDoubleTap => L10n.T("trigger.doubleLeft", "Ctrl"),
        TriggerKind.RightCtrlDoubleTap => L10n.T("trigger.doubleRight", "Ctrl"),
        TriggerKind.LeftShiftDoubleTap => L10n.T("trigger.doubleLeft", "Shift"),
        TriggerKind.RightShiftDoubleTap => L10n.T("trigger.doubleRight", "Shift"),
        TriggerKind.LeftAltDoubleTap => L10n.T("trigger.doubleLeft", "Alt"),
        TriggerKind.RightAltDoubleTap => L10n.T("trigger.doubleRight", "Alt"),
        TriggerKind.CtrlTap => L10n.T("trigger.tap", "Ctrl"),
        TriggerKind.ShiftTap => L10n.T("trigger.tap", "Shift"),
        TriggerKind.AltTap => L10n.T("trigger.tap", "Alt"),
        _ => "?",
    };

    private IntPtr WindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == _taskbarCreated && msg != 0)
        {
            _visible = false;
            RefreshAppearance();
            return IntPtr.Zero;
        }
        switch (msg)
        {
            case WM_TRAYICON when ((uint)(lParam.ToInt64() & 0xFFFF)) is WM_RBUTTONUP or WM_LBUTTONUP:
                ShowMenu();
                return IntPtr.Zero;

            case WM_HOTKEY:
                if (!_menuOpen)
                {
                    ClipboardHistory.HandleHotkey(wParam);
                    Shortcuts.Handle(wParam);
                }
                return IntPtr.Zero;

            case WM_SETTINGS:
                SettingsRequested?.Invoke();
                return IntPtr.Zero;

            case WM_SHORTCUTREADY:
                Shortcuts.Poll();
                return IntPtr.Zero;

            case WM_APP:
                TriggerActivated?.Invoke();
                return IntPtr.Zero;

            case WM_AUTOCONVERT:
                AutoConvertActivated?.Invoke();
                return IntPtr.Zero;

#if NORMALSWITCHER_UPDATE_SMOKE
            case WM_APP + 20:
                if (wParam == IntPtr.Zero)
                    return Updater.MenuTitle == L10n.T("tray.update") ? IntPtr.Zero : (IntPtr)1;
                UpdateRequested?.Invoke();
                return (IntPtr)1;
#endif

            case WM_UPDATE_QUIT:
                QuitRequested?.Invoke();
                PostQuitMessage(0);
                return IntPtr.Zero;

            case WM_DESTROY:
                PostQuitMessage(0);
                return IntPtr.Zero;
        }
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private void ShowMenu()
    {
        if (_menuOpen) return;
        var s = Settings.Current;
        IntPtr menu = CreatePopupMenu();
        IntPtr target = GetForegroundWindow();
        var layouts = LayoutSwitcher.Installed();
        IntPtr current = LayoutSwitcher.Current();
        for (int i = 0; i < layouts.Length; i++)
            AppendMenuW(menu, MF_STRING | Chk(layouts[i] == current), ID_LAYOUT_FIRST + (uint)i,
                LayoutIcon.Name(layouts[i]));
        if (layouts.Length > 0)
            AppendMenuW(menu, MF_SEPARATOR, 0, null);
        AppendMenuW(menu, MF_STRING | Chk(_enabled), ID_ENABLE, L10n.T("tray.enable"));
        AppendMenuW(menu, MF_STRING | Chk(s.AutoConvert), ID_AUTO, L10n.T("tray.auto"));
        if (AutoStatus?.Invoke() is { } status)
            AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, status);
        AppendMenuW(menu, MF_STRING, ID_TASKS, L10n.T("tasks.title"));
        if (s.ClipboardHistoryEnabled)
            AppendMenuW(menu, MF_STRING, ID_CLIPBOARD, L10n.T("clipboard.title"));
        AppendMenuW(menu, MF_STRING, ID_SETTINGS, L10n.T("tray.settings"));
        AppendMenuW(menu, MF_STRING, ID_UPDATE, Updater.MenuTitle);

        AppendMenuW(menu, MF_SEPARATOR, 0, null);
        AppendMenuW(menu, MF_STRING, ID_QUIT, L10n.T("tray.quit"));

        GetCursorPos(out POINT pt);
        SetForegroundWindow(_hwnd); // so the menu dismisses correctly on outside click
        uint command;
        _menuOpen = true;
        try
        {
            command = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD, pt.X, pt.Y, 0, _hwnd, IntPtr.Zero);
            PostMessageW(_hwnd, 0, IntPtr.Zero, IntPtr.Zero); // WM_NULL lets the tray menu reopen normally.
        }
        finally
        {
            DestroyMenu(menu);
            _menuOpen = false;
        }

        switch (command)
        {
            case ID_ENABLE: SetEnabled(!_enabled); break;
            case ID_TASKS: TasksRequested?.Invoke(); break;
            case ID_CLIPBOARD:
                if (target != IntPtr.Zero) SetForegroundWindow(target);
                ClipboardHistory.Show();
                break;
            case ID_SETTINGS: SettingsRequested?.Invoke(); break;
            case ID_UPDATE: UpdateRequested?.Invoke(); break;
            case ID_QUIT: QuitRequested?.Invoke(); PostQuitMessage(0); break;
            case ID_AUTO: s.AutoConvert = !s.AutoConvert; s.Save(); break;
            default:
                if (target != IntPtr.Zero && command >= ID_LAYOUT_FIRST && command - ID_LAYOUT_FIRST < layouts.Length)
                {
                    SetForegroundWindow(target);
                    LayoutSwitcher.SwitchTo(layouts[command - ID_LAYOUT_FIRST], target);
                }
                break;
        }
    }

    public void SetEnabled(bool enabled)
    {
        _enabled = enabled;
        Settings.Current.KeyboardEnabled = enabled;
        Settings.Current.Save();
        EnabledChanged?.Invoke(enabled);
    }

    private static uint Chk(bool on) => on ? MF_CHECKED : MF_UNCHECKED;

    public void Dispose()
    {
        _layoutTimer.Dispose();
        _badge?.Dispose();
        ClipboardHistory?.Dispose();
        Shortcuts?.Dispose();
        if (_hwnd != IntPtr.Zero)
        {
            Shell_NotifyIconW(NIM_DELETE, ref _nid);
            DestroyWindow(_hwnd);
            _hwnd = IntPtr.Zero;
        }
        _icon?.Dispose();
        _icon = null;
    }
}
