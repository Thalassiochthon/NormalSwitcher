namespace RuSwitcher.Win.Core;

/// <summary>Two-letter conversion allowlists from macOS. Known collisions are present in both lists.</summary>
internal static class ShortWords
{
    private static readonly HashSet<string> Russian = new(
        "не ты на он мы вы да но за бы же из ну по то от их ее её со ли ни об ей во им ко те та уж ок эй до ой ах ох ух эх хм ха ща"
            .Split(' '), StringComparer.Ordinal);
    private static readonly HashSet<string> English = new(
        "to it of is in we me he my on do no be so go if up at as an us or by am ok hi oh ah um mr ya vs dj kb jr bp ye ds jq im"
            .Split(' '), StringComparer.Ordinal);

    public static bool Contains(string word, string tag) => tag.Split('-')[0] switch
    {
        "en" => English.Contains(word),
        "ru" => Russian.Contains(word),
        _ => false,
    };
}
