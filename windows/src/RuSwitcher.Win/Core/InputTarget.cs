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

    internal Task<bool> MatchesTextAtCaretAsync(string suffix) =>
        IsNativeEdit() ? Task.FromResult(HasPlainTextAtCaret(suffix)) : AccessibleText.MatchesAtCaretAsync(this, suffix);

    internal bool IsWritableNativeEdit =>
        IsNativeEdit() && (GetWindowLongW(Focus, GWL_STYLE) & (ES_PASSWORD | ES_READONLY)) == 0;

    /// <summary>Automatic editing requires a verifiable caret and exact suffix in a plain Win32 edit.</summary>
    public bool HasPlainTextAtCaret(string suffix)
    {
        if (!IsWritableNativeEdit) return false;
        if (SendMessageTimeoutW(Focus, EM_GETSEL, IntPtr.Zero, IntPtr.Zero,
                SMTO_ABORTIFHUNG, 20, out var selection) == IntPtr.Zero)
            return false;
        long packed = selection.ToInt64();
        if (packed < 0) return false;
        int start = (int)(packed & 0xFFFF), end = (int)((packed >> 16) & 0xFFFF);
        const int maxRead = 4096;
        if (start != end || end < suffix.Length || end > maxRead) return false;

        var text = new StringBuilder(maxRead + 1);
        if (SendMessageTimeoutTextW(Focus, WM_GETTEXT, (IntPtr)text.Capacity, text,
                SMTO_ABORTIFHUNG, 20, out _) == IntPtr.Zero)
            return false;
        return MatchesSuffix(text.ToString(), start, end, suffix);
    }

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
