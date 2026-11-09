using System.Media;

namespace RuSwitcher.Win.Core;

/// <summary>Optional audible cue on layout change — the Windows counterpart of the macOS
/// issue-#7 layout sound. Off by default; uses a light system sound. Never throws.</summary>
internal static class Sound
{
    public static void Switch()
    {
        if (!Settings.Current.SoundOnSwitch) return;
        try { SystemSounds.Asterisk.Play(); } catch { /* no audio device — ignore */ }
    }
}
