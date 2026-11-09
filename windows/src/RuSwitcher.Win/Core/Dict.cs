using System.Runtime.InteropServices;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Spell-check via the Windows Spell Checking API (ISpellChecker, Windows 8+) — the counterpart
/// of the macOS NSSpellChecker. Used to decide, for smart conversion, whether a word is a real
/// word in a given language. Fully defensive: any COM failure ⇒ <see cref="Available"/> is false
/// and callers fall back to the plain one-way conversion (never throws, never blocks a convert).
/// NOTE: COM vtables are written blind (assistant is on macOS) — verify behaviour on Windows.
/// </summary>
internal static class Dict
{
    private static readonly ISpellCheckerFactory? Factory;
    private static readonly Dictionary<string, ISpellChecker?> Checkers = new(StringComparer.OrdinalIgnoreCase);

    public static bool Available => Factory != null;

    static Dict()
    {
        try { Factory = (ISpellCheckerFactory)new SpellCheckerFactory(); }
        catch { Factory = null; }
    }

    private static ISpellChecker? CheckerFor(string languageTag)
    {
        if (Factory == null) return null;
        if (Checkers.TryGetValue(languageTag, out var c)) return c;
        ISpellChecker? checker = null;
        try
        {
            if (Factory.IsSupported(languageTag) != 0)
                checker = Factory.CreateSpellChecker(languageTag);
        }
        catch { checker = null; }
        Checkers[languageTag] = checker;
        return checker;
    }

    /// <summary>True if <paramref name="word"/> is spelled correctly in <paramref name="languageTag"/>
    /// (e.g. "ru", "en"). If the language/API is unavailable, returns false (unknown).</summary>
    public static bool IsValidWord(string word, string languageTag)
    {
        if (string.IsNullOrWhiteSpace(word)) return false;
        var checker = CheckerFor(languageTag);
        if (checker == null) return false;
        try
        {
            IEnumSpellingError errors = checker.Check(word);
            // Next() returns S_OK (0) with an error, or S_FALSE (1) with null when there are none.
            int hr = errors.Next(out ISpellingError? err);
            bool hasError = hr == 0 && err != null;
            if (err != null) Marshal.ReleaseComObject(err);
            Marshal.ReleaseComObject(errors);
            return !hasError;
        }
        catch { return false; }
    }
}

// --- Minimal COM interop for the Spell Checking API (spellcheck.h) ---

[ComImport, Guid("7AB36653-1796-484B-BDFA-E74F1DB7C1DC")]
internal class SpellCheckerFactory { }

[ComImport, Guid("8E018A9D-2415-4677-BF08-794EA61F94BB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ISpellCheckerFactory
{
    // Vtable order from ISpellCheckerFactory. get_SupportedLanguages is first; declared as a
    // placeholder so the later slots line up.
    [return: MarshalAs(UnmanagedType.Interface)] object get_SupportedLanguages();
    int IsSupported([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
    [return: MarshalAs(UnmanagedType.Interface)] ISpellChecker CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
}

[ComImport, Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ISpellChecker
{
    [return: MarshalAs(UnmanagedType.LPWStr)] string get_LanguageTag();   // slot 0
    [return: MarshalAs(UnmanagedType.Interface)] IEnumSpellingError Check([MarshalAs(UnmanagedType.LPWStr)] string text);  // slot 1
    // remaining methods (Suggest, Add, …) not declared — not needed.
}

[ComImport, Guid("803E3BD4-2828-4410-8290-418D1D73C762"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IEnumSpellingError
{
    [PreserveSig] int Next([MarshalAs(UnmanagedType.Interface)] out ISpellingError? value);
}

[ComImport, Guid("B7C82D61-FBE8-4B47-9B27-6C0D2E0DE0A3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ISpellingError
{
    uint get_StartIndex();
    uint get_Length();
    uint get_CorrectiveAction();
    [return: MarshalAs(UnmanagedType.LPWStr)] string get_Replacement();
}
