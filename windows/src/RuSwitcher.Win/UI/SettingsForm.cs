using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using RuSwitcher.Win.Core;
using RuSwitcher.Win.Tray;

namespace RuSwitcher.Win.UI;

/// <summary>Settings shared with the tray and the running keyboard detectors.</summary>
internal sealed class SettingsForm : Form
{
    private readonly TableLayoutPanel _navigation;
    private readonly Panel _pages;
    private readonly Label _heading;
    private readonly Color _accent = SystemInformation.HighContrast ? SystemColors.HotTrack : Color.FromArgb(91, 52, 166);
    private readonly Color _selected = SystemInformation.HighContrast ? SystemColors.Highlight : Color.FromArgb(233, 224, 253);
    private readonly Color _navigationSurface = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(246, 243, 251);
    private readonly List<(Button Button, Panel Page)> _sections = new();
    private Bitmap? _aboutIcon;
    private int _activeSection;

    public event Action<TriggerKind>? TriggerChanged;
    public event Action? SwitchChanged;
    public event Action? AppearanceChanged;
    public event Action<bool>? KeyboardEnabledChanged;

    public SettingsForm(ClipboardHistory history, GlobalShortcuts globalShortcuts, string logPath, bool keyboardHookReady, Action? openTasks = null)
    {
        var s = Settings.Current;
        Text = L10n.T("settings.title");
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 10F);
        ClientSize = new Size(760, 570);
        BackColor = SystemColors.Window;
        ForeColor = SystemColors.WindowText;
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        SuspendLayout();

