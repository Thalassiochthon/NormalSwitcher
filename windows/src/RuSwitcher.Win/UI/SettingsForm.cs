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

    public SettingsForm()
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
        AddPage("general",
            Check("settings.startup", AutoStart.IsEnabled(), AutoStart.SetEnabled),
            Check("settings.sound", s.SoundOnSwitch, value => { s.SoundOnSwitch = value; s.Save(); }),
            Check("settings.perapp", s.PerAppLayout, value => { s.PerAppLayout = value; s.Save(); }));

        var triggers = Enum.GetValues<TriggerKind>().Select(TrayIcon.TriggerName).ToArray();
        AddPage("hotkeys",
            Choice("settings.trigger", triggers, (int)s.Trigger, index =>
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
                }));

        var exceptions = new Button { Text = L10n.T("settings.exceptions"), AutoSize = true };
        exceptions.Click += (_, _) => { using var form = new ExceptionsForm(); form.ShowDialog(this); };
        AddPage("automatic",
            Check("settings.auto", s.AutoConvert, value => { s.AutoConvert = value; s.Save(); }),
            exceptions);

        AddPage("advanced",
            Check("settings.wholeline", s.ConvertWholeLine, value => { s.ConvertWholeLine = value; s.Save(); }),
            Check("settings.smart", s.SmartConversion, value => { s.SmartConversion = value; s.Save(); }),
            Check("settings.updates", s.CheckUpdatesEnabled, value => { s.CheckUpdatesEnabled = value; s.Save(); }));

        AddPage("about",
            new Label { Text = $"NormalSwitcher {Updater.Current.ToString(3)}", AutoSize = true },
            Link("github.com/antonjas/NormalSwitcher", "https://github.com/antonjas/NormalSwitcher"),
            Link(L10n.T("settings.credit"), "https://github.com/rashn/RuSwitcher"));

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
        combo.SelectedIndex = selected;
        combo.SelectedIndexChanged += (_, _) => onChange(combo.SelectedIndex);
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
