using System.Runtime.InteropServices;
using System.Windows.Forms;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Orchestrates a manual conversion of the last typed word: take the buffer, render it in the
/// opposite layout, delete + reinsert, then switch the layout — the Windows counterpart of the
/// macOS <c>AppDelegate.onAltTap</c>. A second trigger with no typing in between reverses it
/// (reconvert/undo, toggling back and forth) — the counterpart of <c>onAltReconvert</c>.
/// </summary>
internal static class Converter
{
    // Last conversion, for reconvert. "_a" is what's currently on screen; "_b" is the alternative.
    // Each side carries its layout so reconvert also restores the right keyboard layout.
    private static string _aText = "";
    private static string _bText = "";
    private static IntPtr _aHkl;
    private static IntPtr _bHkl;
    private static bool _lastWasAuto;   // last conversion came from as-you-type auto (learn-from-undo)

    /// <summary>True if the last conversion can be reversed (nothing typed since).</summary>
    public static bool CanReconvert => _aText.Length > 0;

    /// <summary>Any real typing invalidates a pending reconvert (the word on screen changed).</summary>
    public static void ClearReconvert() { _aText = ""; _bText = ""; _lastWasAuto = false; }

    /// <summary>Record an auto-conversion so the trigger can reverse it — and so reversing it teaches
    /// an exception (learn-from-undo). <paramref name="onScreen"/> is what's now shown; the
    /// <paramref name="alternative"/> is the original typed word restored on undo.</summary>
    public static void NoteAutoConversion(string onScreen, string alternative, IntPtr onScreenHkl, IntPtr altHkl, bool learn = true)
    {
        _aText = onScreen; _aHkl = onScreenHkl;
        _bText = alternative; _bHkl = altHkl;
        _lastWasAuto = learn;
    }

    // Trailing keys whose char in the CURRENT layout is sentence punctuation are kept literally,
    // not converted — otherwise «ghbdtn,» would become «приветб» (the comma key is «б» in ЙЦУКЕН).
    // issue #15. The ambiguous ю/б/ж tails (e.g. «зуб» = "pe,") are left to the user, as on macOS.
    private static readonly HashSet<char> TrailingPunct = new() { ',', '.', '!', '?', ';', ':', ')' };

    /// <summary>Convert the buffered word into the opposite layout. Returns true if it acted.</summary>
    public static bool ConvertLastWord(KeystrokeBuffer buffer)
    {
        if (buffer.IsEmpty) return false;

        IntPtr activeHkl = LayoutSwitcher.Current();
        var keys = buffer.CurrentWord;
        IntPtr sourceHkl = KeyMapper.TextLayout(keys, activeHkl);
        if (LayoutSwitcher.CorrectionTarget(sourceHkl) is not { } targetHkl) return false;

        // Split off trailing real punctuation (kept as typed).
        int coreCount = keys.Count;
        var suffix = new System.Text.StringBuilder();
        while (coreCount > 0 &&
               KeyMapper.TranslateIn(keys[coreCount - 1], sourceHkl) is { } pc && TrailingPunct.Contains(pc))
        {
            suffix.Insert(0, pc);
            coreCount--;
        }
        if (coreCount == 0) return false;   // nothing but punctuation

        var core = new List<TypedKey>(coreCount);
        for (int i = 0; i < coreCount; i++) core.Add(keys[i]);
        string suf = suffix.ToString();

        string convertedCore = KeyMapper.ConvertWord(core, sourceHkl, targetHkl);
        if (convertedCore.Length == 0) return false;
        string originalCore = KeyMapper.ConvertWord(core, sourceHkl);  // as it was typed

        string converted = convertedCore + suf;
        string original = originalCore + suf;

        if (original.Length != coreCount + suf.Length || original == converted
            || !TextInjector.Replace(backspaces: original.Length, text: converted)) return false;
        LayoutSwitcher.SwitchTo(targetHkl);

        _aText = converted; _aHkl = targetHkl;   // now on screen
        _bText = original;  _bHkl = sourceHkl;    // the alternative (undo target)
        _lastWasAuto = false;                     // a manual convert isn't subject to learn-from-undo
        buffer.Reset();
        return true;
    }

    /// <summary>Reverse the last conversion (and toggle for a repeated trigger).</summary>
    public static bool Reconvert()
    {
        if (_aText.Length == 0) return false;

        if (!TextInjector.Replace(backspaces: _aText.Length, text: _bText)) return false;

        // Learn-from-undo: reversing an auto-conversion means the user rejected it — remember never to
        // auto-convert that typed word again (mirrors the macOS learn-from-undo).
        if (_lastWasAuto)
        {
            string word = LetterCoreLower(_bText);   // _bText is the original typed word being restored
            var never = Settings.Current.NeverConvert;
            if (word.Length >= 2 && !never.Contains(word))
            {
                never.Add(word);
                Settings.Current.Save();
            }
            _lastWasAuto = false;   // only teach once
        }

        LayoutSwitcher.SwitchTo(_bHkl);

        (_aText, _bText) = (_bText, _aText);   // toggle: a third trigger redoes the conversion
        (_aHkl, _bHkl) = (_bHkl, _aHkl);
        return true;
    }

