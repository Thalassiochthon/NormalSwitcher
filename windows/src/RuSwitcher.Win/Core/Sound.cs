using System.Media;

namespace RuSwitcher.Win.Core;

/// <summary>Optional system sound used by both layout switching and Settings preview.</summary>
internal static class Sound
{
    public const string Default = "default";

    internal static IReadOnlyList<string> Choices { get; } =
        [Default, "beep", "exclamation", "question", "hand"];

    public static void Switch()
    {
        if (Settings.Current.SoundOnSwitch)
            Play(Settings.Current.LayoutSound);
    }

    internal static void Play(string sound)
    {
        var cue = sound switch
        {
            "beep" => SystemSounds.Beep,
            "exclamation" => SystemSounds.Exclamation,
            "question" => SystemSounds.Question,
            "hand" => SystemSounds.Hand,
            _ => SystemSounds.Asterisk,
        };
        try { cue.Play(); }
        catch { /* The sound is unavailable. */ }
    }
}
