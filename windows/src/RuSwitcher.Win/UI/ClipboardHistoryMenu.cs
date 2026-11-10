using System.Drawing;
using System.Windows.Forms;
using RuSwitcher.Win.Core;

namespace RuSwitcher.Win.UI;

internal sealed class ClipboardHistoryMenu : Form
{
    public string? Selection { get; private set; }
    public bool ClearRequested { get; private set; }

    public ClipboardHistoryMenu(string[] entries, bool storageError)
    {
        Text = L10n.T("clipboard.title");
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(360, Math.Min(270, 76 + entries.Length * 19));
        var pointer = Cursor.Position;
        var bounds = Screen.FromPoint(pointer).WorkingArea;
        Location = new Point(Math.Clamp(pointer.X, bounds.Left, Math.Max(bounds.Left, bounds.Right - Width)),
            Math.Clamp(pointer.Y, bounds.Top, Math.Max(bounds.Top, bounds.Bottom - Height)));

        var list = new ListBox { Dock = DockStyle.Fill, IntegralHeight = false };
        foreach (string entry in entries)
        {
            string preview = entry.ReplaceLineEndings(" ").Replace('\t', ' ');
            list.Items.Add(preview.Length > 80 ? preview[..80] + "…" : preview);
        }
        var paste = new Button { Text = L10n.T("clipboard.paste"), AutoSize = true, Enabled = entries.Length != 0 };
        if (entries.Length > 0) list.SelectedIndex = 0;
        else list.Items.Add(L10n.T("clipboard.empty"));

        void Choose()
        {
            if (list.SelectedIndex < 0 || list.SelectedIndex >= entries.Length) return;
            Selection = entries[list.SelectedIndex];
            DialogResult = DialogResult.OK;
        }
        paste.Click += (_, _) => Choose();
        list.DoubleClick += (_, _) => Choose();
        var clear = new Button { Text = L10n.T("clipboard.clear"), AutoSize = true };
        clear.Click += (_, _) => { ClearRequested = true; DialogResult = DialogResult.OK; };
        var close = new Button { Text = L10n.T("settings.close"), AutoSize = true, DialogResult = DialogResult.Cancel };
        var footer = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, FlowDirection = FlowDirection.RightToLeft };
        footer.Controls.AddRange([close, paste, clear]);
        Controls.Add(list);
        Controls.Add(footer);
        if (storageError)
            Controls.Add(new Label { Text = L10n.T("clipboard.storageError"), Dock = DockStyle.Top, AutoSize = true });
        AcceptButton = paste;
        CancelButton = close;
        Shown += (_, _) => list.Focus();
    }
}
