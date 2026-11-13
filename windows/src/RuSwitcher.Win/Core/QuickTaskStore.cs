using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace RuSwitcher.Win.Core;

internal sealed record QuickTask(Guid Id, string Title, string Text, bool Completed)
{
    public static QuickTask FromText(string text)
    {
        string title = text.ReplaceLineEndings("\n").Split('\n')
            .Select(line => line.Trim()).FirstOrDefault(line => line.Length > 0) ?? "";
        var elements = new StringInfo(title);
        if (elements.LengthInTextElements > 120) title = elements.SubstringByTextElements(0, 120);
        return new(Guid.NewGuid(), title, text, false);
    }
}

internal sealed class QuickTaskStore(string path)
{
    private static readonly byte[] Entropy = "NormalSwitcher.Windows.Tasks.v1"u8.ToArray();
    private const int MaxBytes = 20 * 1024 * 1024;

    public QuickTask[] Read()
    {
        try
        {
            using var file = File.OpenRead(path);
            if (file.Length > MaxBytes) throw new InvalidDataException();
            byte[] cipher = new byte[(int)file.Length];
            file.ReadExactly(cipher);
            byte[] clear = ProtectedData.Unprotect(cipher, Entropy, DataProtectionScope.CurrentUser);
            try
            {
                var tasks = JsonSerializer.Deserialize<QuickTask[]>(clear) ?? throw new InvalidDataException();
                if (tasks.Any(task => task == null || !Valid(task)) ||
                    tasks.Select(task => task.Id).Distinct().Count() != tasks.Length)
                    throw new InvalidDataException();
                return tasks;
            }
            finally { CryptographicOperations.ZeroMemory(clear); }
        }
        catch (FileNotFoundException) { return []; }
        catch (DirectoryNotFoundException) { return []; }
    }

    internal static bool Valid(QuickTask task) => task.Id != Guid.Empty &&
        !string.IsNullOrWhiteSpace(task.Title) && new StringInfo(task.Title).LengthInTextElements <= 120 &&
        task.Text is { Length: <= ClipboardHistoryStore.MaxEntryLength };

    public QuickTask[] Change(Func<QuickTask[], QuickTask[]> change)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var gate = new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.Write, FileShare.None);
        var next = change(Read());
        if (next.Any(task => !Valid(task))) throw new InvalidDataException();
        byte[] clear = JsonSerializer.SerializeToUtf8Bytes(next);
        byte[] cipher;
        try { cipher = ProtectedData.Protect(clear, Entropy, DataProtectionScope.CurrentUser); }
        finally { CryptographicOperations.ZeroMemory(clear); }
        if (cipher.Length > MaxBytes) throw new InvalidDataException();
        string staged = path + ".tmp";
        try
        {
            using (var file = File.Create(staged))
            {
                file.Write(cipher);
                file.Flush(flushToDisk: true);
            }
            File.Move(staged, path, overwrite: true);
        }
        finally { File.Delete(staged); }
        return next;
    }
}
