using System.Drawing;
using System.Drawing.Imaging;
using System.Security.Cryptography;
using System.Text.Json.Serialization;

namespace RuSwitcher.Win.Core;

internal sealed record ClipboardEntry(string? Text, byte[]? Png = null, int Width = 0, int Height = 0)
{
    public const int MaxImageBytes = 16 * 1024 * 1024;
    public const int TotalImageBytes = 64 * 1024 * 1024;
    private const long MaxPixels = 24_000_000;
    private string? _key;

    [JsonIgnore]
    public string Key => _key ??= Png is { } data
        ? "png:" + Convert.ToHexString(SHA256.HashData(data)) : "text:" + Text;

    internal bool Valid => Png is { } data
        ? Text is null && data.Length is > 0 and <= MaxImageBytes && Fits(Width, Height)
        : ClipboardHistoryStore.IsValid(Text);

    internal static ClipboardEntry? FromImage(Image image)
    {
        if (!Fits(image.Width, image.Height)) return null;
        using var png = new MemoryStream();
        image.Save(png, ImageFormat.Png);
        return png.Length <= MaxImageBytes ? new(null, png.ToArray(), image.Width, image.Height) : null;
    }

    internal Bitmap? OpenImage()
    {
        if (Png is null || !Valid) return null;
        try
        {
            using var input = new MemoryStream(Png);
            using var image = Image.FromStream(input);
            return image.Width == Width && image.Height == Height ? new Bitmap(image) : null;
        }
        catch (Exception e) when (e is ArgumentException or OutOfMemoryException or System.Runtime.InteropServices.ExternalException)
        {
            return null;
        }
    }

    internal static ClipboardEntry[] Trim(IEnumerable<ClipboardEntry> entries, int imageLimit)
    {
        var result = new List<ClipboardEntry>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        int textCount = 0, images = 0, bytes = 0;
        foreach (var entry in entries)
        {
            if (entry is null || !entry.Valid || !seen.Add(entry.Key)) continue;
            if (entry.Png is { } png)
            {
                if (images >= Math.Clamp(imageLimit, 0, 50) || bytes + png.Length > TotalImageBytes) continue;
                images++;
                bytes += png.Length;
            }
            else if (textCount++ >= ClipboardHistoryStore.Limit) continue;
            result.Add(entry);
        }
        return result.ToArray();
    }

    private static bool Fits(int width, int height) =>
        width > 0 && height > 0 && (long)width * height <= MaxPixels;
}
