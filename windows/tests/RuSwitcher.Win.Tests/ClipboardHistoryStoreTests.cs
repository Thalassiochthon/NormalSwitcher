using System.Drawing;
using System.Security.Cryptography;
using System.Text.Json;
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
            history.Write(samples.Select(text => new ClipboardEntry(text)));
            Assert.DoesNotContain("fixture-sensitive-string", System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path)));
            Assert.Equal(samples[..3], new ClipboardHistoryStore(path).Read(10).Select(entry => entry.Text));
            history.Clear();
            history.Clear();
            Assert.False(File.Exists(path));
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }

    [Fact]
    public void ReadsPreviousTextOnlyHistoryAndKeepsImagesAtOriginalSize()
    {
        string folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        string path = Path.Combine(folder, "history.dat");
        try
        {
            Directory.CreateDirectory(folder);
            File.WriteAllBytes(path, ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(new[] { "old text" }),
                "NormalSwitcher.Windows.ClipboardHistory.v1"u8.ToArray(), DataProtectionScope.CurrentUser));
            var store = new ClipboardHistoryStore(path);
            var old = Assert.Single(store.Read(10));
            Assert.Equal("old text", old.Text);

            using var bitmap = new Bitmap(320, 160);
            bitmap.SetPixel(15, 20, Color.Blue);
            var image = Assert.IsType<ClipboardEntry>(ClipboardEntry.FromImage(bitmap));
            store.Write([image, old, image]);
            var restored = new ClipboardHistoryStore(path).Read(10);
            Assert.Equal(2, restored.Length);
            using var decoded = restored[0].OpenImage();
            Assert.NotNull(decoded);
            Assert.Equal(new Size(320, 160), decoded.Size);
            Assert.Equal(Color.Blue.ToArgb(), decoded.GetPixel(15, 20).ToArgb());
            Assert.Equal("old text", Assert.Single(store.Read(0)).Text);
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }
}
