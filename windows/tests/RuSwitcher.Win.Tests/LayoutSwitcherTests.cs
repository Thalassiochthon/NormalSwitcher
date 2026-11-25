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
    public void SwitchUsesTheSystemOrderWithTwoOrFourLayouts()
    {
        IntPtr[] installed = [new(0x0C0A), new(0x0419), new(0x040C), new(0x0409)];
        foreach (int count in new[] { 2, 4 })
        {
            var cycle = installed[..count];
            for (int index = 0; index < count; index++)
                Assert.Equal((IntPtr?)cycle[(index + 1) % count], LayoutSwitcher.NextInstalled(cycle[index], cycle));
        }
    }

    [Fact]
    public void SwitchDoesNothingWithOneLayout()
    {
        var russian = new IntPtr(0x0419);
        Assert.Null(LayoutSwitcher.NextInstalled(russian, [russian]));
    }

    [Fact]
    public void AutomaticCorrectionConsidersSpanishAndPreservesAnExplicitPair()
    {
        IntPtr russian = new(0x0419), english = new(0x0409), spanish = new(0x0C0A);
        IntPtr[] installed = [russian, english, spanish];
        Assert.Equal(new[] { english, spanish },
            LayoutSwitcher.ConversionTargets(russian, installed, russian, IntPtr.Zero).ToArray());
        Assert.Equal(new[] { russian, english },
            LayoutSwitcher.ConversionTargets(spanish, installed, IntPtr.Zero, IntPtr.Zero).ToArray());
        Assert.Equal(new[] { english },
            LayoutSwitcher.ConversionTargets(russian, installed, russian, english).ToArray());
        Assert.Empty(LayoutSwitcher.ConversionTargets(spanish, installed, russian, english));
    }
}
