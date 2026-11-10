using System.Drawing;
using System.Windows.Forms;
using RuSwitcher.Win.Core;

namespace RuSwitcher.Win.UI;

internal sealed class ClipboardHistoryMenu : Form
{
    public string? Selection { get; private set; }

    public ClipboardHistoryMenu(string[] entries, bool storageError, Func<string[]?> retry, Func<bool> clearHistory)
    {
        Text = L10n.T("clipboard.title");
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(450, 330);
        var pointer = Cursor.Position;
        var bounds = Screen.FromPoint(pointer).WorkingArea;
        Location = new Point(Math.Clamp(pointer.X, bounds.Left, Math.Max(bounds.Left, bounds.Right - Width)),
            Math.Clamp(pointer.Y, bounds.Top, Math.Max(bounds.Top, bounds.Bottom - Height)));

        string[] visible = [];
        var search = new TextBox { Dock = DockStyle.Top, PlaceholderText = L10n.T("clipboard.search") };
        search.AccessibleName = search.PlaceholderText;
        var all = new CheckBox { Text = L10n.T("clipboard.all"), AutoSize = true };
        var count = new Label { AutoSize = true, Padding = new Padding(0, 5, 0, 0) };
        var summary = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true };
        summary.Controls.AddRange([all, count]);
        var list = new ListBox { Dock = DockStyle.Fill, IntegralHeight = false };
        var paste = new Button { Text = L10n.T("clipboard.paste"), AutoSize = true };
        var clear = new Button { Text = L10n.T("clipboard.clear"), AutoSize = true };
        var close = new Button { Text = L10n.T("settings.close"), AutoSize = true, DialogResult = DialogResult.Cancel };
        var retryButton = new Button { Text = L10n.T("clipboard.retry"), AutoSize = true };
        var warning = new Label { Text = L10n.T("clipboard.storageError"), AutoSize = true, Dock = DockStyle.Top };
        warning.Visible = retryButton.Visible = storageError;

        void RefreshEntries()
        {
            string query = search.Text.Trim();
            visible = query.Length == 0
                ? (all.Checked ? entries : entries.Take(8).ToArray())
                : entries.Where(entry => entry.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToArray();
            list.Items.Clear();
            foreach (string entry in visible)
            {
                string preview = entry.ReplaceLineEndings(" ").Replace('\t', ' ');
                list.Items.Add(preview.Length > 80 ? preview[..80] + "…" : preview);
            }
            if (visible.Length > 0) list.SelectedIndex = 0;
            else list.Items.Add(L10n.T(query.Length == 0 ? "clipboard.empty" : "clipboard.noMatches"));
            paste.Enabled = visible.Length > 0;
            count.Text = L10n.T("clipboard.count", visible.Length, entries.Length);
        }

        void Choose()
        {
            if (list.SelectedIndex < 0 || list.SelectedIndex >= visible.Length) return;
            Selection = visible[list.SelectedIndex];
            DialogResult = DialogResult.OK;
        }

        search.TextChanged += (_, _) => RefreshEntries();
        all.CheckedChanged += (_, _) => RefreshEntries();
        paste.Click += (_, _) => Choose();
        list.DoubleClick += (_, _) => Choose();
        retryButton.Click += (_, _) =>
        {
            if (retry() is not { } restored) return;
            entries = restored;
            warning.Visible = retryButton.Visible = false;
            RefreshEntries();
        };
        clear.Click += (_, _) =>
        {
            if (MessageBox.Show(this, L10n.T("clipboard.confirmClear"), Text,
                MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                return;
            bool cleared = clearHistory();
            warning.Visible = retryButton.Visible = !cleared;
            if (!cleared) return;
            entries = [];
            RefreshEntries();
        };
        var footer = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, FlowDirection = FlowDirection.RightToLeft };
        footer.Controls.AddRange([close, paste, clear, retryButton]);
        Controls.Add(list);
        Controls.Add(warning);
        Controls.Add(summary);
        Controls.Add(search);
        Controls.Add(footer);
        AcceptButton = paste;
        CancelButton = close;
        Shown += (_, _) => search.Focus();
        RefreshEntries();
    }
}
