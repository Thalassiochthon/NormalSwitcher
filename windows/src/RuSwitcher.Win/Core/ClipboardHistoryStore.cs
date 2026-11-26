using System.Security.Cryptography;
using System.Text.Json;

namespace RuSwitcher.Win.Core;

internal sealed class ClipboardHistoryStore(string path)
{
    public const int Limit = 30;
    public const int MaxEntryLength = 100_000;
    private const int MaxFileBytes = 96 * 1024 * 1024;
    private static readonly byte[] Entropy = "NormalSwitcher.Windows.ClipboardHistory.v1"u8.ToArray();

    public ClipboardEntry[] Read(int imageLimit)
    {
        using var file = File.OpenRead(path);
        if (file.Length > MaxFileBytes) throw new InvalidDataException("Clipboard history is too large");
        byte[] encrypted = new byte[(int)file.Length];
        file.ReadExactly(encrypted);
        byte[] clear = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
        try
        {
            using var document = JsonDocument.Parse(clear);
            if (document.RootElement.ValueKind != JsonValueKind.Array) throw new InvalidDataException();
            var root = document.RootElement;
            return ClipboardEntry.Trim(root.GetArrayLength() > 0 && root[0].ValueKind == JsonValueKind.String
                ? (root.Deserialize<string[]>() ?? []).Select(text => new ClipboardEntry(text))
                : root.Deserialize<ClipboardEntry[]>() ?? [], imageLimit);
        }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    public void Write(IEnumerable<ClipboardEntry> entries)
    {
        byte[] clear = JsonSerializer.SerializeToUtf8Bytes(entries);
        byte[] encrypted;
        try { encrypted = ProtectedData.Protect(clear, Entropy, DataProtectionScope.CurrentUser); }
        finally { CryptographicOperations.ZeroMemory(clear); }
        if (encrypted.Length > MaxFileBytes) throw new InvalidDataException("Clipboard history is too large");
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
