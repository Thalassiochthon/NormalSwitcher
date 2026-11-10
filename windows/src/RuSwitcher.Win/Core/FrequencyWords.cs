using System.IO.Compression;
using System.Text;

namespace RuSwitcher.Win.Core;

internal static class FrequencyWords
{
    private static readonly Lazy<HashSet<string>> English = new(() => Load("en"));
    private static readonly Lazy<HashSet<string>> Russian = new(() => Load("ru"));

    internal static bool Contains(string word, string tag)
    {
        string language = tag.Split('-')[0];
        return language switch
        {
            "en" => English.Value.Contains(word),
            "ru" => Russian.Value.Contains(word),
            _ => false,
        };
    }

    private static HashSet<string> Load(string language)
    {
        using var raw = typeof(FrequencyWords).Assembly.GetManifestResourceStream($"WordPacks.{language}.deflate")
            ?? throw new InvalidDataException($"Missing {language} word pack");
        using var unpacked = new DeflateStream(raw, CompressionMode.Decompress);
        using var reader = new StreamReader(unpacked, Encoding.UTF8);
        var words = new HashSet<string>(StringComparer.Ordinal);
        while (reader.ReadLine() is { } word) words.Add(word);
        return words;
    }
}
