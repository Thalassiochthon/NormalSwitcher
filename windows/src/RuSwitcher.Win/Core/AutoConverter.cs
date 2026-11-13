using System.Linq;

namespace RuSwitcher.Win.Core;

/// <summary>
/// As-you-type auto conversion — the Windows counterpart of the macOS <c>LayoutDetector.decide</c>
/// + <c>AutoSwitch</c>. On a word boundary it looks at the just-typed word and, only when the
/// dictionary is confident it was typed in the wrong layout, flips it into the opposite layout and
/// switches the keyboard. Precision over recall: at any uncertainty it does nothing (the manual
/// trigger always works). Beta, default OFF.
/// </summary>
internal static class AutoConverter
{
    /// <summary>Try to auto-convert a completed word. Runs on the message loop (NOT inside the LL-hook
    /// callback) AFTER the real Space has already been delivered to the app — so it deletes the word
    /// PLUS that trailing space (<paramref name="keys"/>.Count + 1 backspaces) and re-types the
    /// converted word followed by a space. Deferring off the hook thread keeps the callback O(1) and
    /// avoids the LowLevelHooksTimeout / silent-unhook trap (COM + SendInput must not run in-callback).
    /// Returns true if it converted; on "keep" it does nothing (the word + space stay as typed).</summary>
    public static async Task<bool> TryConvertWordAsync(IReadOnlyList<TypedKey> keys, InputTarget input, Func<bool> stillCurrent, string suffix = " ", bool preserveLayout = false, Action<string>? diagnostic = null)
    {
        if (keys.Count is 0 or > 64 || !stillCurrent()) return false;
        var settings = Settings.Current;
        if ((settings.ExcludedApps.Count > 0 || settings.RemoteDesktopMode)
            && AppLayoutTracker.ProcessName(input.Foreground) is { } process
            && (settings.ExcludedApps.Contains(process, StringComparer.OrdinalIgnoreCase)
                || (settings.RemoteDesktopMode && process is "mstsc" or "msrdc")))
            return false;

        IntPtr sourceHkl = KeyMapper.TextLayout(keys, input.Layout);
        string typed = KeyMapper.ConvertWord(keys, sourceHkl);
        if (typed.Length != keys.Count) return false;
        string srcTag = SmartConvert.LangTag(sourceHkl);
        bool caps = keys.All(k => k.Caps);

        string lower = typed.ToLowerInvariant();
        if (settings.Abbreviations.TryGetValue(lower, out string? expansion) && !string.IsNullOrEmpty(expansion))
            return await Replace(expansion, input.Layout, learn: false);
        if (settings.NeverConvert.Contains(lower)) return false;

        var targets = LayoutSwitcher.ConversionTargets(sourceHkl).ToArray();
        if (settings.Abbreviations.Count > 0)
        {
            string[] expansions = targets.Select(layout => KeyMapper.ConvertWord(keys, sourceHkl, layout).ToLowerInvariant())
                .Where(settings.Abbreviations.ContainsKey).Select(key => settings.Abbreviations[key])
                .Where(value => !string.IsNullOrEmpty(value)).Distinct().Take(2).ToArray();
            if (expansions.Length == 1) return await Replace(expansions[0], input.Layout, learn: false);
            if (expansions.Length > 1) return false;
        }

        IntPtr targetHkl = IntPtr.Zero;
        string? converted = null;
        if (settings.AutoConvert)
        {
            foreach (var layout in targets)
            {
                string candidate = KeyMapper.ConvertWord(keys, sourceHkl, layout);
                if (candidate.Length != keys.Count || candidate == typed) continue;
                string targetTag = SmartConvert.LangTag(layout);
                string? plan = PreservePunctuation(typed, candidate,
                    (before, after) => ShouldConvertPure(before, after, srcTag, targetTag, caps, Dict.Available,
                        Dict.CheckWord, settings.NeverConvert, settings.AlwaysConvert, CheckTarget));
                if (plan == null) continue;
                if (converted != null) return false; // More than one plausible destination.
                targetHkl = layout;
                converted = settings.FixTwoCaps && !caps
                    ? TextFixes.TwoCaps(plan, word => CheckTarget(word, targetTag) == true) ?? plan
                    : plan;
            }
        }
        if (converted != null) return await Replace(converted, targetHkl, learn: true);

        if (keys.Any(key => key.Literal.HasValue)) return false;
        if (settings.FixTypos && targets.Length == 1 &&
            TextFixes.Number(keys, typed, key => KeyMapper.TranslateIn(key, targets[0])) is { } number)
            return await Replace(number, sourceHkl, learn: true);

        if (IsHebrew(srcTag)) return false;
        if (settings.FixTwoCaps && !caps &&
            TextFixes.TwoCaps(typed, word => Dict.CheckWord(word, srcTag) == true) is { } casing)
            return await Replace(casing, sourceHkl, learn: false);
        if (settings.FixTypos && TextFixes.Typo(keys, typed, key => KeyMapper.TranslateIn(key, sourceHkl),
                word => CheckTarget(word, srcTag), word => CheckTarget(word, srcTag) == true) is { } typo)
            return await Replace(typo, sourceHkl, learn: true);
        return false;

        bool? CheckTarget(string word, string tag) =>
            settings.ExtendedDictionary && FrequencyWords.Contains(word, tag) ? true : Dict.CheckWord(word, tag);

        async Task<bool> Replace(string replacement, IntPtr layout, bool learn)
        {
            if (replacement == typed || !stillCurrent()) return false;
            string expected = typed + suffix;
            bool matched = await input.MatchesTextAtCaretAsync(expected);
            // The receiving editor may still be processing the Space already passed by the hook.
            for (int attempt = 0; !matched && suffix.Length > 0 && input.IsWritableNativeEdit
                && attempt < 3 && stillCurrent(); attempt++)
            {
                await Task.Delay(12);
                matched = stillCurrent() && input.HasPlainTextAtCaret(expected);
            }
            string? failure = !stillCurrent() ? "focus-or-input-changed" : !matched ? "unverified-editor-text" : null;
            if (failure is null && !TextInjector.Replace(backspaces: keys.Count + suffix.Length, text: replacement + suffix))
                failure = "input-injection-failed";
            if (failure is not null)
            {
                diagnostic?.Invoke(failure);
                return false;
            }

            if (!preserveLayout)
            {
                if (layout != input.Layout) LayoutSwitcher.SwitchTo(layout);
                Converter.NoteAutoConversion(replacement + suffix, typed + suffix, layout, input.Layout, learn);
            }
            return true;
        }
    }

