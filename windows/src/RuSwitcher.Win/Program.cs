using RuSwitcher.Win.Core;
using RuSwitcher.Win.Native;
using RuSwitcher.Win.Tray;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win;

// NormalSwitcher for Windows — manual-trigger conversion, mirroring the macOS engine:
// LL hook → keystroke buffer → ToUnicodeEx map → SendInput retype → layout switch. Clipboard-free
// for typed words; a clipboard round-trip is used only for converting an existing selection.
// The trigger defaults to a double-tap of Ctrl (works on all keyboards incl. laptops, doesn't
// disturb typing — the Windows counterpart of the macOS Option double-tap), selectable in the tray.
internal static class Program
{
    [STAThread]  // required for WinForms clipboard / dialogs
    private static void Main()
    {
        using var instance = new Mutex(true, @"Local\NormalSwitcher.Windows", out bool firstInstance);
        if (!firstInstance) return;

        ApplicationConfiguration.Initialize();

        string logDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NormalSwitcher");
        Directory.CreateDirectory(logDir);
        string logPath = Path.Combine(logDir, "debug.log");
        void Log(string line) => File.AppendAllText(logPath, $"{DateTime.Now:HH:mm:ss.fff} {line}{Environment.NewLine}");

        // Capture crashes to the log instead of dying silently (a tester can then send debug.log).
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        { try { Log("FATAL: " + (e.ExceptionObject as Exception)?.ToString()); } catch { /* ignore */ } };
        System.Windows.Forms.Application.ThreadException += (_, e) =>
        { try { Log("THREAD-EX: " + e.Exception); } catch { /* ignore */ } };

        var settings = Settings.Current;
        var buffer = new KeystrokeBuffer();
        bool enabled = true;
        long inputGeneration = 0;
        InputTarget? wordTarget = null, undoTarget = null;
        (List<TypedKey> Keys, InputTarget Target, long Generation)? pendingAuto = null;
        (InputTarget Target, long Generation)? pendingTrigger = null;

        void ResetInput()
        {
            inputGeneration++;
            pendingAuto = null;
            pendingTrigger = null;
            buffer.Reset();
            wordTarget = null;
            Converter.ClearReconvert();
        }

        bool CanEdit(InputTarget target, long generation, bool checkLayout)
        {
            if (!enabled || generation != inputGeneration || ShortcutHeld()
                || InputTarget.Capture() is not { } current || current.IsPasswordEdit)
                return false;
            return checkLayout ? current == target : current.SameControl(target);
        }

        // Auto-conversion checks the dictionary on the message loop; warm the COM spell-checker for the
        // actually-installed layout languages now, so the first auto-convert of the session isn't slow.
        if (settings.AutoConvert && Dict.Available)
        {
            try
            {
                foreach (var hkl in LayoutSwitcher.Installed())
                    Dict.IsValidWord("test", SmartConvert.LangTag(hkl));
            }
            catch { /* ignore */ }
        }

        using var tray = new TrayIcon();
        var detector = new TriggerDetector(settings.Trigger);

        // Hook thread: only post a message — the real (possibly slow, clipboard-touching)
        // conversion runs on the message loop so the LL hook callback stays fast.
        detector.Triggered += () =>
        {
            if (enabled && InputTarget.Capture() is { } target)
            {
                pendingTrigger = (target, inputGeneration);
                tray.PostTrigger();
            }
        };

        // issue #14: a separate hotkey that only switches the layout (fast → safe in-callback).
        var switchDetector = new TriggerDetector(settings.SwitchTrigger);
        switchDetector.Triggered += () =>
        {
            if (enabled && settings.SwitchTriggerEnabled && LayoutSwitcher.Opposite() is { } opp)
                LayoutSwitcher.SwitchTo(opp);
        };

        tray.TriggerActivated += () =>
        {
            var request = pendingTrigger;
            pendingTrigger = null;
            if (request is not { } trigger || !CanEdit(trigger.Target, trigger.Generation, checkLayout: true))
                return;
            if (wordTarget != trigger.Target) buffer.Reset();
            if (undoTarget is not { } undo || !undo.SameControl(trigger.Target))
                Converter.ClearReconvert();
            // Trigger again with nothing typed since = reverse the last conversion (toggle);
            // else whole-line mode → convert the line; else convert the typed word; else the selection.
            bool acted;
            if (Converter.CanReconvert && buffer.IsEmpty) acted = Converter.Reconvert();
            else if (settings.ConvertWholeLine) { acted = Converter.ConvertLine(settings.SmartConversion); if (acted) buffer.Reset(); }
            else if (!buffer.IsEmpty) acted = Converter.ConvertLastWord(buffer);
            else acted = Converter.ConvertSelection(settings.SmartConversion);
            if (acted) undoTarget = trigger.Target;
            Log($"trigger: acted={acted}");
        };
        tray.AutoConvertActivated += () =>
        {
            // Deferred off the hook callback: the real Space has already landed, so TryConvertWord
            // deletes the word + that space and re-types the converted word + space (or keeps it).
            var request = pendingAuto;
            pendingAuto = null;
            if (request is not { } word) return;
            if (AutoConverter.TryConvertWord(word.Keys, word.Target,
                    () => settings.AutoConvert && CanEdit(word.Target, word.Generation, checkLayout: true)))
                undoTarget = word.Target;
        };
        tray.EnabledChanged += on => { enabled = on; ResetInput(); Log($"enabled = {on}"); };
        tray.SettingsRequested += () =>
        {
            using var form = new UI.SettingsForm();
            form.TriggerChanged += kind => detector.Kind = kind;
            form.SwitchChanged += () => switchDetector.Kind = settings.SwitchTrigger;
            form.ShowDialog();   // modal; the message loop keeps pumping the hook + tray
        };
        tray.QuitRequested += () => Log("quit requested");
        tray.Show("NormalSwitcher");

        // A hidden WinForms control forces a WindowsFormsSynchronizationContext onto this thread, so
        // the background update check can marshal its message box back here (dispatched by our loop).
        using var uiAnchor = new System.Windows.Forms.Control();
        _ = uiAnchor.Handle;   // force handle creation → installs the sync context
        var ui = SynchronizationContext.Current ?? new SynchronizationContext();
        tray.UpdateRequested += () => Updater.CheckNow(ui);

        using var hook = new KeyboardHook();
        hook.MousePressed += ResetInput;
        hook.KeyDown += (vk, sc) =>
        {
            if (!enabled) return;
            inputGeneration++;
            pendingAuto = null;

            detector.OnKeyDown(vk);
            switchDetector.OnKeyDown(vk);
            if (vk is VK_LCONTROL or VK_RCONTROL or VK_LSHIFT or VK_RSHIFT or VK_PAUSE)
                return;

            Converter.ClearReconvert();
            if (ShortcutHeld() || InputTarget.Capture() is not { } target || target.IsPasswordEdit)
            {
                ResetInput();
                return;
            }
            if (wordTarget != target)
            {
                buffer.Reset();
                wordTarget = target;
            }

            if (vk == KeystrokeBuffer.VK_SPACE && settings.AutoConvert && !buffer.IsEmpty)
            {
                pendingAuto = (new List<TypedKey>(buffer.CurrentWord), target, inputGeneration);
                tray.PostAutoConvert();
            }
            if (KeystrokeBuffer.IsTypingKey(vk))
            {
                bool shift = IsDown(VK_SHIFT);
                bool caps = (GetKeyState(VK_CAPITAL) & 0x0001) != 0;
                buffer.Append(new TypedKey(vk, sc, shift, caps));
            }
            else
            {
                buffer.Reset();
            }
        };
        hook.KeyUp += (vk, sc) =>
        {
            if (!enabled) return;
            detector.OnKeyUp(vk);
            switchDetector.OnKeyUp(vk);
        };
        hook.Install();

        // Per-app layout memory (issue): restores each app's last-used layout on focus. Off by default.
        using var appTracker = new AppLayoutTracker();
        appTracker.Install();

        Updater.CheckOnLaunch(ui);   // silent, throttled once-a-day, off the startup path

        Log($"NormalSwitcher started — hook + tray up, trigger={settings.Trigger}");

        // Message loop: required for both the LL hook callbacks and the tray window.
        while (GetMessageW(out MSG msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessageW(ref msg);
        }
    }

    private static bool IsDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    private static bool ShortcutHeld() =>
        IsDown(VK_CONTROL) || IsDown(0x12) || IsDown(0x5B) || IsDown(0x5C); // Alt and Win keys
}
