using System.Windows.Automation;
using System.Windows.Automation.Text;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>Checks the text immediately before the caret in a non-native editor via UI Automation.</summary>
internal static class AccessibleText
{
    private static int _worker;

    public static async Task<bool> MatchesAtCaretAsync(InputTarget target, string suffix)
    {
        // Some applications have an unresponsive provider. Allow only one outstanding call and
        // keep the keyboard-hook thread free even if that provider never answers.
        if (Interlocked.CompareExchange(ref _worker, 1, 0) != 0) return false;
        var check = Task.Run(() =>
        {
            try { return MatchesAtCaret(target, suffix); }
            catch (Exception) { return false; }
            finally { Volatile.Write(ref _worker, 0); }
        });

        try { return await check.WaitAsync(TimeSpan.FromMilliseconds(250)).ConfigureAwait(false); }
        catch (TimeoutException) { return false; }
    }

    private static bool MatchesAtCaret(InputTarget target, string suffix)
    {
        if (InputTarget.Capture() != target) return false;
        GetWindowThreadProcessId(target.Foreground, out uint owner);
        var focus = AutomationElement.FocusedElement;
        if (focus == null || focus.Current.ProcessId != owner || !focus.Current.HasKeyboardFocus
            || !focus.Current.IsEnabled
            || focus.GetCurrentPropertyValue(AutomationElement.IsPasswordProperty, true) is not false
            || focus.Current.ControlType != ControlType.Edit
            || !focus.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) || pattern is not TextPattern text)
            return false;

        var selection = text.GetSelection();
        if (selection.Length != 1
            || selection[0].CompareEndpoints(TextPatternRangeEndpoint.Start, selection[0], TextPatternRangeEndpoint.End) != 0)
            return false;

        var before = selection[0].Clone();
        if (before.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -suffix.Length) != -suffix.Length
            || !string.Equals(before.GetText(suffix.Length), suffix, StringComparison.Ordinal))
            return false;
        bool writable = focus.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && value is ValuePattern writableValue
            ? !writableValue.Current.IsReadOnly
            : before.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is false;
        return writable && focus.Equals(AutomationElement.FocusedElement) && InputTarget.Capture() == target;
    }
}