        var shell = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = Padding.Empty };
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 194));
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(shell);

        var sidebar = new Panel
        {
            Dock = DockStyle.Fill, Margin = Padding.Empty, BackColor = _navigationSurface,
            Padding = new Padding(12, 26, 12, 12)
        };
        shell.Controls.Add(sidebar, 0, 0);
        _navigation = Stack();
        sidebar.Controls.Add(_navigation);
        var brand = TextLabel("NormalSwitcher", 11, FontStyle.Bold);
        brand.Padding = new Padding(8, 0, 0, 18);
        brand.ForeColor = _accent;
        _navigation.Controls.Add(brand);

        var content = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Margin = Padding.Empty };
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        content.RowStyles.Add(new RowStyle(SizeType.Absolute, 84));
        content.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        content.RowStyles.Add(new RowStyle(SizeType.Absolute, 64));
        shell.Controls.Add(content, 1, 0);

        _heading = TextLabel("", 22, FontStyle.Bold);
        _heading.Dock = DockStyle.Fill;
        _heading.TextAlign = ContentAlignment.MiddleLeft;
        _heading.Padding = new Padding(26, 0, 0, 0);
        _heading.AccessibleRole = AccessibleRole.StaticText;
        content.Controls.Add(_heading, 0, 0);
        _pages = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty };
        content.Controls.Add(_pages, 0, 1);

        IntPtr[] layouts = [IntPtr.Zero, .. LayoutSwitcher.Installed()];
        string[] layoutNames = [L10n.T("settings.layout.auto"), .. layouts.Skip(1).Select(LayoutIcon.Name)];
        AddPage("general",
            Check("tray.enable", s.KeyboardEnabled, value => KeyboardEnabledChanged?.Invoke(value)),
            Check("settings.startup", AutoStart.IsEnabled(), AutoStart.SetEnabled),
            Check("settings.sound", s.SoundOnSwitch, value => { s.SoundOnSwitch = value; s.Save(); }),
            Choice("settings.sound.choice", Sound.Choices.Select(sound => L10n.T("settings.sound." + sound)).ToArray(),
                Array.IndexOf(Sound.Choices.ToArray(), Sound.Resolve(s.LayoutSound)),
                index => { s.LayoutSound = Sound.Choices[index]; s.Save(); },
                index => Sound.Play(Sound.Choices[index])),
            Check("settings.perapp", s.PerAppLayout, value => { s.PerAppLayout = value; s.Save(); }),
            Choice("settings.layout.first", layoutNames, Array.IndexOf(layouts, new IntPtr(s.FirstLayout)),
                index => { s.FirstLayout = layouts[index].ToInt64(); s.Save(); }),
            Choice("settings.layout.second", layoutNames, Array.IndexOf(layouts, new IntPtr(s.SecondLayout)),
                index => { s.SecondLayout = layouts[index].ToInt64(); s.Save(); }),
            Hint("settings.layout.hint"),
            Choice("settings.language", [L10n.T("settings.layout.auto"), "English", "Русский"],
                Array.IndexOf(new[] { "", "en", "ru" }, s.UiLanguage), index =>
                {
                    s.UiLanguage = new[] { "", "en", "ru" }[index];
                    s.Save();
                }));

        var triggers = Enum.GetValues<TriggerKind>().Select(TrayIcon.TriggerName).ToArray();
        var configurable = Enum.GetValues<ShortcutAction>().Select(action =>
            ShortcutButton("hotkeys." + action, () => globalShortcuts.Get(action), chord => globalShortcuts.Set(action, chord),
                () => globalShortcuts.IsRegistered(action)));
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
            Section("settings.group.wordEnd"),
            Check("settings.wordEnd.space", s.WordEndOnSpace, value => { s.WordEndOnSpace = value; s.Save(); }),
            Check("settings.wordEnd.enter", s.WordEndOnEnter, value => { s.WordEndOnEnter = value; s.Save(); }),
            Check("settings.wordEnd.tab", s.WordEndOnTab, value => { s.WordEndOnTab = value; s.Save(); }),
            Section("settings.group.text"),
            Check("settings.fixCaps", s.FixTwoCaps, value => { s.FixTwoCaps = value; s.Save(); }),
            Check("settings.fixTypos", s.FixTypos, value => { s.FixTypos = value; s.Save(); }),
            Check("settings.frequencyWords", s.ExtendedDictionary, value => { s.ExtendedDictionary = value; s.Save(); }),
            Actions(abbreviations, exceptions));

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
        var shortcut = ShortcutButton("clipboard.shortcut", () => history.DisplayShortcut, history.SetCustomShortcut,
            () => !s.ClipboardHistoryEnabled || history.ShortcutRegistered);
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
        var tasks = new Button { Text = L10n.T("tasks.title"), AutoSize = true };
        tasks.Click += (_, _) => { Close(); openTasks?.Invoke(); };
        AddPage("clipboard", enabled, shortcut, persist, tasks,
            Hint("clipboard.hint"));

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
        var checkAccess = new Button { Text = L10n.T("settings.access.check"), AutoSize = true };
        checkAccess.Click += (_, _) => MessageBox.Show(this,
            L10n.T(keyboardHookReady ? "settings.access.ready" : "settings.access.failed"), Text);
        AddPage("advanced",
            Check("settings.tray.hide", s.HideTrayIcon, value => SetAppearance(() => s.HideTrayIcon = value)),
            Check("settings.tray.mono", s.MonochromeTray, value => SetAppearance(() => s.MonochromeTray = value)),
            Check("settings.tray.caret", s.CaretIndicator, value => SetAppearance(() => s.CaretIndicator = value)),
            Check("settings.wholeline", s.ConvertWholeLine, value => { s.ConvertWholeLine = value; s.Save(); }),
            Check("settings.smart", s.SmartConversion, value => { s.SmartConversion = value; s.Save(); }),
            Check("settings.byText", s.ConvertByText, value => { s.ConvertByText = value; s.Save(); }),
            Check("upd.beta", s.ReceiveBetaUpdates, value => { s.ReceiveBetaUpdates = value; Updater.UpdatePreferenceChanged(); }),
            Check("settings.updates", s.CheckUpdatesEnabled, value => { s.CheckUpdatesEnabled = value; s.Save(); }),
            Check("settings.remote", s.RemoteDesktopMode, value => { s.RemoteDesktopMode = value; s.Save(); }),
            Check("settings.log.enable", s.DebugLogging, value => { s.DebugLogging = value; s.Save(); }),
            Actions(checkAccess, openLog));

        AddPage("about",
            AboutHeader(),
            Hint("settings.about.description"),
            Section("settings.about.project"),
            Link(L10n.T("settings.about.github"), "https://github.com/antonjas/NormalSwitcher"),
            Link(L10n.T("settings.about.releases"), "https://github.com/antonjas/NormalSwitcher/releases"),
            Section("settings.about.credits"),
            Link(L10n.T("settings.credit"), "https://github.com/rashn/RuSwitcher"),
            Link("FrequencyWords · CC BY-SA 4.0", "https://github.com/antonjas/NormalSwitcher/blob/personal/dicts/LICENSE"));

        var close = new Button { Text = L10n.T("settings.close"), AutoSize = true, DialogResult = DialogResult.OK,
            MinimumSize = new Size(106, 32) };
        var footer = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft,
            Padding = new Padding(20, 12, 22, 0), Margin = Padding.Empty
        };
        footer.Controls.Add(close);
        CancelButton = close;
        content.Controls.Add(footer, 0, 2);

        SelectSection(0);
        ResumeLayout(performLayout: true);

        void SetAppearance(Action change)
        {
            change();
            s.Save();
            AppearanceChanged?.Invoke();
        }

        void ShowClipboardError(string key) =>
            MessageBox.Show(this, L10n.T(key), L10n.T("settings.title"), MessageBoxButtons.OK, MessageBoxIcon.Warning);

    }

    protected override void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        FitWorkingArea();
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        FitWorkingArea();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData is not (Keys.Control | Keys.Tab) and not (Keys.Control | Keys.Shift | Keys.Tab))
            return base.ProcessCmdKey(ref msg, keyData);

        int direction = keyData.HasFlag(Keys.Shift) ? -1 : 1;
        int index = (_activeSection + direction + _sections.Count) % _sections.Count;
        SelectSection(index);
        _sections[index].Button.Focus();
        return true;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _aboutIcon?.Dispose();
        base.Dispose(disposing);
    }

    private void FitWorkingArea()
    {
        var area = Screen.FromControl(this).WorkingArea;
        var preferred = SizeFromClientSize(LogicalToDeviceUnits(new Size(760, 570)));
        Size = new Size(Math.Min(preferred.Width, area.Width), Math.Min(preferred.Height, area.Height));
        Location = new Point(
            Math.Clamp(Left, area.Left, area.Right - Width),
            Math.Clamp(Top, area.Top, area.Bottom - Height));
    }

    private void AddPage(string name, params Control[] controls)
    {
        int index = _sections.Count;
        var button = new Button
        {
            Text = L10n.T("settings.tab." + name), TextAlign = ContentAlignment.MiddleLeft,
            Height = 39, Dock = DockStyle.Top, Margin = new Padding(0, 0, 0, 3),
            FlatStyle = FlatStyle.Flat, Padding = new Padding(9, 0, 3, 0),
            UseVisualStyleBackColor = false
        };
        button.FlatAppearance.BorderSize = 0;
        button.Click += (_, _) => SelectSection(index);
        _navigation.Controls.Add(button);

        var page = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Visible = false, Name = name };
        var stack = Stack();
        stack.Padding = new Padding(26, 4, 24, 6);
        foreach (var control in controls)
        {
            control.Margin = new Padding(0, 0, 0, 8);
            control.Anchor = AnchorStyles.Left | AnchorStyles.Right;
            stack.Controls.Add(control);
        }
        // Reserve a scrollbar gutter so text has the same wrap width when it appears.
        void WrapRows()
        {
            int width = Math.Max(1, page.ClientSize.Width - stack.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth);
            foreach (var row in controls)
                row.MaximumSize = new Size(width, 0);
        }
        page.ClientSizeChanged += (_, _) => WrapRows();
        page.DpiChangedAfterParent += (_, _) => WrapRows();
        page.Controls.Add(stack);
        _pages.Controls.Add(page);
        _sections.Add((button, page));
    }

    private void SelectSection(int index)
    {
        _activeSection = index;
        foreach (var (button, page) in _sections)
        {
            bool active = ReferenceEquals(page, _sections[index].Page);
            page.Visible = active;
            button.BackColor = active ? _selected : _navigationSurface;
            button.ForeColor = active
                ? SystemInformation.HighContrast ? SystemColors.HighlightText : _accent
                : SystemColors.WindowText;
        }
        _heading.Text = _sections[index].Button.Text;
    }

    private static TableLayoutPanel Stack()
    {
        var stack = new TableLayoutPanel
        {
            Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 1, GrowStyle = TableLayoutPanelGrowStyle.AddRows, Margin = Padding.Empty
        };
        stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        return stack;
    }

    private static Label TextLabel(string text, float size, FontStyle style = FontStyle.Regular) =>
        new() { Text = text, AutoSize = true, Font = new Font("Segoe UI", size, style) };

    private Label Section(string key)
    {
        var title = TextLabel(L10n.T(key), 10, FontStyle.Bold);
        title.ForeColor = _accent;
        title.Padding = new Padding(0, 9, 0, 1);
        return title;
    }

    private static Label Hint(string key) => new()
    {
        Text = L10n.T(key), AutoSize = true, ForeColor = SystemColors.WindowText
    };

    private Control AboutHeader()
    {
        _aboutIcon = Icon?.ToBitmap();
        var header = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Padding = new Padding(0, 2, 0, 10) };
        var logo = new PictureBox
        {
            Image = _aboutIcon, Size = new Size(64, 64), SizeMode = PictureBoxSizeMode.Zoom,
            Margin = new Padding(0, 0, 16, 0)
        };
        var details = new FlowLayoutPanel
        {
            AutoSize = true, WrapContents = false, FlowDirection = FlowDirection.TopDown,
            Padding = new Padding(0, 4, 0, 0)
        };
        details.Controls.Add(TextLabel("NormalSwitcher", 17, FontStyle.Bold));
        details.Controls.Add(TextLabel(L10n.T("settings.about.version", Updater.CurrentRelease), 10));
        header.Controls.AddRange([logo, details]);
        return header;
    }

    private static Control Actions(params Button[] buttons)
    {
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = true };
        row.Controls.AddRange(buttons);
        return row;
    }

    private Control ShortcutButton(string key, Func<KeyChord?> current, Func<KeyChord?, bool> save, Func<bool>? registered = null)
    {
        string Display() => current() is not { } chord ? L10n.T("settings.off") :
            registered?.Invoke() == false ? L10n.T("tasks.shortcutUnavailable", chord) : chord.ToString();
        var button = new Button { Text = Display(), AutoSize = true };
        button.Click += (_, _) =>
        {
            using var recorder = new ShortcutRecorder();
            if (recorder.ShowDialog(this) != DialogResult.OK) return;
            if (save(recorder.Chord))
                button.Text = Display();
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

    private static Control Choice(string key, string[] options, int selected, Action<int> onChange,
        Action<int>? onPreview = null)
    {
        var row = new TableLayoutPanel { AutoSize = true, ColumnCount = onPreview is null ? 2 : 3, RowCount = 1 };
        var label = new Label { Text = L10n.T(key), AutoSize = true, Anchor = AnchorStyles.Left };
        var combo = new ComboBox { Width = 210, DropDownStyle = ComboBoxStyle.DropDownList };
        combo.Items.AddRange(options);
        combo.SelectedIndex = Math.Clamp(selected, 0, options.Length - 1);
        combo.SelectionChangeCommitted += (_, _) => onChange(combo.SelectedIndex);
        row.Controls.Add(label, 0, 0);
        row.Controls.Add(combo, 1, 0);
        if (onPreview is not null)
        {
            var preview = new Button { Text = L10n.T("settings.sound.preview"), AutoSize = true };
            preview.Click += (_, _) => onPreview(combo.SelectedIndex);
            row.Controls.Add(preview, 2, 0);
        }
        return row;
    }

    private LinkLabel Link(string title, string url)
    {
        var link = new LinkLabel { Text = title, AutoSize = true, LinkColor = _accent };
        link.LinkClicked += (_, _) =>
        {
            try { using var browser = Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch { /* The rest of Settings is still available. */ }
        };
        return link;
    }
}
