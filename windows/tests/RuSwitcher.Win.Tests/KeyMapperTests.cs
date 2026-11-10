using System.Runtime.InteropServices;
using RuSwitcher.Win.Core;
using Xunit;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Tests;

public class KeyMapperTests
{
    [Fact]
    public void SamePhysicalKeysPreserveLatinAndCyrillicCharacters()
    {
        var installed = new IntPtr[GetKeyboardLayoutList(0, null)];
        GetKeyboardLayoutList(installed.Length, installed);
        IntPtr english = LoadKeyboardLayoutW("00000409", 0);
        IntPtr russian = LoadKeyboardLayoutW("00000419", 0);
        try
        {
            Assert.NotEqual(IntPtr.Zero, english);
            Assert.NotEqual(IntPtr.Zero, russian);
            var keys = "GHBDTN".Select(key =>
                new TypedKey(key, MapVirtualKeyExW(key, MAPVK_VK_TO_VSC, english), Shift: false, Caps: false))
                .ToArray();
            Assert.Equal("ghbdtn", KeyMapper.ConvertWord(keys, english));
            Assert.Equal("привет", KeyMapper.ConvertWord(keys, russian));
        }
        finally
        {
            if (russian != IntPtr.Zero && !installed.Contains(russian)) UnloadKeyboardLayout(russian);
            if (english != IntPtr.Zero && !installed.Contains(english)) UnloadKeyboardLayout(english);
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr LoadKeyboardLayoutW(string name, uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnloadKeyboardLayout(IntPtr layout);
}
