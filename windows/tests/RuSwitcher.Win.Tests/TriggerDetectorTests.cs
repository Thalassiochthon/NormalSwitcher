using RuSwitcher.Win.Core;
using Xunit;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Tests;

public class TriggerDetectorTests
{
    [Fact]
    public void Right_control_binding_ignores_the_left_control_key()
    {
        var detector = new TriggerDetector(TriggerKind.RightCtrlDoubleTap);
        int calls = 0;
        detector.Triggered += () => calls++;
        Tap(detector, VK_LCONTROL);
        Tap(detector, VK_LCONTROL);
        Assert.Equal(0, calls);
        Tap(detector, VK_RCONTROL);
        Tap(detector, VK_RCONTROL);
        Assert.Equal(1, calls);
    }

    [Fact]
    public void Single_modifier_tap_does_not_interfere_with_a_normal_shortcut()
    {
        var detector = new TriggerDetector(TriggerKind.CtrlTap);
        int calls = 0;
        detector.Triggered += () => calls++;
        detector.OnKeyDown(VK_LCONTROL);
        detector.OnKeyDown(VK_C);
        detector.OnKeyUp(VK_C);
        detector.OnKeyUp(VK_LCONTROL);
        Assert.Equal(0, calls);
        Tap(detector, VK_LCONTROL);
        Assert.Equal(1, calls);
    }

    private static void Tap(TriggerDetector detector, uint key)
    {
        detector.OnKeyDown(key);
        detector.OnKeyUp(key);
    }
}