    internal static string? PreservePunctuation(string typed, string candidate, Func<string, string, bool> shouldConvert)
    {
        int end = typed.Length;
        while (end > 0 && ".,!?;:)".Contains(typed[end - 1])) end--;
        if (end == 0) return null;
        bool whole = shouldConvert(typed, candidate);
        if (end == typed.Length) return whole ? candidate : null;
        bool withPunctuation = shouldConvert(typed[..end], candidate[..end]);
        if (whole == withPunctuation) return null;
        return whole ? candidate : candidate[..end] + typed[end..];
    }

    private static bool IsHebrew(string tag) => tag == "he" || tag.StartsWith("he-", StringComparison.OrdinalIgnoreCase);

    /// <summary>The verdict logic, ported from the macOS <c>LayoutDetector.decide</c>. Pure: the
    /// dictionary and exception lists are passed in, so it is fully unit-testable. Returns true only
    /// when the word should be flipped to the opposite layout.</summary>
    internal static bool ShouldConvertPure(string typed, string converted, string srcTag, string tgtTag,
        bool caps, bool dictAvailable, Func<string, string, bool?> checkWord,
        ICollection<string> never, ICollection<string> always, Func<string, string, bool?>? checkTarget = null)
    {
        string typedLc = typed.ToLowerInvariant();
        string convertedLc = converted.ToLowerInvariant();

        // Explicit overrides (checked before the soft vetoes).
        if (never.Contains(typedLc) || never.Contains(convertedLc)) return false;
        if (always.Contains(convertedLc)) return true;

        // --- soft vetoes (cheap, before the dictionary) ---
        if (typed.Length < 2 || !converted.All(char.IsLetter)
            || !typed.All(ch => char.IsLetter(ch) || "`[];',.".Contains(ch)))
            return false;
        if (!caps)                                          // under Caps Lock these two aren't acronyms/camelCase
        {
            if (IsAllCaps(typed)) return false;             // acronyms
            if (LooksLikeCode(typed)) return false;         // camelCase / mixed scripts
        }

        if (typed.Length == 2)
            return ShortWords.Contains(convertedLc, tgtTag) && !ShortWords.Contains(typedLc, srcTag);

        // --- Hebrew cross-script pairs (positive signal only, from the non-Hebrew side) ---
        bool srcHe = IsHebrew(srcTag);
        bool tgtHe = IsHebrew(tgtTag);
        if (srcHe || tgtHe)
        {
            string sideTag = srcHe ? tgtTag : srcTag;
            if (sideTag == "he" || !dictAvailable) return false;
            if (srcHe)
            {
                // The EN image of correct Hebrew can be "word + punctuation" and falsely pass the
                // dictionary — only feed it an all-letter image.
                if (!converted.All(char.IsLetter)) return false;
                return checkWord(convertedLc, sideTag) == true;
            }
            // Typed on the non-Hebrew side: never auto-convert toward Hebrew (direction unresolvable
            // without a Hebrew dictionary — precision over recall). The manual trigger still works.
            return false;
        }

        // --- common same-alphabet-swap case ---
        if (!dictAvailable) return false;
        if ((checkTarget ?? checkWord)(convertedLc, tgtTag) != true) return false;
        return !typed.All(ch => char.IsLetter(ch) || ch == '\'') || checkWord(typedLc, srcTag) == false;
    }

    private static bool IsAllCaps(string s) =>
        s == s.ToUpperInvariant() && s != s.ToLowerInvariant();

    /// <summary>Looks like a code identifier: an internal capital (camelCase/PascalCase) or a mix of
    /// Latin and Cyrillic in one token — almost always code, not a word.</summary>
    private static bool LooksLikeCode(string s)
    {
        for (int i = 1; i < s.Length; i++)
            if (char.IsUpper(s[i])) return true;

        bool latin = false, cyr = false;
        foreach (char c in s)
        {
            if (c is >= 'a' and <= 'z' or >= 'A' and <= 'Z') latin = true;
            else if (c is >= 'Ѐ' and <= 'ӿ') cyr = true;
        }
        return latin && cyr;
    }
}
