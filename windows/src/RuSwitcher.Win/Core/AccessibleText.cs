using System.Drawing;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>Checks the text immediately before the caret in a non-native editor via UI Automation.</summary>
internal static class AccessibleText
{
    private static int _worker;
    private static int _badgeWorker;

    internal readonly record struct BadgeAnchor(Rectangle Bounds, bool IsCaret);

    public static async Task<BadgeAnchor?> FindBadgeAnchorAsync(InputTarget target)
    {
        // A slow accessibility provider must not block keystrokes or queue up work on every tick.
        if (Interlocked.CompareExchange(ref _badgeWorker, 1, 0) != 0) return null;
        var probe = Task.Run(() =>
        {
            try { return FindBadgeAnchor(target); }
            catch (Exception) { return null; }
            finally { Volatile.Write(ref _badgeWorker, 0); }
        });
        try { return await probe.WaitAsync(TimeSpan.FromMilliseconds(160)).ConfigureAwait(false); }
        catch (TimeoutException) { return null; }
    }

    private static BadgeAnchor? FindBadgeAnchor(InputTarget target)
    {
        if (InputTarget.Capture() != target) return null;
        GetWindowThreadProcessId(target.Foreground, out uint owner);
        var focus = FindEditor(target, owner, out var text);
        if (focus is null || text is null || focus.Current.IsOffscreen) return null;
        var selection = text.GetSelection();
        var range = selection.Length == 1 ? selection[0] : null;
        if (!IsWritable(focus, range ?? text.DocumentRange)) return null;

        BadgeAnchor? anchor = null;
        if (range is not null &&
            range.CompareEndpoints(TextPatternRangeEndpoint.Start, range, TextPatternRangeEndpoint.End) == 0)
        {
            // A collapsed UI Automation range has no bounding rectangle. Its neighboring
            // visible character supplies the screen position, including in custom editors.
            if ((AdjacentCaret(range, following: true) ?? AdjacentCaret(range, following: false)) is { } caret)
                anchor = new BadgeAnchor(caret, IsCaret: true);
        }
        if (anchor is null && ScreenRectangle(focus.Current.BoundingRectangle) is { } bounds)
            anchor = new BadgeAnchor(bounds, IsCaret: false);
        return InputTarget.Capture() == target && focus.Current.HasKeyboardFocus ? anchor : null;
    }

    private static Rectangle? AdjacentCaret(TextPatternRange caret, bool following)
    {
        var range = caret.Clone();
        int moved = range.MoveEndpointByUnit(following ? TextPatternRangeEndpoint.End : TextPatternRangeEndpoint.Start,
            TextUnit.Character, following ? 1 : -1);
        if (moved == 0) return null;
        var boxes = range.GetBoundingRectangles();
        if (boxes.Length != 1 || ScreenRectangle(boxes[0]) is not { } box) return null;
        string glyph = range.GetText(2);
        if (string.IsNullOrEmpty(glyph) || glyph.Any(char.IsControl)) return null;

        bool rightToLeft;
        if (range.GetAttributeValue(TextPattern.TextFlowDirectionsAttribute) is FlowDirections direction)
            rightToLeft = (direction & FlowDirections.RightToLeft) != 0;
        else if (glyph.All(c => c <= '~' || c is >= '\u00C0' and <= '\u024F' or >= '\u0400' and <= '\u052F'))
            rightToLeft = false;
        else
            return null;

        int x = following != rightToLeft ? box.Left : box.Right;
        return new Rectangle(x, box.Top, 1, box.Height);
    }

    private static Rectangle? ScreenRectangle(System.Windows.Rect rect)
    {
        if (rect.IsEmpty || rect.Width <= 0 || rect.Height <= 0 ||
            !double.IsFinite(rect.Left) || !double.IsFinite(rect.Top) ||
            !double.IsFinite(rect.Right) || !double.IsFinite(rect.Bottom)) return null;
        var bounds = Rectangle.Round(new RectangleF((float)rect.X, (float)rect.Y, (float)rect.Width, (float)rect.Height));
        return bounds.Width > 0 && bounds.Height > 0 ? bounds : null;
    }


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
        return IsWritable(focus, before) ? selection[0] : null;
    }

    private static bool IsWritable(AutomationElement focus, TextPatternRange range) =>
        focus.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && value is ValuePattern writableValue
            ? !writableValue.Current.IsReadOnly
            : range.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is false;
}