    /// <summary>Convert the current selection via a clipboard round-trip (the counterpart of the
    /// macOS <c>convertViaClipboard</c>): Ctrl+C → convert the text char-by-char in the opposite
    /// layout → Ctrl+V, restoring the user's clipboard afterwards. One-way flip by the current
    /// layout (smart per-word conversion is a later parity step). No selection / no-op → false.
    /// MUST run on the message loop (STA), never inside the hook callback.</summary>
    public static bool ConvertSelection(bool smart)
    {
        IntPtr sourceHkl = LayoutSwitcher.Current();
        if (LayoutSwitcher.CorrectionTarget(sourceHkl) is not { } targetHkl) return false;

        return TransformSelection(sel => Settings.Current.ConvertByText ? KeyMapper.ConvertByText(sel, sourceHkl, targetHkl)
            : smart ? SmartConvert.Selection(sel, sourceHkl, targetHkl)
            : KeyMapper.ConvertText(sel, sourceHkl, targetHkl));
    }

    internal static bool ChangeSelectionCase(bool wholeLine)
    {
        if (InputTarget.Capture() is { IsWritableNativeEdit: true } target)
        {
            if (!target.TryReadNativeEdit(out var text, out int start, out int end)) return false;
            if (wholeLine)
            {
                int previousLine = start > 0 ? text.LastIndexOf('\n', start - 1) : -1;
                int nextLine = text.IndexOf('\n', end);
                start = previousLine + 1;
                end = nextLine < 0 ? text.Length : nextLine;
                if (end > start && text[end - 1] == '\r') end--;
            }
            if (end <= start || InputTarget.Capture() is not { } focused || !target.SameControl(focused)) return false;
            string selection = text[start..end];
            string changed = ToggleCase(selection);
            return changed != selection && target.SelectNativeRange(start, end)
                && InputTarget.Capture() is { } active && target.SameControl(active)
                && TextInjector.Replace(0, changed);
        }

        if (wholeLine)
        {
            TextInjector.SendShift(VK_HOME);
            Thread.Sleep(40);
        }
        return TransformSelection(ToggleCase);
    }

    private static string ToggleCase(string text) =>
        text == text.ToUpperInvariant() ? text.ToLowerInvariant() : text.ToUpperInvariant();

    internal static void WithSelectedWord(Action<string> action)
    {
        TransformSelection(text =>
        {
            string word = text.Trim();
            if (word.Length > 1 && word.All(char.IsLetter)) action(word.ToLowerInvariant());
            return text;
        });
    }

    internal static string CaseVariant(string word, int variant) => variant switch
    {
        0 => word.ToUpperInvariant(),
        1 => word.ToLowerInvariant(),
        _ => word[..1].ToUpperInvariant() + word[1..].ToLowerInvariant()
    };

    private static bool TransformSelection(Func<string, string> transform)
    {
        if (InputTarget.Capture() is not { IsPasswordEdit: false } target) return false;
        uint initial = GetClipboardSequenceNumber();
        uint owned = 0;
        IDataObject? saved = null;
        try
        {
            saved = Clipboard.GetDataObject();
            if (GetClipboardSequenceNumber() != initial || !TextInjector.SendCtrl(VK_C)) return false;
            Thread.Sleep(60); // The source processes Copy on its own UI thread.

            uint copied = GetClipboardSequenceNumber();
            if (copied == initial || copied == 0) return false;
            GetWindowThreadProcessId(target.Foreground, out uint targetProcess);
            GetWindowThreadProcessId(GetClipboardOwner(), out uint owner);
            if (targetProcess == 0 || owner != targetProcess) return false;
            owned = copied;
            string selected = Clipboard.GetText(TextDataFormat.UnicodeText);
            if (selected.Length == 0 || GetClipboardSequenceNumber() != owned) return false;

            string converted = transform(selected);
            if (converted == selected || GetClipboardSequenceNumber() != owned
                || InputTarget.Capture() is not { IsPasswordEdit: false } current || !target.SameControl(current))
                return false;

            Clipboard.SetText(converted, TextDataFormat.UnicodeText);
            owned = GetClipboardSequenceNumber();
            if (!TextInjector.SendCtrl(VK_V)) return false;
            Thread.Sleep(60); // Let the focused control take the clipboard before restoring it.
            return true;
        }
        catch (ExternalException) { return false; }
        finally
        {
            if (owned != 0 && GetClipboardSequenceNumber() == owned)
            {
                try
                {
                    if (saved == null) Clipboard.Clear();
                    else Clipboard.SetDataObject(saved, copy: true, retryTimes: 4, retryDelay: 20);
                }
                catch (ExternalException) { }
            }
        }
    }

    /// <summary>issue #24: convert the whole current line — select it with Shift+Home, then run
    /// the selection conversion. Works in normal apps and terminals that support Shift+Home
    /// selection. On a no-op, collapse the selection (End) so the line isn't left highlighted.</summary>
    public static bool ConvertLine(bool smart)
    {
        TextInjector.SendShift(VK_HOME);   // select from cursor to line start
        Thread.Sleep(40);
        bool ok = ConvertSelection(smart);
        if (!ok) TextInjector.SendKey(VK_END);   // drop the selection (go to line end)
        return ok;
    }

    // Trim non-letters off both ends and lowercase — the key used for the never-convert exception list.
    private static string LetterCoreLower(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && !char.IsLetter(s[a])) a++;
        while (b > a && !char.IsLetter(s[b - 1])) b--;
        return s.Substring(a, b - a).ToLowerInvariant();
    }

}
