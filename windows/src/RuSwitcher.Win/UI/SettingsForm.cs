using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using RuSwitcher.Win.Core;
using RuSwitcher.Win.Tray;

namespace RuSwitcher.Win.UI;

/// <summary>Settings shared with the tray and the running keyboard detectors.</summary>
internal sealed class SettingsForm : Form
{
    public event Action<TriggerKind>? TriggerChanged;
    public event Action? SwitchChanged;
    public event Action? AppearanceChanged;
    public event Action<bool>? KeyboardEnabledChanged;

    public SettingsForm(ClipboardHistory history, GlobalShortcuts globalShortcuts, string logPath)
    {
        var s = Settings.Current;
        Text = L10n.T("settings.title");
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Font;
        ClientSize = new Size(520, 296);

        var tabs = new TabControl { Dock = DockStyle.Fill };
        IntPtr[] layouts = [IntPtr.Zero, .. LayoutSwitcher.Installed()];
        string[] layoutNames = [L10n.T("settings.layout.auto"), .. layouts.Skip(1).Select(LayoutIcon.Name)];
        AddPage("general",
            Check("tray.enable", s.KeyboardEnabled, value => KeyboardEnabledChanged?.Invoke(value)),
            Check("settings.startup", AutoStart.IsEnabled(), AutoStart.SetEnabled),
            Check("settings.sound", s.SoundOnSwitch, value => { s.SoundOnSwitch = value; s.Save(); }),
            Check("settings.perapp", s.PerAppLayout, value => { s.PerAppLayout = value; s.Save(); }),
            Choice("settings.layout.first", layoutNames, Array.IndexOf(layouts, new IntPtr(s.FirstLayout)),
                index => { s.FirstLayout = layouts[index].ToInt64(); s.Save(); }),
            Choice("settings.layout.second", layoutNames, Array.IndexOf(layouts, new IntPtr(s.SecondLayout)),
                index => { s.SecondLayout = layouts[index].ToInt64(); s.Save(); }),
            new Label { Text = L10n.T("settings.layout.hint"), MaximumSize = new Size(440, 0), AutoSize = true },
            Choice("settings.language", [L10n.T("settings.layout.auto"), "English", "Русский"],
                Array.IndexOf(new[] { "", "en", "ru" }, s.UiLanguage), index =>
                {
                    s.UiLanguage = new[] { "", "en", "ru" }[index];
                    s.Save();
                }));

        var triggers = Enum.GetValues<TriggerKind>().Select(TrayIcon.TriggerName).ToArray();
        var configurable = Enum.GetValues<ShortcutAction>().Select(action =>
            ShortcutButton("hotkeys." + action, () => globalShortcuts.Get(action), chord => globalShortcuts.Set(action, chord)));
        AddPage("hotkeys",
            [Choice("settings.trigger", triggers, (int)s.Trigger, index =>
            {
                s.Trigger = (TriggerKind)index;
                s.Save();
                TriggerChanged?.Invoke(s.Trigger);
            }),
            Choice("settings.switchhotkey", [L10n.T("settings.off"), .. triggers],
                s.SwitchTriggerEnabled ? (int)s.SwitchTrigger + 1 : 0, index =>
                {
                    s.SwitchTriggerEnabled = index > 0;
                    if (index > 0) s.SwitchTrigger = (TriggerKind)(index - 1);
                    s.Save();
                    SwitchChanged?.Invoke();
                }),
            .. configurable]);

        var exceptions = new Button { Text = L10n.T("settings.exceptions"), AutoSize = true };
        exceptions.Click += (_, _) => { using var form = new ExceptionsForm(); form.ShowDialog(this); };
        var abbreviations = new Button { Text = L10n.T("settings.abbreviations"), AutoSize = true };
        abbreviations.Click += (_, _) => { using var form = new AbbreviationsForm(); form.ShowDialog(this); };
        AddPage("automatic",
            Check("settings.auto", s.AutoConvert, value => { s.AutoConvert = value; s.Save(); }),
            Check("settings.wordEnd.space", s.WordEndOnSpace, value => { s.WordEndOnSpace = value; s.Save(); }),
            Check("settings.wordEnd.enter", s.WordEndOnEnter, value => { s.WordEndOnEnter = value; s.Save(); }),
            Check("settings.wordEnd.tab", s.WordEndOnTab, value => { s.WordEndOnTab = value; s.Save(); }),
            Check("settings.fixCaps", s.FixTwoCaps, value => { s.FixTwoCaps = value; s.Save(); }),
            Check("settings.fixTypos", s.FixTypos, value => { s.FixTypos = value; s.Save(); }),
            Check("settings.frequencyWords", s.ExtendedDictionary, value => { s.ExtendedDictionary = value; s.Save(); }),
            abbreviations, exceptions);

        var persist = new CheckBox
        {
            Text = L10n.T("clipboard.persist"), AutoSize = true,
            Checked = s.ClipboardHistoryPersistent, Enabled = s.ClipboardHistoryEnabled,
        };
        persist.Click += (_, _) =>
        {
            if (!history.SetPersistence(persist.Checked))
            {
                persist.Checked = s.ClipboardHistoryPersistent;
                ShowClipboardError("clipboard.storageError");
            }
        };
        var shortcut = ShortcutButton("clipboard.shortcut", () => history.DisplayShortcut, history.SetCustomShortcut);
        var enabled = new CheckBox { Text = L10n.T("clipboard.enable"), AutoSize = true, Checked = s.ClipboardHistoryEnabled };
        enabled.Click += (_, _) =>
        {
            if (!history.SetEnabled(enabled.Checked))
            {
                enabled.Checked = s.ClipboardHistoryEnabled;
                ShowClipboardError("clipboard.storageError");
            }
            persist.Enabled = enabled.Checked;
        };
        AddPage("clipboard", enabled, shortcut, persist,
            new Label { Text = L10n.T("clipboard.hint"), MaximumSize = new Size(440, 0), AutoSize = true });

        var openLog = new Button { Text = L10n.T("settings.log.open"), AutoSize = true };
        openLog.Click += (_, _) =>
        {
            if (File.Exists(logPath))
            {
                try { using var process = Process.Start(new ProcessStartInfo(logPath) { UseShellExecute = true }); }
                catch { }
            }
            else MessageBox.Show(this, L10n.T("settings.log.empty"), Text);
        };
        AddPage("advanced",
            Check("settings.tray.hide", s.HideTrayIcon, value => SetAppearance(() => s.HideTrayIcon = value)),
            Check("settings.tray.mono", s.MonochromeTray, value => SetAppearance(() => s.MonochromeTray = value)),
            Check("settings.tray.caret", s.CaretIndicator, value => SetAppearance(() => s.CaretIndicator = value)),
            Check("settings.wholeline", s.ConvertWholeLine, value => { s.ConvertWholeLine = value; s.Save(); }),
            Check("settings.smart", s.SmartConversion, value => { s.SmartConversion = value; s.Save(); }),
            Check("settings.byText", s.ConvertByText, value => { s.ConvertByText = value; s.Save(); }),
            Check("settings.updates", s.CheckUpdatesEnabled, value => { s.CheckUpdatesEnabled = value; s.Save(); }),
            Check("settings.log.enable", s.DebugLogging, value => { s.DebugLogging = value; s.Save(); }),
            openLog);

        AddPage("about",
            new Label { Text = $"NormalSwitcher {Updater.Current.ToString(3)}", AutoSize = true },
            Link("github.com/antonjas/NormalSwitcher", "https://github.com/antonjas/NormalSwitcher"),
            Link(L10n.T("settings.credit"), "https://github.com/rashn/RuSwitcher"),
            Link("FrequencyWords · CC BY-SA 4.0", "https://github.com/antonjas/NormalSwitcher/blob/personal/dicts/LICENSE"));

        var close = new Button { Text = L10n.T("settings.close"), AutoSize = true, DialogResult = DialogResult.OK };
        var footer = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom, AutoSize = true, FlowDirection = FlowDirection.RightToLeft,
            Padding = new Padding(8)
        };
        footer.Controls.Add(close);
        CancelButton = close;
        Controls.Add(tabs);
        Controls.Add(footer);

