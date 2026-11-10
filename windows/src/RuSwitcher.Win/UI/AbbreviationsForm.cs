using System.Drawing;
using System.Windows.Forms;
using RuSwitcher.Win.Core;

namespace RuSwitcher.Win.UI;

internal sealed class AbbreviationsForm : Form
{
    public AbbreviationsForm()
    {
        Text = L10n.T("settings.abbreviations");
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(460, 300);
        MinimumSize = new Size(390, 250);
        var help = new Label
        {
            Text = L10n.T("settings.abbreviations.hint"), Dock = DockStyle.Top, Height = 40
        };
        var editor = new TextBox
        {
            Dock = DockStyle.Fill, Multiline = true, ScrollBars = ScrollBars.Vertical,
            Text = string.Join(Environment.NewLine, Settings.Current.Abbreviations.Select(kv => $"{kv.Key} = {kv.Value}"))
        };
        var save = new Button { Text = L10n.T("exc.save"), AutoSize = true };
        save.Click += (_, _) =>
        {
            var entries = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var line in editor.Lines)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                int separator = line.IndexOf('=');
                string key = separator > 0 ? line[..separator].Trim().ToLowerInvariant() : "";
                string value = separator > 0 ? line[(separator + 1)..].Trim() : "";
                if (key.Length is 0 or > 64 || key.Any(char.IsWhiteSpace)
                    || value.Length is 0 or > 500 || !entries.TryAdd(key, value))
                {
                    MessageBox.Show(this, L10n.T("settings.abbreviations.error"), Text,
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
            }
            Settings.Current.Abbreviations = entries;
            Settings.Current.Save();
            DialogResult = DialogResult.OK;
        };
        var cancel = new Button { Text = L10n.T("exc.cancel"), AutoSize = true, DialogResult = DialogResult.Cancel };
        var footer = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom, AutoSize = true, FlowDirection = FlowDirection.RightToLeft
        };
        footer.Controls.AddRange([cancel, save]);
        CancelButton = cancel;
        Controls.Add(editor);
        Controls.Add(footer);
        Controls.Add(help);
    }
}
