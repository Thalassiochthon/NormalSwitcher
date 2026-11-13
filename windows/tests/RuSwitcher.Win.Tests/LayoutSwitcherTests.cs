using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class LayoutSwitcherTests
{
    [Theory]
    [InlineData(0x0419, 0x0409)]
    [InlineData(0x0409, 0x0C0A)]
    [InlineData(0x0C0A, 0x0419)]
    [InlineData(0, 0x0419)]
    public void SwitchCyclesRussianEnglishAndSpanish(int current, int expected)
    {
        IntPtr[] installed = [new(0x0419), new(0x0409), new(0x0C0A)];
        Assert.Equal((IntPtr?)new IntPtr(expected), LayoutSwitcher.NextInstalled(new IntPtr(current), installed));
    }

    [Fact]
    public void SwitchDoesNothingWithOneLayout()
    {
        var russian = new IntPtr(0x0419);
        Assert.Null(LayoutSwitcher.NextInstalled(russian, [russian]));
    }
}
