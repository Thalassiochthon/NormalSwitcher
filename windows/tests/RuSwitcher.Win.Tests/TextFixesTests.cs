using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class TextFixesTests
{
    [Theory]
    [InlineData("КОгда", "Когда")]
    [InlineData("HEllo", "Hello")]
    [InlineData("PCs", null)]
    [InlineData("HELLO", null)]
    [InlineData("H3llo", null)]
    public void Corrects_only_two_initial_capitals(string typed, string? expected)
    {
        Assert.Equal(expected, TextFixes.TwoCaps(typed, _ => true));
        Assert.Null(TextFixes.TwoCaps(typed, _ => false));
    }

    [Fact]
    public void Numbers_use_the_separator_from_the_alternative_layout()
    {
        TypedKey[] keys = [new(0, 0x02, false, false), new(0, 0x34, false, false), new(0, 0x09, false, false)];
        Assert.Equal("1.8", TextFixes.Number(keys, "1ю8", _ => '.'));
        Assert.Null(TextFixes.Number(keys, "1ю8", _ => 'x'));
        Assert.Null(TextFixes.Number(keys, "1юx", _ => '.'));
    }

    [Fact]
    public void Typo_requires_exactly_one_dictionary_match_and_a_known_invalid_original()
    {
        var typed = "gello";
        TypedKey[] keys = [new(0, 0x22, false, false), new(0, 0x12, false, false), new(0, 0x26, false, false),
            new(0, 0x26, false, false), new(0, 0x18, false, false)];
        static char? Character(TypedKey key) => key.ScanCode switch { 0x23 => 'h', 0x21 => 'f', _ => null };
        Assert.Equal("hello", TextFixes.Typo(keys, typed, Character, _ => false, word => word == "hello"));
        Assert.Null(TextFixes.Typo(keys, typed, Character, _ => false, word => word is "hello" or "fello"));
        Assert.Null(TextFixes.Typo(keys, typed, Character, _ => null, word => word == "hello"));
    }

    [Fact]
    public void Dictionary_packs_are_embedded_and_partitioned_by_language()
    {
        Assert.True(FrequencyWords.Contains("hello", "en-US"));
        Assert.True(FrequencyWords.Contains("привет", "ru-RU"));
        Assert.False(FrequencyWords.Contains("привет", "en-US"));
        Assert.False(FrequencyWords.Contains("hello", "es-ES"));
    }
}
