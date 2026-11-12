using System.Media;

namespace RuSwitcher.Win.Core;

/// <summary>Optional layout cue and Settings preview using the bundled NormalSwitcher sounds.</summary>
internal static class Sound
{
    public const string Default = "default";
    internal static IReadOnlyList<string> Choices { get; } =
        [Default, "tap", "double", "wood", "drop", "rise", "glass", "soft", "pulse"];

    private static readonly Dictionary<string, SoundPlayer> Players = new(StringComparer.Ordinal);

    internal static string Resolve(string? sound) => sound switch
    {
        "beep" => "tap",
        "exclamation" => "drop",
        "question" => "rise",
        "hand" => "wood",
        _ => sound is not null && Choices.Contains(sound) ? sound : Default,
    };

    internal static long LayoutKey(IntPtr layout) => layout.ToInt64() & 0xFFFFFFFF;

    public static void Switch(IntPtr layout)
    {
        var settings = Settings.Current;
        if (settings.SoundOnSwitch && layout != IntPtr.Zero)
            Play(settings.LayoutSounds.GetValueOrDefault(LayoutKey(layout), settings.LayoutSound));
    }

    internal static void Play(string? sound)
    {
        string name = Resolve(sound);
        if (name == Default) name = "tap";
        try
        {
            if (!Players.TryGetValue(name, out var player))
            {
                Stream? audio = typeof(Sound).Assembly.GetManifestResourceStream($"LayoutSounds.{name}.wav");
                if (audio is null) return;
                player = new SoundPlayer(audio);
                Players.Add(name, player);
            }
            player.Play();
        }
        catch { /* Keep switching available if audio playback fails. */ }
    }
}
