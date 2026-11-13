using System.Runtime.InteropServices;
using System.Text;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>The focused control and its layout at the time a word was typed.</summary>
internal readonly record struct InputTarget(IntPtr Foreground, IntPtr Focus, IntPtr Layout)
{
    public static InputTarget? Capture()
    {
        var foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero) return null;
        uint thread = GetWindowThreadProcessId(foreground, out _);
        var info = new GUITHREADINFO { cbSize = (uint)Marshal.SizeOf<GUITHREADINFO>() };
        if (thread == 0 || !GetGUIThreadInfo(thread, ref info) || info.hwndFocus == IntPtr.Zero
            || (info.flags & (GUI_INMENUMODE | GUI_SYSTEMMENUMODE | GUI_POPUPMENUMODE)) != 0)
            return null;
        return new InputTarget(foreground, info.hwndFocus, GetKeyboardLayout(thread));
    }

    public bool SameControl(InputTarget other) => Foreground == other.Foreground && Focus == other.Focus;

    public bool IsPasswordEdit =>
        IsNativeEdit() && (GetWindowLongW(Focus, GWL_STYLE) & ES_PASSWORD) != 0;

    internal Task<bool> MatchesTextAtCaretAsync(string suffix)
    {
        if (!IsNativeEdit()) return AccessibleText.MatchesAtCaretAsync(this, suffix);
        if (TryReadNativeEdit(out string text, out int start, out int end))
            return Task.FromResult(MatchesSuffix(text, start, end, suffix));
        return IsWritableNativeEdit ? AccessibleText.MatchesAtCaretAsync(this, suffix) : Task.FromResult(false);
    }

    internal bool IsWritableNativeEdit =>
        IsNativeEdit() && (GetWindowLongW(Focus, GWL_STYLE) & (ES_PASSWORD | ES_READONLY)) == 0;

    /// <summary>Automatic editing requires a verifiable caret and exact suffix in a plain Win32 edit.</summary>
    public bool HasPlainTextAtCaret(string suffix) =>
        TryReadNativeEdit(out string text, out int start, out int end) && MatchesSuffix(text, start, end, suffix);

    internal bool TryReadNativeEdit(out string text, out int start, out int end)
    {
        text = "";
        start = end = 0;
        if (!IsWritableNativeEdit) return false;
        if (SendMessageTimeoutW(Focus, EM_GETSEL, IntPtr.Zero, IntPtr.Zero,
                SMTO_ABORTIFHUNG, 20, out var selection) == IntPtr.Zero)
            return false;
        long packed = selection.ToInt64();
        if (packed < 0 || packed == uint.MaxValue) return false;
        start = (int)(packed & 0xFFFF);
        end = (int)((packed >> 16) & 0xFFFF);
        var buffer = new StringBuilder(Math.Max(4096, end) + 1);
        if (SendMessageTimeoutTextW(Focus, WM_GETTEXT, (IntPtr)buffer.Capacity, buffer,
                SMTO_ABORTIFHUNG, 20, out _) == IntPtr.Zero)
            return false;
        text = buffer.ToString();
        return start <= end && end <= text.Length;
    }

    internal bool SelectNativeRange(int start, int end) =>
        SendMessageTimeoutW(Focus, EM_SETSEL, (IntPtr)start, (IntPtr)end, SMTO_ABORTIFHUNG, 20, out _) != IntPtr.Zero;

    internal static bool MatchesSuffix(string text, int start, int end, string suffix) =>
        suffix.Length > 0 && start == end && end >= suffix.Length && end <= text.Length
        && text.AsSpan(end - suffix.Length, suffix.Length).SequenceEqual(suffix.AsSpan());

    private bool IsNativeEdit()
    {
        var name = new StringBuilder(128);
        if (GetClassNameW(Focus, name, name.Capacity) == 0) return false;
        string windowClass = name.ToString();
        return windowClass.Equals("Edit", StringComparison.OrdinalIgnoreCase)
            || windowClass.StartsWith("RichEdit", StringComparison.OrdinalIgnoreCase)
            || windowClass.StartsWith("WindowsForms10.EDIT.", StringComparison.OrdinalIgnoreCase);
    }
}