        void SetAppearance(Action change)
        {
            change();
            s.Save();
            AppearanceChanged?.Invoke();
        }

        void ShowClipboardError(string key) =>
            MessageBox.Show(this, L10n.T(key), L10n.T("settings.title"), MessageBoxButtons.OK, MessageBoxIcon.Warning);

        void AddPage(string name, params Control[] controls)
        {
            var page = new TabPage(L10n.T("settings.tab." + name)) { UseVisualStyleBackColor = true };
            var stack = new FlowLayoutPanel
            {
                Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false,
                AutoScroll = true, Padding = new Padding(16)
            };
            foreach (var control in controls)
            {
                control.Margin = new Padding(0, 0, 0, 10);
                stack.Controls.Add(control);
            }
            page.Controls.Add(stack);
            tabs.TabPages.Add(page);
        }
    }

    private Control ShortcutButton(string key, Func<KeyChord?> current, Func<KeyChord?, bool> save)
    {
        var button = new Button { Text = current()?.ToString() ?? L10n.T("settings.off"), AutoSize = true };
        button.Click += (_, _) =>
        {
            using var recorder = new ShortcutRecorder();
            if (recorder.ShowDialog(this) != DialogResult.OK) return;
            if (save(recorder.Chord))
                button.Text = current()?.ToString() ?? L10n.T("settings.off");
            else
                MessageBox.Show(this, L10n.T("clipboard.hotkeyError"), Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        };
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        var title = new Label { Text = L10n.T(key), AutoSize = true, Margin = new Padding(0, 6, 8, 0) };
        row.Controls.AddRange([title, button]);
        return row;
    }

    private static CheckBox Check(string key, bool value, Action<bool> onChange)
    {
        var check = new CheckBox { Text = L10n.T(key), AutoSize = true, Checked = value };
        check.CheckedChanged += (_, _) => onChange(check.Checked);
        return check;
    }

    private static Control Choice(string key, string[] options, int selected, Action<int> onChange)
    {
        var row = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, RowCount = 1 };
        var label = new Label { Text = L10n.T(key), AutoSize = true, Anchor = AnchorStyles.Left };
        var combo = new ComboBox { Width = 210, DropDownStyle = ComboBoxStyle.DropDownList };
        combo.Items.AddRange(options);
        combo.SelectedIndex = Math.Clamp(selected, 0, options.Length - 1);
        combo.SelectionChangeCommitted += (_, _) => onChange(combo.SelectedIndex);
        row.Controls.Add(label, 0, 0);
        row.Controls.Add(combo, 1, 0);
        return row;
    }

    private static LinkLabel Link(string title, string url)
    {
        var link = new LinkLabel { Text = title, AutoSize = true };
        link.LinkClicked += (_, _) =>
        {
            try { using var browser = Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch { /* The rest of Settings is still available. */ }
        };
        return link;
    }
}
