using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class ClipboardHistoryStoreTests
{
    [Fact]
    public void Keeps_order_and_unicode_without_writing_plaintext()
    {
        string folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        string path = Path.Combine(folder, "history.dat");
        var history = new ClipboardHistoryStore(path);
        string[] samples = ["fixture-sensitive-string", "привет", "hola\nEspaña", "hola\nEspaña", ""];
        try
        {
            history.Write(samples);
            Assert.DoesNotContain("fixture-sensitive-string", System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path)));
            Assert.Equal(samples[..3], new ClipboardHistoryStore(path).Read());
            history.Clear();
            history.Clear();
            Assert.False(File.Exists(path));
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }
}
