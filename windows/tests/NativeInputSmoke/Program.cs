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

                Clipboard.SetText("clipboard fixture");
                await Task.Delay(650);
                CheckRegistrationAndDispatch(1, 0x78); // Ctrl + Shift + F9.
                await Until(() => FindWindowW(null, "Clipboard history…") != IntPtr.Zero, "clipboard menu");
                await Task.Delay(100);
                Tap(0x0D);
                await Until(() => first.Text == "clipboard fixture", "history selection and paste");

                first.SelectionStart = first.TextLength;
                first.SelectionLength = 0;
                CheckRegistrationAndDispatch(24, 0x77); // ChangeCase (20 + 4), Ctrl + Shift + F8.
                await Until(() => first.Text == "CLIPBOARD FIXTURE", "configured change-case shortcut");

                Console.WriteLine("Clipboard history and configured shortcut passed.");
                first.Clear();
                TypeShortcutWord();
                await Until(() => first.Text == "zz", "ordinary keyboard input before Space");
                Tap(0x20);
                await Until(() => first.Text == "NormalSwitcher ", "Space expansion");

                string prefix = new string('x', 4500) + " ";
                first.Text = prefix;
                first.SelectionStart = prefix.Length;
                TypeShortcutWord();
                await Until(() => first.Text == prefix + "zz", "word beyond the native 4096-character boundary");
                Tap(0x20);
                Tap(0x41);
                await Until(() => first.Text == prefix + "NormalSwitcher a", "rapid input with verified trailing letter");

                first.Clear();
                // Clear() changes the fixture programmatically. Send a navigation key so the
                // app also starts with an empty typing buffer after the previous trailing 'a'.
                Tap(0x24);
                TypeShortcutWord();
                await Until(() => first.Text == "zz", "ordinary keyboard input before Enter");
                Tap(0x0D);
                await Until(() => first.Text == "NormalSwitcher\r\n", "Enter expansion");

                first.Clear();
                TypeShortcutWord();
                await Until(() => first.Text == "zz", "ordinary keyboard input before Tab");
                Tap(0x09);
                await Until(() => first.Text == "NormalSwitcher" && second.Focused, "Tab expansion and focus change");

                Console.WriteLine("Space, Enter and Tab passed.");
                first.Focus();
                first.Clear();
                await Until(() => first.Focused, "fixture focus after Tab");
                Unicode('z');
                Unicode('z');
                await Until(() => first.Text == "zz", "Unicode packet text before the boundary");
                Unicode(' ');
                await Until(() => first.Text == "NormalSwitcher ", $"Unicode packet expansion (received {first.Text.Length} characters initially)");
                Console.WriteLine("Unicode packet input passed.");
                first.Clear();
                Console.WriteLine("Space, Enter, Tab, clipboard history paste and custom shortcut passed.");
                Clipboard.SetText("Acceptance task\r\nMultiline text");
                string taskFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "NormalSwitcher", "tasks.dat");
                CheckRegistrationAndDispatch(27, 0x56, 7); // Save clipboard as task.
                await Until(() => File.Exists(taskFile), "encrypted task saved by shortcut");
                CheckRegistrationAndDispatch(26, 0x54); // Open tasks.
                await Until(() => FindWindowW(null, "Tasks") != IntPtr.Zero, "task window");
                var taskWindow = FindWindowW(null, "Tasks");
                PostMessageW(taskWindow, 0x0010, IntPtr.Zero, IntPtr.Zero); // WM_CLOSE.
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

    private static void TypeShortcutWord()
    {
        Tap(0x5A);
        Tap(0x5A);
    }

    private static void CheckRegistrationAndDispatch(int id, uint key, uint modifiers = 6)
    {
        // Synthetic modifier chords on hosted Windows are not equivalent to a physical global
        // shortcut. Verify Windows reserved the chord, then exercise the same WM_HOTKEY handler.
        if (RegisterHotKey(IntPtr.Zero, 900, modifiers, key))
        {
            UnregisterHotKey(IntPtr.Zero, 900);
            throw new InvalidOperationException("NormalSwitcher did not register the configured shortcut");
        }
        if (Marshal.GetLastWin32Error() != 1409)
            throw new InvalidOperationException("Could not verify the global shortcut registration");
        IntPtr tray = FindWindowW("NormalSwitcherTrayWindow", "NormalSwitcher");
        if (tray == IntPtr.Zero || !PostMessageW(tray, 0x0312, (IntPtr)id, (IntPtr)((key << 16) | modifiers)))
            throw new InvalidOperationException("Could not dispatch the registered shortcut");
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr window, int id);

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

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
    private static extern IntPtr FindWindowW(string? className, string? title);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
}
