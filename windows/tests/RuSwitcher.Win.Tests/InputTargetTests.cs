using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class InputTargetTests
{
    [Theory]
    [InlineData("ghbdtn ", 7, 7, true)]
    [InlineData("ghbdtn v", 8, 8, false)]
    [InlineData("ghbdtn ", 6, 7, false)]
    [InlineData("ghbdtn ", 6, 6, false)]
    [InlineData("other ", 6, 6, false)]
    public void Automatic_edit_requires_the_expected_suffix_at_the_caret(
        string text, int start, int end, bool expected)
    {
        Assert.Equal(expected, InputTarget.MatchesSuffix(text, start, end, "ghbdtn "));
    }
}
