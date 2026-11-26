using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using RuSwitcher.Win.Core;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Tray;

/// <summary>Non-activating layout indicator with an optional correction button.</summary>
internal sealed class CaretBadge : Form
{
    private readonly System.Windows.Forms.Timer _hide = new() { Interval = 850 };
    private readonly Font _symbol = new("Segoe UI Symbol", 10);
    private Bitmap? _flag;
    private IntPtr _layout;
    private bool _persistent;
    private bool _canCorrect;
    private bool _probingEditor;
    private int _placementRevision;
    private InputTarget? _visibleTarget;
    private (IntPtr Handle, Rectangle Bounds)? _fallbackWindow;
    private Point? _fallbackPointer;
    public event Action? Correct;

    public CaretBadge()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        BackColor = SystemColors.Window;
        ClientSize = new Size(24, 20);
        _hide.Tick += (_, _) => { _hide.Stop(); Hide(); };
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle |= 0x08000000 | 0x00000080; // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
            return parameters;
        }
    }

    private Rectangle ButtonBounds => new(ClientSize.Width / 2, 0, ClientSize.Width / 2, ClientSize.Height);
    public bool ButtonHit => Visible && _canCorrect && ButtonBounds.Contains(PointToClient(Cursor.Position));

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x0084) // WM_NCHITTEST
        {
            message.Result = ButtonHit ? (IntPtr)1 : (IntPtr)(-1); // HTCLIENT or HTTRANSPARENT
            return;
        }
        if (message.Msg == 0x0021) // WM_MOUSEACTIVATE
        {
            message.Result = (IntPtr)3; // MA_NOACTIVATE
            return;
        }
        base.WndProc(ref message);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button == MouseButtons.Left && _canCorrect && ButtonBounds.Contains(e.Location))
            Correct?.Invoke();
    }

    public void ShowAtCaret(IntPtr layout, bool persistent = false, Func<InputTarget, bool>? canCorrect = null)
    {
        if (InputTarget.Capture() is not { IsPasswordEdit: false } target) { Hide(); return; }
        uint thread = GetWindowThreadProcessId(target.Foreground, out _);
        var info = new GUITHREADINFO { cbSize = (uint)Marshal.SizeOf<GUITHREADINFO>() };
        if (thread == 0 || !GetGUIThreadInfo(thread, ref info)) { Hide(); return; }

        var caret = new POINT { X = info.caretRight, Y = persistent ? info.caretTop : info.caretBottom };
        if (info.hwndCaret != IntPtr.Zero && info.caretBottom > info.caretTop && ClientToScreen(info.hwndCaret, ref caret))
        {
            _placementRevision++;
            ClearPointerAnchor();
            var point = new Point(caret.X, caret.Y);
            var origin = persistent ? new Point(point.X, point.Y - ClientSize.Height - 5)
                : new Point(point.X + 5, point.Y + 3);
            Present(target, layout, persistent, canCorrect?.Invoke(target) == true,
                Screen.FromPoint(point).WorkingArea, origin);
            return;
        }

        if (_visibleTarget is { } visibleTarget && !visibleTarget.SameControl(target)) Hide();
        if (!_probingEditor) _ = ShowFromAccessibilityAsync(target, layout, persistent, canCorrect);
    }

    private async Task ShowFromAccessibilityAsync(InputTarget target, IntPtr layout, bool persistent,
                                                    Func<InputTarget, bool>? canCorrect)
    {
        int revision = ++_placementRevision;
        _probingEditor = true;
        AccessibleText.BadgeAnchor? anchor;
        try { anchor = await AccessibleText.FindBadgeAnchorAsync(target); }
        finally { _probingEditor = false; }

        if (IsDisposed || revision != _placementRevision || Form.ActiveForm is not null) return;
        if (InputTarget.Capture() != target) { Hide(); return; }
        if (!GetWindowRect(target.Foreground, out var rect)) { Hide(); return; }
        var window = Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
        bool correctionReady = canCorrect?.Invoke(target) == true;
        var badgeSize = new Size(persistent ? 48 : 24, 20);
        if (anchor is { } measured)
        {
            var area = Rectangle.Intersect(window, Screen.FromRectangle(measured.Bounds).WorkingArea);
            if (AccessibleOrigin(measured, badgeSize, persistent, area) is { } origin)
            {
                ClearPointerAnchor();
                Present(target, layout, persistent, correctionReady, area, origin);
                return;
            }
        }

        if (persistent && correctionReady)
        {
            if (_fallbackWindow != (target.Foreground, window))
            {
                _fallbackWindow = (target.Foreground, window);
                _fallbackPointer = null;
            }
            var pointer = _fallbackPointer ?? Cursor.Position;
            if (window.Contains(pointer))
            {
                _fallbackPointer = pointer;
                var area = Rectangle.Intersect(window, Screen.FromPoint(pointer).WorkingArea);
                var origin = new Point(pointer.X - badgeSize.Width - 12, pointer.Y - badgeSize.Height - 12);
                if (origin.Y < area.Top) origin.Y = pointer.Y + 12;
                Present(target, layout, persistent, correctionReady, area, origin);
                return;
            }
        }
        ClearPointerAnchor();
        Hide();
    }

    internal static Point? AccessibleOrigin(AccessibleText.BadgeAnchor anchor, Size size, bool persistent, Rectangle area)
    {
        if (area.Width < size.Width || area.Height < size.Height || !area.IntersectsWith(anchor.Bounds)) return null;
        var visible = Rectangle.Intersect(area, anchor.Bounds);
        int x = visible.Left + (anchor.IsCaret && persistent ? 0 : 5);
        int above = visible.Top - size.Height - 5;
        int below = visible.Bottom + 3;
        bool preferAbove = persistent || !anchor.IsCaret;
        int y = preferAbove ? (above >= area.Top ? above : below)
            : (below + size.Height <= area.Bottom ? below : above);
        if (y < area.Top || y + size.Height > area.Bottom) return null;
        return new Point(Math.Clamp(x, area.Left, area.Right - size.Width), y);
    }

    private void ClearPointerAnchor()
    {
        _fallbackWindow = null;
        _fallbackPointer = null;
    }

    private void Present(InputTarget target, IntPtr layout, bool persistent, bool canCorrect, Rectangle area, Point origin)
    {
        ClientSize = new Size(persistent ? 48 : 24, 20);
        if (area.Width < Width || area.Height < Height) { Hide(); return; }
        Location = new Point(Math.Clamp(origin.X, area.Left, area.Right - Width),
            Math.Clamp(origin.Y, area.Top, area.Bottom - Height));
        _visibleTarget = target;
        _canCorrect = canCorrect;
        _persistent = persistent;
        Opacity = persistent ? (Bounds.Contains(Cursor.Position) ? 0.94 : 0.72) : 1;
        if (layout != _layout || _flag is null)
        {
            using var icon = LayoutIcon.Create(layout);
            _flag?.Dispose();
            _flag = icon.ToBitmap();
            _layout = layout;
        }
        Invalidate();
        if (!Visible) Show();
        _hide.Stop();
        if (!persistent) _hide.Start();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (_flag != null) e.Graphics.DrawImageUnscaled(_flag, 4, 2);
        if (_persistent)
            TextRenderer.DrawText(e.Graphics, "↻", _symbol, ButtonBounds,
                _canCorrect ? SystemColors.WindowText : SystemColors.GrayText,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        ControlPaint.DrawBorder(e.Graphics, ClientRectangle, SystemColors.ControlDark, ButtonBorderStyle.Solid);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _hide.Dispose();
            _flag?.Dispose();
            _symbol.Dispose();
        }
        base.Dispose(disposing);
    }
}
