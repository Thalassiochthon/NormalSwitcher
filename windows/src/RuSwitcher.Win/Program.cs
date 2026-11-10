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
    private static void Main(string[] args)
    {
        if (Updater.RunHelper(args)) return;
        using var instance = new Mutex(true, @"Local\NormalSwitcher.Windows", out bool firstInstance);
        if (!firstInstance)
        {
            IntPtr window = FindWindowW(TrayIcon.WindowClass, "NormalSwitcher");
            if (window != IntPtr.Zero) PostMessageW(window, WM_SETTINGS, IntPtr.Zero, IntPtr.Zero);
            return;
        }

        ApplicationConfiguration.Initialize();

        string logDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NormalSwitcher");
        Directory.CreateDirectory(logDir);
        string logPath = Path.Combine(logDir, "debug.log");
        void Log(string line)
        {
            if (!Settings.Current.DebugLogging) return;
            try { File.AppendAllText(logPath, $"{DateTime.Now:HH:mm:ss.fff} {line}{Environment.NewLine}"); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        // Capture crashes to the log instead of dying silently (a tester can then send debug.log).
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        { try { Log("FATAL: " + (e.ExceptionObject as Exception)?.ToString()); } catch { /* ignore */ } };
        System.Windows.Forms.Application.ThreadException += (_, e) =>
        { try { Log("THREAD-EX: " + e.Exception); } catch { /* ignore */ } };

        var settings = Settings.Current;
        var buffer = new KeystrokeBuffer();
        bool enabled = settings.KeyboardEnabled;
        long inputGeneration = 0;
        InputTarget? wordTarget = null, undoTarget = null;
        (InputTarget Target, string Text, int NextVariant)? caseCycle = null;
        (List<TypedKey> Keys, InputTarget Target, long Generation, uint DeferredKey, List<TypedKey> Tail)? pendingAuto = null;
        (InputTarget Target, long Generation)? pendingTrigger = null;

        void ResetInput()
        {
            inputGeneration++;
            ReplayBoundary();
            pendingAuto = null;
            pendingTrigger = null;
            buffer.Reset();
            wordTarget = null;
            caseCycle = null;
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
        tray.Diagnostic += Log;
        var detector = new TriggerDetector(settings.Trigger);

        // Hook thread: only post a message — the real (possibly slow, clipboard-touching)
        // conversion runs on the message loop so the LL hook callback stays fast.
        detector.Triggered += QueueManualCorrection;
        void QueueManualCorrection()
        {
            if (enabled && InputTarget.Capture() is { } target)
            {
                pendingTrigger = (target, inputGeneration);
                tray.PostTrigger();
            }
        }

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
            else if (settings.ConvertWholeLine || buffer.IsEmpty)
            {
                tray.ClipboardHistory.Poll();
                acted = settings.ConvertWholeLine ? Converter.ConvertLine(settings.SmartConversion)
                    : Converter.ConvertSelection(settings.SmartConversion);
                tray.ClipboardHistory.SkipCurrent();
                if (acted) buffer.Reset();
            }
            else acted = Converter.ConvertLastWord(buffer);
            if (acted) undoTarget = trigger.Target;
            Log($"trigger: acted={acted}");
        };
        void ReplayBoundary()
        {
            if (pendingAuto is not { DeferredKey: not 0 } pending) return;
            pendingAuto = null;
            Replay(pending.DeferredKey, pending.Target);
        }

        static void Replay(uint key, InputTarget target)
        {
            if (InputTarget.Capture() is { } current && target.SameControl(current))
                TextInjector.SendKey((ushort)key);
        }

        tray.AutoConvertActivated += async () =>
        {
            if (pendingAuto is { DeferredKey: 0 }) await Task.Delay(12);
            var request = pendingAuto;
            pendingAuto = null;
            if (request is not { } word) return;
            bool deferred = word.DeferredKey != 0;
            string tail = KeyMapper.ConvertWord(word.Tail, word.Target.Layout);
            try
            {
                if (tail.Length != word.Tail.Count) return;
                if (await AutoConverter.TryConvertWordAsync(word.Keys, word.Target,
                        () => settings.HasAutomaticEdits && CanEdit(word.Target, word.Generation, checkLayout: true),
                        deferred ? "" : " " + tail, preserveLayout: tail.Length > 0))
                    undoTarget = word.Target;
            }
            finally
            {
                if (deferred)
                {
                    Converter.ClearReconvert();
                    Replay(word.DeferredKey, word.Target);
                }
            }
        };
        tray.EnabledChanged += on => { enabled = on; ResetInput(); Log($"enabled = {on}"); };
        bool keyboardHookReady = false;
        tray.AutoStatus = () => L10n.T(
            !enabled || !settings.HasAutomaticEdits ? "auto.status.off" :
            !keyboardHookReady ? "auto.status.hook" :
            !settings.WordEndOnSpace && !settings.WordEndOnEnter && !settings.WordEndOnTab ? "auto.status.boundary" :
            settings.AutoConvert && !Dict.Available ? "auto.status.dictionary" :
            "auto.status.ready");
        using var tasks = new UI.QuickTasksWindow();
        void OpenTasks()
        {
            if (!tray.ClipboardHistory.IsOpen && Form.ActiveForm?.Modal != true) tasks.Open();
        }
        void AddTask(string? text)
        {
            if (tasks.AddText(text)) tasks.Notify(L10n.T("tasks.added"));
            else tasks.Notify(L10n.T("tasks.captureFailed"));
        }
        tray.TasksRequested += OpenTasks;
        UI.SettingsForm? currentSettings = null;
        tray.SettingsRequested += () =>
        {
            if (currentSettings != null) { currentSettings.Activate(); return; }
            bool openTasksAfterSettings = false;
            using var form = new UI.SettingsForm(tray.ClipboardHistory, tray.Shortcuts, logPath, keyboardHookReady,
                () => openTasksAfterSettings = true);
            currentSettings = form;
            form.AppearanceChanged += tray.RefreshAppearance;
            form.KeyboardEnabledChanged += tray.SetEnabled;
            form.TriggerChanged += kind => detector.Kind = kind;
            form.SwitchChanged += () => switchDetector.Kind = settings.SwitchTrigger;
            try { form.ShowDialog(); } // modal; the message loop keeps pumping the hook + tray
            finally { currentSettings = null; }
            if (openTasksAfterSettings) OpenTasks();
        };
        tray.QuitRequested += () => Log("quit requested");
        tray.Show("NormalSwitcher");
        tray.ClipboardHistory.Pasted += ResetInput;
        tray.ClipboardHistory.TaskRequested = AddTask;
        tray.Shortcuts.Activated += async action =>
        {
            Log($"shortcut action={action}");
            if (action == ShortcutAction.OpenTasks) { OpenTasks(); return; }
            if (action == ShortcutAction.CaptureTask)
            {
                try { AddTask(ClipboardHistory.ReadAllowedText()); }
                catch (System.Runtime.InteropServices.ExternalException) { AddTask(null); }
                return;
            }
            if (!enabled || InputTarget.Capture() is not { IsPasswordEdit: false } target) return;
            switch (action)
            {
                case ShortcutAction.Correct:
                    QueueManualCorrection();
                    break;
                case ShortcutAction.Switch:
                    if (LayoutSwitcher.Opposite() is { } opposite) LayoutSwitcher.SwitchTo(opposite);
                    ResetInput();
                    break;
                case ShortcutAction.FirstLayout:
                case ShortcutAction.SecondLayout:
                    IntPtr layout = LayoutSwitcher.Preferred(action == ShortcutAction.FirstLayout);
                    if (layout != IntPtr.Zero) LayoutSwitcher.SwitchTo(layout);
                    ResetInput();
                    break;
                case ShortcutAction.ChangeCase:
                    if (!settings.ConvertWholeLine && wordTarget == target && !buffer.IsEmpty)
                    {
                        var cycle = caseCycle;
                        int variant = cycle?.NextVariant ?? 0;
                        string currentWord = cycle?.Text ?? KeyMapper.ConvertWord(buffer.CurrentWord, target.Layout);
                        long generation = inputGeneration;
                        if (currentWord.Length > 0 && await target.MatchesTextAtCaretAsync(currentWord)
                            && CanEdit(target, generation, checkLayout: true))
                        {
                            string next = Converter.CaseVariant(currentWord, variant);
                            if (next == currentWord)
                            {
                                variant = (variant + 1) % 3;
                                next = Converter.CaseVariant(currentWord, variant);
                            }
                            if (next != currentWord && TextInjector.Replace(currentWord.Length, next))
                            {
                                Converter.ClearReconvert();
                                caseCycle = (target, next, (variant + 1) % 3);
                            }
                        }
                        break;
                    }
                    tray.ClipboardHistory.Poll();
                    Converter.ChangeSelectionCase(settings.ConvertWholeLine);
                    tray.ClipboardHistory.SkipCurrent();
                    ResetInput();
                    break;
                case ShortcutAction.AddException:
                    if (wordTarget == target && !buffer.IsEmpty)
                        AddException(KeyMapper.ConvertWord(buffer.CurrentWord, target.Layout).ToLowerInvariant());
                    else
                    {
                        tray.ClipboardHistory.Poll();
                        Converter.WithSelectedWord(AddException);
                        tray.ClipboardHistory.SkipCurrent();
                    }
                    break;
            }
        };

        void AddException(string word)
        {
            if (word.Length <= 1 || settings.NeverConvert.Contains(word)) return;
            settings.NeverConvert.Add(word);
            settings.Save();
        }

        // A hidden WinForms control forces a WindowsFormsSynchronizationContext onto this thread, so
        // the background update check can marshal its message box back here (dispatched by our loop).
        using var uiAnchor = new System.Windows.Forms.Control();
        _ = uiAnchor.Handle;   // force handle creation → installs the sync context
        var ui = SynchronizationContext.Current ?? new SynchronizationContext();
        tray.UpdateRequested += () => Updater.CheckNow(ui);

        using var hook = new KeyboardHook();
        hook.MousePressed += () => { tray.Shortcuts.CancelPending(); ResetInput(); };
        hook.KeyDown = (vk, sc) =>
        {
            if (!enabled) return false;
            ReplayBoundary();
            inputGeneration++;
            var previousWord = pendingAuto;
            pendingAuto = null;

            detector.OnKeyDown(vk);
            switchDetector.OnKeyDown(vk);
            if (vk is VK_LCONTROL or VK_RCONTROL or VK_LSHIFT or VK_RSHIFT or VK_PAUSE
                or 0xA4 or 0xA5 or 0x5B or 0x5C || tray.Shortcuts.IsRegisteredPress(vk))
                return false;

            tray.Shortcuts.CancelPending();
            caseCycle = null;
            Converter.ClearReconvert();
            if (ShortcutHeld() || InputTarget.Capture() is not { } target || target.IsPasswordEdit)
            {
                ResetInput();
                return false;
            }
            if (wordTarget != target)
            {
                buffer.Reset();
                wordTarget = target;
            }

            char? packet = settings.RemoteDesktopMode && vk == 0xE7 && sc is > 0 and <= char.MaxValue
                ? (char)sc : null;
            uint deferredKey = 0;
            if (!buffer.IsEmpty && settings.HasAutomaticEdits && !IsDown(VK_SHIFT))
            {
                bool space = (vk == KeystrokeBuffer.VK_SPACE || packet == ' ') && settings.WordEndOnSpace;
                bool deferred = (vk == KeystrokeBuffer.VK_RETURN && settings.WordEndOnEnter
                    || vk == KeystrokeBuffer.VK_TAB && settings.WordEndOnTab) && target.IsWritableNativeEdit;
                if ((space || deferred) && tray.PostAutoConvert())
                {
                    deferredKey = deferred ? vk : 0;
                    pendingAuto = (new List<TypedKey>(buffer.CurrentWord), target, inputGeneration, deferredKey, []);
                }
            }
            if (KeystrokeBuffer.IsTypingKey(vk) || packet is { } literal && !char.IsWhiteSpace(literal) && !char.IsControl(literal))
            {
                bool shift = IsDown(VK_SHIFT);
                bool caps = (GetKeyState(VK_CAPITAL) & 0x0001) != 0;
                var typed = new TypedKey(vk, sc, shift, caps, packet);
                buffer.Append(typed);
                if (pendingAuto == null && previousWord is { DeferredKey: 0 } pending &&
                    pending.Target == target && pending.Tail.Count < 32 && !shift && !caps)
                {
                    pending.Tail.Add(typed);
                    pendingAuto = (pending.Keys, pending.Target, inputGeneration, 0, pending.Tail);
                }
            }
            else buffer.Reset();
            return deferredKey != 0;
        };
        hook.KeyUp += (vk, sc) =>
        {
            if (!enabled) return;
            detector.OnKeyUp(vk);
            switchDetector.OnKeyUp(vk);
            if (tray.Shortcuts.HasPending) tray.PostShortcutPoll();
        };
        try { hook.Install(); keyboardHookReady = true; }
        catch (InvalidOperationException error)
        {
            hook.Dispose();
            Log(error.Message);
        }

        // Per-app layout memory (issue): restores each app's last-used layout on focus. Off by default.
        using var appTracker = new AppLayoutTracker();
        appTracker.Install();

        Updater.CheckOnLaunch(ui);
        using var updateTimer = new System.Windows.Forms.Timer { Interval = 30 * 60 * 1000 };
        updateTimer.Tick += (_, _) => Updater.CheckPeriodic();
        updateTimer.Start();

        Log($"NormalSwitcher started — keyboard hook={keyboardHookReady}, trigger={settings.Trigger}");

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
