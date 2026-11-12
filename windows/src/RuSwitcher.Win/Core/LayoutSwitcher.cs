using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Installed layouts, the current/opposite pair, and switching — the Windows counterpart
/// of the macOS <c>LayoutSwitcher</c> (TIS). Layout switch is sent to the focused window
/// via WM_INPUTLANGCHANGEREQUEST, so it takes effect where the text actually is.
/// </summary>
internal static class LayoutSwitcher
{
    /// <summary>All installed keyboard layouts (HKLs).</summary>
    public static IntPtr[] Installed()
    {
        int n = GetKeyboardLayoutList(0, null);
        if (n <= 0) return Array.Empty<IntPtr>();
        var list = new IntPtr[n];
        GetKeyboardLayoutList(n, list);
        return list;
    }

    /// <summary>HKL of the layout active in the focused window's thread.</summary>
    public static IntPtr Current()
    {
        IntPtr hwnd = GetForegroundWindow();
        uint tid = GetWindowThreadProcessId(hwnd, out _);
        return GetKeyboardLayout(tid);
    }

    public static IntPtr? Opposite()
    {
        foreach (var layout in ConversionTargets(Current())) return layout;
        return null;
    }

    internal static IEnumerable<IntPtr> ConversionTargets(IntPtr current)
    {
        var settings = Settings.Current;
        var layouts = Installed();
        var first = new IntPtr(settings.FirstLayout);
        var second = new IntPtr(settings.SecondLayout);
        if (first != second && layouts.Contains(first) && layouts.Contains(second))
        {
            if (current == first) yield return second;
            else if (current == second) yield return first;
            yield break;
        }

        foreach (var layout in layouts)
            if (layout != current) yield return layout;
    }

    internal static IntPtr Preferred(bool first)
    {
        var settings = Settings.Current;
        var installed = Installed();
        var preferred = new IntPtr(first ? settings.FirstLayout : settings.SecondLayout);
        return preferred != IntPtr.Zero && installed.Contains(preferred)
            ? preferred : installed.ElementAtOrDefault(first ? 0 : 1);
    }

    /// <summary>Switch the focused window to <paramref name="hkl"/>.</summary>
    public static void SwitchTo(IntPtr hkl) => SwitchTo(hkl, GetForegroundWindow());

    internal static void SwitchTo(IntPtr hkl, IntPtr hwnd)
    {
        if (hwnd != IntPtr.Zero)
            PostMessageW(hwnd, WM_INPUTLANGCHANGEREQUEST, IntPtr.Zero, hkl);
    }
}
