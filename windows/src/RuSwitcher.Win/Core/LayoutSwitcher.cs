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

    /// <summary>The other layout of the pair (MVP: the first installed HKL that isn't current).</summary>
    public static IntPtr? Opposite()
    {
        IntPtr cur = Current();
        foreach (var hkl in Installed())
            if (hkl != cur) return hkl;
        return null;
    }

    /// <summary>Switch the focused window to <paramref name="hkl"/>.</summary>
    public static void SwitchTo(IntPtr hkl)
    {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd != IntPtr.Zero)
            PostMessageW(hwnd, WM_INPUTLANGCHANGEREQUEST, IntPtr.Zero, hkl);
        Sound.Switch();   // issue #7: optional cue on layout change
    }
}
