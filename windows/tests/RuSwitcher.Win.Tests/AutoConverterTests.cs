using System;
using System.Collections.Generic;
using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

/// <summary>Covers the ported <c>LayoutDetector.decide</c> verdict (AutoConverter.ShouldConvertPure)
/// — the trickiest auto-conversion logic — with the dictionary and exception lists injected.</summary>
public class AutoConverterTests
{
    private static readonly ICollection<string> None = new List<string>();

    // A tiny fake dictionary: (word, langTag) pairs that are "real words".
    private static Func<string, string, bool> Dict(params (string word, string tag)[] valid)
    {
        var set = new HashSet<(string, string)>(valid);
        return (w, t) => set.Contains((w, t));
    }

    [Fact]
    public void Converts_gibberish_that_becomes_a_real_word()
    {
        // "ghbdtn" (EN) → "привет" (RU): not a word in en, a word in ru → convert.
        bool r = AutoConverter.ShouldConvertPure("ghbdtn", "привет", "en", "ru",
            caps: false, dictAvailable: true, Dict(("привет", "ru")), None, None);
        Assert.True(r);
    }

    [Fact]
    public void Keeps_a_word_that_is_already_real_in_the_typed_layout()
    {
        // "test" is a real en word; even though it maps to some ru string, keep it.
        bool r = AutoConverter.ShouldConvertPure("test", "етые", "en", "ru",
            caps: false, dictAvailable: true, Dict(("test", "en"), ("етые", "ru")), None, None);
        Assert.False(r);
    }

    [Fact]
    public void Keeps_when_the_flipped_form_is_not_a_real_word()
    {
        bool r = AutoConverter.ShouldConvertPure("qwerty", "йцукен", "en", "ru",
            caps: false, dictAvailable: true, Dict(/* neither is valid */), None, None);
        Assert.False(r);
    }

    [Theory]
    [InlineData("ab")]     // 1–2 letters: too many collisions
    [InlineData("no")]
    public void Keeps_words_shorter_than_three_letters(string typed)
    {
        bool r = AutoConverter.ShouldConvertPure(typed, "хх", "en", "ru",
            caps: false, dictAvailable: true, Dict(("хх", "ru")), None, None);
        Assert.False(r);
    }

    [Fact]
    public void Keeps_tokens_with_non_letters()
    {
        // digits / punctuation → URL/code/email territory, never auto-convert.
        bool r = AutoConverter.ShouldConvertPure("ab12", "фид", "en", "ru",
            caps: false, dictAvailable: true, Dict(("фид", "ru")), None, None);
        Assert.False(r);
    }

    [Fact]
    public void Keeps_all_caps_acronyms_when_caps_lock_off()
    {
        bool r = AutoConverter.ShouldConvertPure("USA", "гыф", "en", "ru",
            caps: false, dictAvailable: true, Dict(("гыф", "ru")), None, None);
        Assert.False(r);
    }

    [Fact]
    public void Keeps_camel_case_identifiers()
    {
        bool r = AutoConverter.ShouldConvertPure("myVar", "туМфк", "en", "ru",
            caps: false, dictAvailable: true, Dict(("туМфк", "ru")), None, None);
        Assert.False(r);
    }

    [Fact]
    public void Always_list_forces_conversion_even_for_short_words()
    {
        var always = new List<string> { "жоппа" };
        bool r = AutoConverter.ShouldConvertPure(";jggf", "жоппа", "en", "ru",
            caps: false, dictAvailable: true, Dict(), None, always);
        Assert.True(r);
    }

    [Fact]
    public void Never_list_blocks_a_would_be_conversion()
    {
        var never = new List<string> { "ghbdtn" };
        bool r = AutoConverter.ShouldConvertPure("ghbdtn", "привет", "en", "ru",
            caps: false, dictAvailable: true, Dict(("привет", "ru")), never, None);
        Assert.False(r);
    }

    [Fact]
    public void Without_a_dictionary_it_never_auto_converts()
    {
        bool r = AutoConverter.ShouldConvertPure("ghbdtn", "привет", "en", "ru",
            caps: false, dictAvailable: false, Dict(("привет", "ru")), None, None);
        Assert.False(r);
    }

    [Fact]
    public void Hebrew_converts_only_on_positive_signal_from_the_other_side()
    {
        // Typed in the Hebrew layout, its EN image is a real English word → convert.
        bool r = AutoConverter.ShouldConvertPure("akuo", "hello", "he", "en",
            caps: false, dictAvailable: true, Dict(("hello", "en")), None, None);
        Assert.True(r);
    }

    [Fact]
    public void Never_auto_converts_toward_hebrew()
    {
        // Typed on the non-Hebrew side: direction toward Hebrew is unresolvable → keep.
        bool r = AutoConverter.ShouldConvertPure("hello", "אקkf", "en", "he",
            caps: false, dictAvailable: true, Dict(), None, None);
        Assert.False(r);
    }
}
