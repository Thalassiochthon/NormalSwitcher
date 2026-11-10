using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using RuSwitcher.Win.Core;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Tray;

/// <summary>A transient indicator anchored to the native Windows caret.</summary>
internal sealed class CaretBadge : Form
{
    private readonly System.Windows.Forms.Timer _hide = new() { Interval = 850 };
    private Bitmap? _flag;

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
            parameters.ExStyle |= 0x08000000 | 0x00000080 | 0x00000020; // no activate, tool window, transparent
            return parameters;
        }
    }

    public void ShowAtCaret(IntPtr layout)
    {
        if (InputTarget.Capture() is not { IsPasswordEdit: false } target) { Hide(); return; }
        uint thread = GetWindowThreadProcessId(target.Foreground, out _);
        var info = new GUITHREADINFO { cbSize = (uint)Marshal.SizeOf<GUITHREADINFO>() };
        if (thread == 0 || !GetGUIThreadInfo(thread, ref info) || info.hwndCaret == IntPtr.Zero)
        {
            Hide();
            return;
        }
        var caret = new POINT { X = info.caretRight, Y = info.caretBottom };
        if (!ClientToScreen(info.hwndCaret, ref caret)) { Hide(); return; }
        var work = Screen.FromPoint(new Point(caret.X, caret.Y)).WorkingArea;
        Location = new Point(Math.Clamp(caret.X + 5, work.Left, work.Right - Width),
            Math.Clamp(caret.Y + 3, work.Top, work.Bottom - Height));
        using var icon = LayoutIcon.Create(layout);
        _flag?.Dispose();
        _flag = icon.ToBitmap();
        Invalidate();
        Show();
        _hide.Stop();
        _hide.Start();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (_flag != null) e.Graphics.DrawImageUnscaled(_flag, 4, 2);
        ControlPaint.DrawBorder(e.Graphics, ClientRectangle, SystemColors.ControlDark, ButtonBorderStyle.Solid);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _hide.Dispose();
            _flag?.Dispose();
        }
        base.Dispose(disposing);
    }
}
