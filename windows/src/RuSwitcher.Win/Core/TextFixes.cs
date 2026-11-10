namespace RuSwitcher.Win.Core;

/// <summary>Conservative text fixes shared by the automatic correction pipeline.</summary>
internal static class TextFixes
{
    // Physical ANSI scan codes, ordered by key position. The layout determines their characters.
    private static readonly uint[][] Rows =
    [
        [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B],
        [0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28],
        [0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35],
    ];

    internal static string? TwoCaps(string word, Func<string, bool> isWord)
    {
        if (word.Length < 3 || !char.IsUpper(word[0]) || !char.IsUpper(word[1])
            || !word.Skip(2).All(char.IsLower) || word[2..] == "s")
            return null;
        string fixedWord = word[..1] + word[1..].ToLowerInvariant();
        return isWord(fixedWord.ToLowerInvariant()) ? fixedWord : null;
    }

    internal static string? Number(IReadOnlyList<TypedKey> keys, string typed, Func<TypedKey, char?> otherChar)
    {
        if (typed.Length < 3 || !char.IsAsciiDigit(typed[0]) || !char.IsAsciiDigit(typed[^1])
            || keys.Any(key => key.Shift || key.Caps))
            return null;
        var output = typed.ToCharArray();
        bool changed = false;
        for (int i = 1; i < typed.Length - 1; i++)
        {
            if (char.IsAsciiDigit(typed[i])) continue;
            char? separator = otherChar(keys[i]);
            if (!char.IsAsciiDigit(typed[i - 1]) || !char.IsAsciiDigit(typed[i + 1])
                || !char.IsLetter(typed[i]) || separator is not ('.' or ','))
                return null;
            output[i] = separator.Value;
            changed = true;
        }
        return changed ? new string(output) : null;
    }

    internal static string? Typo(IReadOnlyList<TypedKey> keys, string typed,
        Func<TypedKey, char?> character, Func<string, bool?> checkTyped, Func<string, bool> isCandidate)
    {
        if (typed.Length is < 5 or > 24 || !typed.All(char.IsLetter) || typed.Skip(1).Any(char.IsUpper)
            || keys.Any(key => key.Caps) || checkTyped(typed.ToLowerInvariant()) != false)
            return null;

        string? found = null;
        var seen = new HashSet<string>();
        var word = typed.ToCharArray();
        for (int i = 0; i < keys.Count; i++)
        {
            foreach (uint scan in Neighbors(keys[i].ScanCode))
            {
                if (character(keys[i] with { ScanCode = scan }) is not { } replacement
                    || !char.IsLetter(replacement) || replacement == typed[i])
                    continue;
                word[i] = replacement;
                string candidate = new(word);
                string lower = candidate.ToLowerInvariant();
                if (!seen.Add(lower) || !isCandidate(lower)) continue;
                if (found != null) return null;
                found = candidate;
            }
            word[i] = typed[i];
        }
        return found;
    }

    private static IEnumerable<uint> Neighbors(uint scan)
    {
        for (int row = 0; row < Rows.Length; row++)
        {
            int col = Array.IndexOf(Rows[row], scan);
            if (col < 0) continue;
            (int Row, int Col)[] adjacent =
                [(row, col - 1), (row, col + 1), (row - 1, col), (row - 1, col + 1), (row + 1, col - 1), (row + 1, col)];
            foreach (var (r, c) in adjacent)
                if (r >= 0 && r < Rows.Length && c >= 0 && c < Rows[r].Length)
                    yield return Rows[r][c];
            yield break;
        }
    }
}
