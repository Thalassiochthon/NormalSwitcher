using System.Drawing;
using System.Windows.Forms;
using RuSwitcher.Win.Core;

namespace RuSwitcher.Win.UI;

/// <summary>Editor for the auto-conversion exception lists — the Windows counterpart of the macOS
/// exception lists. "Never convert" holds typed words that must be left alone (grown automatically by
/// learn-from-undo); "Always convert" holds target-form words that are always flipped. One word per
/// line, lower-cased on save.</summary>
internal sealed class ExceptionsForm : Form
{
    private readonly TextBox _never;
    private readonly TextBox _always;
    private readonly TextBox _apps;

    public ExceptionsForm()
    {
        var s = Settings.Current;

        Text = L10n.T("exc.title");
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(686, 320);

        var lblNever = new Label { Text = L10n.T("exc.never"), Left = 16, Top = 12, AutoSize = true };
        _never = MakeList(16, s.NeverConvert);

        var lblAlways = new Label { Text = L10n.T("exc.always"), Left = 236, Top = 12, AutoSize = true };
        _always = MakeList(236, s.AlwaysConvert);

        var lblApps = new Label { Text = L10n.T("exc.apps"), Left = 456, Top = 12, AutoSize = true };
        _apps = MakeList(456, s.ExcludedApps);

        var btnOk = new Button { Text = L10n.T("exc.save"), Left = 496, Top = 280, Width = 84, DialogResult = DialogResult.OK };
        var btnCancel = new Button { Text = L10n.T("exc.cancel"), Left = 590, Top = 280, Width = 84, DialogResult = DialogResult.Cancel };
        AcceptButton = btnOk;
        CancelButton = btnCancel;
        btnOk.Click += (_, _) =>
        {
            s.NeverConvert = Parse(_never.Text);
            s.AlwaysConvert = Parse(_always.Text);
            s.ExcludedApps = Parse(_apps.Text)
                .Select(app => app.EndsWith(".exe") ? app[..^4] : app)
                .Where(app => app.Length > 0).Distinct().ToList();
            s.Save();
        };

        Controls.AddRange(new Control[] { lblNever, _never, lblAlways, _always, lblApps, _apps, btnOk, btnCancel });
    }

    private static TextBox MakeList(int left, System.Collections.Generic.IEnumerable<string> items) => new()
    {
        Left = left,
        Top = 34,
        Width = 208,
        Height = 234,
        Multiline = true,
        ScrollBars = ScrollBars.Vertical,
        WordWrap = false,
        Text = string.Join(Environment.NewLine, items),
    };

    private static System.Collections.Generic.List<string> Parse(string text) =>
        text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(w => w.Trim().ToLowerInvariant())
            .Where(w => w.Length > 0)
            .Distinct()
            .ToList();
}
