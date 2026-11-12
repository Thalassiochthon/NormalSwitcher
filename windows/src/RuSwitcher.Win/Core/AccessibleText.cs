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
        var focus = FindEditor(target, owner, out var text);
        if (focus is null || text is null || ReadVerifiedCaret(focus, text, suffix) is not { } caret)
            return false;

        // Hosted editors may share an HWND. Confirm the actual UIA element and caret again.
        if (InputTarget.Capture() != target || !focus.Equals(FindEditor(target, owner, out var currentText))
            || currentText is null || ReadVerifiedCaret(focus, currentText, suffix) is not { } currentCaret)
            return false;
        return caret.CompareEndpoints(TextPatternRangeEndpoint.Start, currentCaret, TextPatternRangeEndpoint.Start) == 0
            && InputTarget.Capture() == target;
    }

    private static AutomationElement? FindEditor(InputTarget target, uint owner, out TextPattern? text)
    {
        text = null;
        if (owner == 0) return null;
        var focused = AutomationElement.FocusedElement;
        if (EditorPattern(focused, owner) is { } direct)
        {
            text = direct;
            return focused;
        }

        // Some hosts report a container as the focused element. Search only its own focused
        // HWND, and require the provider to identify the child as currently focused.
        if (focused is not null && focused.Current.ProcessId != owner) return null;
        var root = AutomationElement.FromHandle(target.Focus);
        var child = root?.FindFirst(TreeScope.Descendants, new AndCondition(
            new PropertyCondition(AutomationElement.ProcessIdProperty, (int)owner),
            new PropertyCondition(AutomationElement.HasKeyboardFocusProperty, true),
            new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true)));
        text = EditorPattern(child, owner);
        return text is null ? null : child;
    }

    private static TextPattern? EditorPattern(AutomationElement? element, uint owner) =>
        element is not null && element.Current.ProcessId == owner && element.Current.HasKeyboardFocus
        && element.Current.IsEnabled
        && element.GetCurrentPropertyValue(AutomationElement.IsPasswordProperty, true) is false
        && element.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) ? pattern as TextPattern : null;

    private static TextPatternRange? ReadVerifiedCaret(AutomationElement focus, TextPattern text, string suffix)
    {
        var selection = text.GetSelection();
        if (selection.Length != 1
            || selection[0].CompareEndpoints(TextPatternRangeEndpoint.Start, selection[0], TextPatternRangeEndpoint.End) != 0)
            return null;

        var before = selection[0].Clone();
        if (before.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -suffix.Length) != -suffix.Length
            || !string.Equals(before.GetText(suffix.Length), suffix, StringComparison.Ordinal))
            return null;
        bool writable = focus.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && value is ValuePattern writableValue
            ? !writableValue.Current.IsReadOnly
            : before.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is false;
        return writable ? selection[0] : null;
    }
}
