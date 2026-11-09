using System.Text;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Smart per-word conversion of a selection — the Windows counterpart of the macOS
/// <c>SmartConvert.selection</c>. A word is flipped to the opposite layout only if it is NOT a
/// real word as typed AND becomes a real word once flipped (so correct text and intentional
/// foreign words are kept). If the spell-check dictionary is unavailable, falls back to a plain
/// one-way flip. Direction: source (current) layout → target (opposite), the common mis-typed case.
/// </summary>
internal static class SmartConvert
{
    public static string Selection(string text, IntPtr sourceHkl, IntPtr targetHkl)
    {
        if (!Dict.Available) return KeyMapper.ConvertText(text, sourceHkl, targetHkl);

        string srcTag = LangTag(sourceHkl);
        string tgtTag = LangTag(targetHkl);
        var fwd = KeyMapper.BuildPairMap(sourceHkl, targetHkl);

        var sb = new StringBuilder(text.Length);
        int i = 0;
        while (i < text.Length)
        {
            if (char.IsWhiteSpace(text[i]))
            {
                sb.Append(text[i++]);
                continue;
            }
            int start = i;
            while (i < text.Length && !char.IsWhiteSpace(text[i])) i++;
            string word = text.Substring(start, i - start);
            sb.Append(ConvertWord(word, fwd, srcTag, tgtTag));
        }
        return sb.ToString();
    }

    private static string ConvertWord(string word, Dictionary<char, char> fwd, string srcTag, string tgtTag)
    {
        string core = LetterCore(word);
        if (core.Length == 0) return word;

        // Honor the user's exception lists, same precedence/keys as AutoConverter (learn-from-undo).
        string flipped = Flip(word, fwd);
        string flippedCore = LetterCore(flipped);
        if (Settings.Current.AlwaysConvert.Contains(flippedCore.ToLowerInvariant())) return flipped;
        if (Settings.Current.NeverConvert.Contains(core.ToLowerInvariant())) return word;

        if (core.Length < 2) return word;                       // too short to judge — keep
        if (Dict.IsValidWord(core, srcTag)) return word;        // already a real word — keep (iPhone, стоит)

        if (flippedCore.Length >= 2 && Dict.IsValidWord(flippedCore, tgtTag))
            return flipped;                                     // gibberish that becomes a real word — flip

        return word;                                            // unresolved (name/brand/unknown) — keep
    }

    private static string Flip(string s, Dictionary<char, char> map)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char c in s) sb.Append(map.TryGetValue(c, out char m) ? m : c);
        return sb.ToString();
    }

    private static string LetterCore(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && !char.IsLetter(s[a])) a++;
        while (b > a && !char.IsLetter(s[b - 1])) b--;
        return s.Substring(a, b - a);
    }

    /// <summary>BCP-47-ish language tag from a keyboard layout handle (low word = LANGID).</summary>
    public static string LangTag(IntPtr hkl)
    {
        int primary = (int)((long)hkl & 0x3FF);
        return primary switch
        {
            0x19 => "ru",
            0x09 => "en",
            0x22 => "uk",
            0x23 => "be",
            0x02 => "bg",
            0x0D => "he",
            0x08 => "el",
            0x2B => "hy",
            0x37 => "ka",
            _ => "en",
        };
    }
}
