using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using RuSwitcher.Win.Core;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Tray;

internal static class LayoutIcon
{
    private static CultureInfo Culture(IntPtr layout) => CultureInfo.GetCultureInfo(SmartConvert.LangTag(layout));

    public static string Name(IntPtr layout)
    {
        var culture = Culture(layout);
        return culture.Name.Length == 0 ? "—" : culture.NativeName;
    }

    public static Icon Create(IntPtr layout, bool monochrome = false)
    {
        using var bitmap = new Bitmap(16, 16, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);
        var culture = Culture(layout);
        string code = culture.Name.Length == 0 ? "–" : culture.TwoLetterISOLanguageName;
        var red = Color.FromArgb(204, 32, 45);
        var blue = Color.FromArgb(35, 77, 164);
        var yellow = Color.FromArgb(255, 205, 42);

        switch (monochrome ? "" : code)
        {
            case "ru": Bands(Color.White, blue, red); break;
            case "uk": Fill(blue, 0, 3, 16, 5); Fill(yellow, 0, 8, 16, 5); break;
            case "de": Bands(Color.Black, red, yellow); break;
            case "fr": Columns(blue, Color.White, red); break;
            case "it": Columns(Color.SeaGreen, Color.White, red); break;
            case "es":
                Fill(red, 0, 3, 16, 10);
                Fill(yellow, 0, 5, 16, 6);
                Fill(red, 4, 7, 2, 3);
                break;
            case "pl": Fill(Color.White, 0, 3, 16, 5); Fill(red, 0, 8, 16, 5); break;
            case "ja":
                Fill(Color.White, 0, 3, 16, 10);
                using (var disc = new SolidBrush(red)) g.FillEllipse(disc, 5, 5, 6, 6);
                break;
            case "en" when culture.Name == "en-US":
                Fill(Color.White, 0, 3, 16, 10);
                for (int y = 3; y < 13; y += 2) Fill(red, 0, y, 16, 1);
                Fill(blue, 0, 3, 7, 5);
                Fill(Color.White, 1, 4, 1, 1);
                Fill(Color.White, 4, 6, 1, 1);
                break;
            case "en" when culture.Name == "en-GB":
                Fill(blue, 0, 3, 16, 10);
                using (var white = new Pen(Color.White, 2))
                {
                    g.DrawLine(white, 1, 4, 14, 11);
                    g.DrawLine(white, 1, 11, 14, 4);
                }
                Fill(Color.White, 0, 6, 16, 4);
                Fill(Color.White, 6, 3, 4, 10);
                Fill(red, 0, 7, 16, 2);
                Fill(red, 7, 3, 2, 10);
                break;
            default:
                Fill(monochrome ? Color.FromArgb(45, 45, 45) : Color.FromArgb(100, 48, 154), 0, 2, 16, 12);
                using (var font = new Font("Segoe UI", 8, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var centered = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString(code.ToUpperInvariant(), font, Brushes.White, new RectangleF(0, 2, 16, 12), centered);
                break;
        }

        IntPtr handle = bitmap.GetHicon();
        try
        {
            using var borrowed = Icon.FromHandle(handle);
            return (Icon)borrowed.Clone();
        }
        finally { DestroyIcon(handle); }

        void Fill(Color color, int x, int y, int width, int height)
        {
            using var brush = new SolidBrush(color);
            g.FillRectangle(brush, x, y, width, height);
        }

        void Bands(Color top, Color middle, Color bottom)
        {
            Fill(top, 0, 3, 16, 3);
            Fill(middle, 0, 6, 16, 4);
            Fill(bottom, 0, 10, 16, 3);
        }

        void Columns(Color left, Color center, Color right)
        {
            Fill(left, 0, 3, 5, 10);
            Fill(center, 5, 3, 6, 10);
            Fill(right, 11, 3, 5, 10);
        }
    }
}
