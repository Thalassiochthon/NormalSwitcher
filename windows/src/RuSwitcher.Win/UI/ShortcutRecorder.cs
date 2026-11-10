using System.Drawing;
using System.Windows.Forms;
using RuSwitcher.Win.Core;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.UI;

internal sealed class ShortcutRecorder : Form
{
    public KeyChord? Chord { get; private set; }

    public ShortcutRecorder()
    {
        Text = L10n.T("hotkeys.record");
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MinimizeBox = MaximizeBox = false;
        ClientSize = new Size(410, 104);
        var hint = new Label
        {
            Text = L10n.T("hotkeys.recordHint"), Dock = DockStyle.Fill, Padding = new Padding(12)
        };
        var clear = new Button { Text = L10n.T("hotkeys.clear"), AutoSize = true, DialogResult = DialogResult.OK };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, FlowDirection = FlowDirection.RightToLeft };
        buttons.Controls.Add(clear);
        Controls.Add(hint);
        Controls.Add(buttons);
    }

    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        Keys key = keyData & Keys.KeyCode;
        if (key == Keys.Escape)
        {
            DialogResult = DialogResult.Cancel;
            return true;
        }
        uint modifiers = ((keyData & Keys.Control) != 0 ? MOD_CONTROL : 0)
            | ((keyData & Keys.Alt) != 0 ? MOD_ALT : 0) | ((keyData & Keys.Shift) != 0 ? MOD_SHIFT : 0);
        var chord = new KeyChord((uint)key, modifiers);
        if (!chord.IsValid) return base.ProcessCmdKey(ref message, keyData);
        Chord = chord;
        DialogResult = DialogResult.OK;
        return true;
    }
}
