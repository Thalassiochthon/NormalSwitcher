using System.Security.Cryptography;
using System.Text.Json;

namespace RuSwitcher.Win.Core;

internal sealed class ClipboardHistoryStore(string path)
{
    public const int Limit = 30;
    public const int MaxEntryLength = 100_000;
    private const int MaxFileBytes = 20 * 1024 * 1024;
    private static readonly byte[] Entropy = "NormalSwitcher.Windows.ClipboardHistory.v1"u8.ToArray();

    public string[] Read()
    {
        using var file = File.OpenRead(path);
        if (file.Length > MaxFileBytes) throw new InvalidDataException("Clipboard history is too large");
        byte[] encrypted = new byte[(int)file.Length];
        file.ReadExactly(encrypted);
        byte[] clear = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
        try
        {
            return (JsonSerializer.Deserialize<string[]>(clear) ?? [])
                .Where(IsValid).Distinct().Take(Limit).ToArray();
        }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    public void Write(IEnumerable<string> entries)
    {
        byte[] clear = JsonSerializer.SerializeToUtf8Bytes(entries);
        byte[] encrypted;
        try { encrypted = ProtectedData.Protect(clear, Entropy, DataProtectionScope.CurrentUser); }
        finally { CryptographicOperations.ZeroMemory(clear); }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string staged = path + ".tmp";
        try
        {
            File.WriteAllBytes(staged, encrypted);
            File.Move(staged, path, overwrite: true);
        }
        finally { File.Delete(staged); }
    }

    public void Clear()
    {
        if (Directory.Exists(Path.GetDirectoryName(path)))
            File.Delete(path);
    }

    public static bool IsValid(string? text) => text is { Length: > 0 and <= MaxEntryLength };
}
