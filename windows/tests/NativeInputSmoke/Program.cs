using System.Runtime.InteropServices;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        ApplicationConfiguration.Initialize();
        using var form = new Form { Text = "NormalSwitcher input test", TopMost = true };
        using var first = new TextBox { Multiline = true, AcceptsReturn = true, Dock = DockStyle.Fill, TabIndex = 0 };
        using var second = new TextBox { Dock = DockStyle.Bottom, TabIndex = 1 };
        form.Controls.Add(first);
        form.Controls.Add(second);
        int result = 1;
        form.Shown += async (_, _) =>
        {
            try
            {
                form.Activate();
                first.Focus();
                await Until(() => GetForegroundWindow() == form.Handle && first.Focused, "fixture focus");

                TypeShortcutWord();
                await Task.Delay(50);
                Tap(0x20);
                await Until(() => first.Text == "NormalSwitcher ", "Space expansion");

                first.Clear();
                TypeShortcutWord();
                await Task.Delay(50);
                Tap(0x0D);
                await Until(() => first.Text == "NormalSwitcher\r\n", "Enter expansion");

                first.Clear();
                TypeShortcutWord();
                await Task.Delay(50);
                Tap(0x09);
                await Until(() => first.Text == "NormalSwitcher" && second.Focused, "Tab expansion and focus change");

                Console.WriteLine("Space, Enter and Tab passed.");
                first.Focus();
                first.Clear();
                Unicode('z');
                Unicode('z');
                await Task.Delay(50);
                Unicode(' ');
                await Until(() => first.Text == "NormalSwitcher ", "Unicode packet expansion");
                Console.WriteLine("Unicode packet input passed.");
                first.Clear();
                Clipboard.SetText("clipboard fixture");
                await Task.Delay(650);
                Chord(0x78); // Ctrl + Shift + F9, reserved for this fixture.
                await Until(IsClipboardMenuOpen, "clipboard menu");
                Tap(0x28);
                Tap(0x0D);
                await Until(() => first.Text == "clipboard fixture", "history selection and paste");

                first.SelectAll();
                Chord(0x77);
                await Until(() => first.Text == "CLIPBOARD FIXTURE", "configured change-case shortcut");

                Console.WriteLine("Space, Enter, Tab, clipboard history paste and custom shortcut passed.");
                result = 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
            }
            finally { form.Close(); }
        };
        Application.Run(form);
        return result == 0 ? CheckAccessibleEditor() : result;
    }

    private static int CheckAccessibleEditor()
    {
        var text = new System.Windows.Controls.TextBox();
        var window = new System.Windows.Window { Title = "NormalSwitcher UI Automation test", Topmost = true, Content = text };
        int result = 1;
        window.ContentRendered += async (_, _) =>
        {
            try
            {
                window.Activate();
                text.Focus();
                await Until(() => text.IsKeyboardFocused, "UI Automation fixture focus");
                TypeShortcutWord();
                await Task.Delay(50);
                Tap(0x20);
                await Until(() => text.Text == "NormalSwitcher ", "Space expansion through UI Automation");
                Console.WriteLine("UI Automation verified the text in a WPF editor.");
                result = 0;
            }
            catch (Exception error) { Console.Error.WriteLine(error); }
            finally { window.Close(); }
        };
        var app = new System.Windows.Application();
        app.Run(window);
        return result;
    }

    private static async Task Until(Func<bool> check, string scenario)
    {
        for (int i = 0; i < 40; i++)
        {
            if (check()) return;
            await Task.Delay(100);
        }
        throw new InvalidOperationException($"Timed out: {scenario}");
    }

    private static bool IsClipboardMenuOpen()
    {
        IntPtr tray = FindWindowW("NormalSwitcherTrayWindow", "NormalSwitcher");
        uint thread = GetWindowThreadProcessId(tray, out _);
        var info = new ThreadInfo { Size = (uint)Marshal.SizeOf<ThreadInfo>() };
        return thread != 0 && GetGUIThreadInfo(thread, ref info) && (info.Flags & 0x1C) != 0;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ThreadInfo
    {
        public uint Size, Flags;
        public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetGUIThreadInfo(uint thread, ref ThreadInfo info);

    private static void TypeShortcutWord()
    {
        Tap(0x5A);
        Tap(0x5A);
    }

    private static void Chord(byte key)
    {
        Send(0xA2, false);
        Send(0xA0, false);
        Tap(key);
        Send(0xA0, true);
        Send(0xA2, true);
    }

    private static void Tap(byte key)
    {
        Send(key, false);
        Send(key, true);
    }

    private static void Send(byte key, bool up) =>
        keybd_event(key, (byte)MapVirtualKeyW(key, 0), up ? 2u : 0u, IntPtr.Zero);

    private static void Unicode(char character)
    {
        NativeInput[] keys =
        [
            new() { Type = 1, Scan = character, Flags = 4 },
            new() { Type = 1, Scan = character, Flags = 6 },
        ];
        if (SendInput(2, keys, Marshal.SizeOf<NativeInput>()) != 2)
            throw new InvalidOperationException("Could not send Unicode input");
    }

    // The smoke executable is x64. KEYBDINPUT begins at offset 8 in the 40-byte INPUT union.
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct NativeInput
    {
        [FieldOffset(0)] public uint Type;
        [FieldOffset(10)] public ushort Scan;
        [FieldOffset(12)] public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern uint SendInput(uint count, NativeInput[] inputs, int size);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, IntPtr extra);

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKeyW(uint key, uint mapType);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr FindWindowW(string className, string? title);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
}
