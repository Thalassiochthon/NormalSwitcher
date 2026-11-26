using System.Drawing;
using System.Windows.Forms;
using RuSwitcher.Win.Core;

namespace RuSwitcher.Win.UI;

internal sealed class ClipboardHistoryMenu : Form
{
    public string? TaskText { get; private set; }
    public ClipboardEntry? Selection { get; private set; }

    public ClipboardHistoryMenu(ClipboardEntry[] entries, bool storageError, Func<ClipboardEntry[]?> retry, Func<bool> clearHistory, bool tasksAvailable)
    {
        Text = L10n.T("clipboard.title");
        FormBorderStyle = FormBorderStyle.SizableToolWindow;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        MinimumSize = new Size(360, 300);
        var settings = Settings.Current;
        var initial = new Size(Math.Clamp(settings.ClipboardWindowWidth, 360, 1800),
            Math.Clamp(settings.ClipboardWindowHeight, 300, 1200));
        ClientSize = initial;
        var pointer = Cursor.Position;
        var bounds = Screen.FromPoint(pointer).WorkingArea;
        Location = new Point(Math.Clamp(pointer.X, bounds.Left, Math.Max(bounds.Left, bounds.Right - Width)),
            Math.Clamp(pointer.Y, bounds.Top, Math.Max(bounds.Top, bounds.Bottom - Height)));

        ClipboardEntry[] visible = [];
        var search = new TextBox { Dock = DockStyle.Top, PlaceholderText = L10n.T("clipboard.search") };
        search.AccessibleName = search.PlaceholderText;
        var all = new CheckBox { Text = L10n.T("clipboard.all"), AutoSize = true };
        var count = new Label { AutoSize = true, Padding = new Padding(0, 5, 0, 0) };
        var summary = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true };
        summary.Controls.AddRange([all, count]);
        var list = new ListBox { Dock = DockStyle.Fill, IntegralHeight = false };
        var previewImage = new PictureBox { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, Visible = false };
        var previewText = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true,
            ScrollBars = ScrollBars.Vertical, TabStop = false };
        var preview = new Panel { Dock = DockStyle.Bottom, Height = 110 };
        preview.Controls.AddRange([previewText, previewImage]);
        var paste = new Button { Text = L10n.T("clipboard.paste"), AutoSize = true };
        var task = new Button { Text = L10n.T("tasks.add"), AutoSize = true, Visible = tasksAvailable };
        task.Click += (_, _) =>
        {
            if (list.SelectedIndex < 0 || list.SelectedIndex >= visible.Length) return;
            if (visible[list.SelectedIndex].Text is not { } text) return;
            TaskText = text;
            DialogResult = DialogResult.OK;
        };
        var clear = new Button { Text = L10n.T("clipboard.clear"), AutoSize = true };
        var close = new Button { Text = L10n.T("settings.close"), AutoSize = true, DialogResult = DialogResult.Cancel };
        var retryButton = new Button { Text = L10n.T("clipboard.retry"), AutoSize = true };
        var warning = new Label { Text = L10n.T("clipboard.storageError"), AutoSize = true, Dock = DockStyle.Top };
        warning.Visible = retryButton.Visible = storageError;

        string LabelFor(ClipboardEntry entry) => entry.Png is not null
            ? L10n.T("clipboard.image", entry.Width, entry.Height)
            : entry.Text!.ReplaceLineEndings(" ").Replace('	', ' ');

        void UpdatePreview()
        {
            int index = list.SelectedIndex;
            var entry = index >= 0 && index < visible.Length ? visible[index] : null;
            var previous = previewImage.Image;
            previewImage.Image = entry?.OpenImage();
            previous?.Dispose();
            previewImage.Visible = previewImage.Image is not null;
            previewText.Visible = !previewImage.Visible;
            previewText.Text = entry is null ? "" : entry.Text ?? LabelFor(entry);
            paste.Enabled = entry is not null;
            task.Enabled = entry?.Text is not null;
        }

        void RefreshEntries()
        {
            string query = search.Text.Trim();
            visible = query.Length == 0
                ? (all.Checked ? entries : entries.Take(8).ToArray())
                : entries.Where(entry => (entry.Text ?? LabelFor(entry))
                    .Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToArray();
            list.Items.Clear();
            foreach (var entry in visible)
            {
                string label = LabelFor(entry);
                list.Items.Add(label.Length > 120 ? label[..120] + "…" : label);
            }
            if (visible.Length > 0) list.SelectedIndex = 0;
            else list.Items.Add(L10n.T(query.Length == 0 ? "clipboard.empty" : "clipboard.noMatches"));
            UpdatePreview();
            count.Text = L10n.T("clipboard.count", visible.Length, entries.Length);
        }

        void Choose()
        {
            if (list.SelectedIndex < 0 || list.SelectedIndex >= visible.Length) return;
            Selection = visible[list.SelectedIndex];
            DialogResult = DialogResult.OK;
        }

        list.SelectedIndexChanged += (_, _) => UpdatePreview();
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
        footer.Controls.AddRange([close, paste, task, clear, retryButton]);
        Controls.Add(list);
        Controls.Add(preview);
        Controls.Add(warning);
        Controls.Add(summary);
        Controls.Add(search);
        Controls.Add(footer);
        AcceptButton = paste;
        CancelButton = close;
        Shown += (_, _) =>
        {
            var area = Screen.FromPoint(pointer).WorkingArea;
            Size = new Size(Math.Min(Width, area.Width), Math.Min(Height, area.Height));
            Location = new Point(Math.Clamp(pointer.X, area.Left, Math.Max(area.Left, area.Right - Width)),
                Math.Clamp(pointer.Y, area.Top, Math.Max(area.Top, area.Bottom - Height)));
            search.Focus();
        };
        FormClosed += (_, _) =>
        {
            settings.ClipboardWindowWidth = ClientSize.Width * 96 / DeviceDpi;
            settings.ClipboardWindowHeight = ClientSize.Height * 96 / DeviceDpi;
            settings.Save();
        };
        Disposed += (_, _) => previewImage.Image?.Dispose();
        RefreshEntries();
    }
}
