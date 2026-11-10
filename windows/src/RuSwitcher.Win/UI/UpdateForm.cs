using System.Drawing;
using RuSwitcher.Win.Core;

namespace RuSwitcher.Win.UI;

internal sealed class UpdateForm : Form
{
    public event Action? Install;
    public event Action? DownloadPage;

    private readonly Label _status;
    private readonly ProgressBar _progress;
    private readonly Button _primary;
    private readonly Button _later;
    private bool _working;
    private bool _failed;
    private bool _downloading;

    public UpdateForm(string version, string current, string notes)
    {
        Text = L10n.T("upd.available.title");
        AutoScaleMode = AutoScaleMode.Font;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ClientSize = new Size(480, 344);
        BackColor = SystemColors.Window;
        ForeColor = SystemColors.WindowText;
        using var appIcon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        Icon = appIcon is null ? SystemIcons.Application : (Icon)appIcon.Clone();

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 6, Padding = new Padding(24) };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (float height in new[] { 58f, 35f })
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        foreach (float height in new[] { 38f, 22f, 40f })
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        Controls.Add(layout);

        var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 58));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var logo = new PictureBox { Image = Icon.ToBitmap(), Size = new Size(40, 40), SizeMode = PictureBoxSizeMode.Zoom, Anchor = AnchorStyles.Left };
        var heading = new Label { Text = L10n.T("upd.heading"), AutoSize = true, Anchor = AnchorStyles.Left,
            Font = new Font(Font.FontFamily, 17, FontStyle.Bold) };
        header.Controls.Add(logo, 0, 0);
        header.Controls.Add(heading, 1, 0);
        layout.Controls.Add(header, 0, 0);
        layout.Controls.Add(new Label { Text = L10n.T("upd.versions", version, current), Dock = DockStyle.Fill }, 0, 1);
        if (!string.IsNullOrWhiteSpace(notes))
        {
            var changes = new TextBox
            {
                AccessibleName = L10n.T("upd.notes"), Text = notes.ReplaceLineEndings(),
                Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical,
                Dock = DockStyle.Fill, BackColor = SystemColors.Window, BorderStyle = BorderStyle.FixedSingle,
            };
            layout.Controls.Add(changes, 0, 2);
        }

        _status = new Label { Text = L10n.T("upd.restartHint"), Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft };
        _progress = new ProgressBar { Dock = DockStyle.Fill, Visible = false };
        layout.Controls.Add(_status, 0, 3);
        layout.Controls.Add(_progress, 0, 4);

        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
        _primary = new Button { Text = L10n.T("upd.update"), AutoSize = true, MinimumSize = new Size(115, 30) };
        _later = new Button { Text = L10n.T("upd.later"), DialogResult = DialogResult.Cancel, AutoSize = true,
            MinimumSize = new Size(90, 30) };
        if (!SystemInformation.HighContrast)
        {
            _primary.FlatStyle = FlatStyle.Flat;
            _primary.FlatAppearance.BorderSize = 0;
            _primary.BackColor = Color.FromArgb(102, 64, 188);
            _primary.ForeColor = Color.White;
        }
        actions.Controls.Add(_primary);
        actions.Controls.Add(_later);
        layout.Controls.Add(actions, 0, 5);
        AcceptButton = _primary;
        CancelButton = _later;
        Shown += (_, _) => _primary.Focus();
        FormClosing += (_, e) => e.Cancel = _working;
        _primary.Click += (_, _) =>
        {
            if (_failed) { DownloadPage?.Invoke(); Close(); return; }
            _working = true;
            _primary.Enabled = _later.Enabled = false;
            ShowStage("upd.downloading");
            Install?.Invoke();
        };
    }

    public void ReportDownload(int? percent)
    {
        if (!_working || !_downloading || percent is not { } value) return;
        _progress.Style = ProgressBarStyle.Continuous;
        _progress.Value = value;
        _status.Text = L10n.T("upd.percent", value);
    }

    public void ShowStage(string key)
    {
        _status.Text = L10n.T(key);
        _downloading = key == "upd.downloading";
        _progress.AccessibleName = _status.Text;
        _progress.Style = ProgressBarStyle.Marquee;
        _progress.Visible = true;
    }

    public void Complete()
    {
        _working = false;
        Close();
    }

    public void ShowError()
    {
        _working = false;
        _failed = true;
        _downloading = false;
        _progress.Visible = false;
        _status.Text = L10n.T("upd.failed");
        _primary.Text = L10n.T("upd.releases");
        _primary.Enabled = _later.Enabled = true;
        _later.Text = L10n.T("upd.close");
    }
}
