using System.Drawing;
using RuSwitcher.Win.Core;

namespace RuSwitcher.Win.UI;

internal sealed class QuickTasksWindow : Form
{
    private readonly QuickTaskStore _store = new(Path.Combine(Settings.DataDirectory, "tasks.dat"));
    private readonly ListBox _list = new() { Dock = DockStyle.Fill, IntegralHeight = false };
    private readonly TextBox _search = new() { Dock = DockStyle.Top, PlaceholderText = L10n.T("clipboard.search") };
    private readonly CheckBox _done = new() { Text = L10n.T("tasks.completed"), AutoSize = true, Dock = DockStyle.Top };
    private readonly Label _status = new() { Dock = DockStyle.Bottom, AutoSize = true };
    private readonly Button _undo = MakeButton("tasks.undo");
    private readonly Button _toggle = MakeButton("tasks.complete");
    private readonly Button _edit = MakeButton("tasks.edit");
    private readonly Button _delete = MakeButton("tasks.delete");
    private QuickTask[] _tasks = [];
    private Guid? _added;
    private bool _editing;
    private Form? _notice;

    public QuickTasksWindow()
    {
        Text = L10n.T("tasks.title");
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(480, 350);
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true };
        var create = MakeButton("tasks.new");
        var reload = MakeButton("clipboard.retry");
        actions.Controls.AddRange([create, _edit, _toggle, _delete, _undo, reload]);
        Controls.AddRange([_list, _done, _search, actions, _status]);
        _list.DisplayMember = nameof(QuickTask.Title);
        _search.PlaceholderText = L10n.T("tasks.search");
        _search.TextChanged += (_, _) => RefreshList();
        _done.CheckedChanged += (_, _) => RefreshList();
        _list.SelectedIndexChanged += (_, _) => RefreshActions();
        _list.DoubleClick += (_, _) => Edit(Selected);
        _list.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; Edit(Selected); } };
        create.Click += (_, _) => Edit(null);
        _edit.Click += (_, _) => Edit(Selected);
        _toggle.Click += (_, _) =>
        {
            if (Selected is { } task)
                Change(items => items.Select(item => item.Id == task.Id ? item with { Completed = !task.Completed } : item).ToArray());
        };
        _delete.Click += (_, _) =>
        {
            if (Selected is { } task && MessageBox.Show(this, L10n.T("tasks.confirmDelete"), Text,
                MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) == DialogResult.Yes)
                Change(items => items.Where(item => item.Id != task.Id).ToArray());
        };
        _undo.Click += (_, _) =>
        {
            if (_added is Guid id && Change(items => items.Where(task => task.Id != id).ToArray()))
            {
                _added = null;
                RefreshActions();
            }
        };
        reload.Click += (_, _) => Reload();
        Shown += (_, _) => Reload();
        FormClosing += (_, e) =>
        {
            if (e.CloseReason == CloseReason.UserClosing && !_editing) { e.Cancel = true; Hide(); }
        };
        KeyPreview = true;
        KeyDown += (_, e) => { if (e.KeyCode == Keys.Escape && !_editing) Hide(); };
        Disposed += (_, _) => _notice?.Dispose();
        RefreshActions();
    }

    public void Notify(string message)
    {
        _notice?.Dispose();
        var notice = new TaskNotice
        {
            Text = L10n.T("tasks.title"), FormBorderStyle = FormBorderStyle.FixedToolWindow,
            ShowInTaskbar = false, TopMost = true, StartPosition = FormStartPosition.Manual,
            AutoScaleMode = AutoScaleMode.Dpi, AutoScaleDimensions = new SizeF(96, 96),
            ClientSize = new Size(330, 46)
        };
        var row = new FlowLayoutPanel { Dock = DockStyle.Fill };
        row.Controls.Add(new Label { Text = message, AutoSize = true, Padding = new Padding(4, 8, 0, 0) });
        if (message == L10n.T("tasks.added") && _added is Guid id)
        {
            var undo = MakeButton("tasks.undo");
            undo.Click += (_, _) =>
            {
                if (Change(items => items.Where(task => task.Id != id).ToArray())) notice.Close();
                else { notice.Close(); Notify(L10n.T("tasks.storage")); }
            };
            row.Controls.Add(undo);
        }
        notice.Controls.Add(row);
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        notice.Location = new Point(area.Right - notice.Width - 12, area.Bottom - notice.Height - 12);
        var timer = new System.Windows.Forms.Timer { Interval = 6000 };
        timer.Tick += (_, _) => notice.Close();
        notice.Disposed += (_, _) => timer.Dispose();
        _notice = notice;
        notice.Show();
        timer.Start();
    }

    private sealed class TaskNotice : Form
    {
        protected override bool ShowWithoutActivation => true;
    }

    public void Open()
    {
        if (_editing) return;
        if (!Visible) { Reload(); Show(); }
        Activate();
    }

    public bool AddText(string? text)
    {
        if (string.IsNullOrWhiteSpace(text) || !ClipboardHistoryStore.IsValid(text)) return false;
        var task = QuickTask.FromText(text);
        if (!Change(items => [task, .. items])) return false;
        _added = task.Id;
        _status.Text = L10n.T("tasks.added");
        RefreshActions();
        return true;
    }

    private QuickTask? Selected => _list.SelectedItem as QuickTask;

    private void Reload()
    {
        try { _tasks = _store.Read(); _status.Text = ""; RefreshList(); }
        catch { _status.Text = L10n.T("tasks.storage"); }
    }

    private bool Change(Func<QuickTask[], QuickTask[]> change)
    {
        try { _tasks = _store.Change(change); _status.Text = ""; RefreshList(); return true; }
        catch { _status.Text = L10n.T("tasks.storage"); return false; }
    }

    private void RefreshList()
    {
        var selected = Selected?.Id;
        string query = _search.Text.Trim();
        var visible = _tasks.Where(task => task.Completed == _done.Checked &&
            (task.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
             task.Text.Contains(query, StringComparison.CurrentCultureIgnoreCase))).ToArray();
        _list.DataSource = visible;
        int index = Array.FindIndex(visible, task => task.Id == selected);
        if (index >= 0) _list.SelectedIndex = index;
        RefreshActions();
    }

    private void RefreshActions()
    {
        _toggle.Enabled = _edit.Enabled = _delete.Enabled = Selected != null;
        _toggle.Text = L10n.T(_done.Checked ? "tasks.reopen" : "tasks.complete");
        _undo.Visible = _added is Guid id && _tasks.Any(task => task.Id == id);
    }

    private void Edit(QuickTask? original)
    {
        if (_editing) return;
        _editing = true;
        try
        {
            using var editor = new Form
            {
                Text = L10n.T(original == null ? "tasks.new" : "tasks.edit"),
                FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
                ClientSize = new Size(450, 310), MinimizeBox = false, MaximizeBox = false,
                AutoScaleMode = AutoScaleMode.Dpi, AutoScaleDimensions = new SizeF(96, 96), ShowInTaskbar = false
            };
            var title = new TextBox { Dock = DockStyle.Top, Text = original?.Title ?? "", PlaceholderText = L10n.T("tasks.name") };
            var text = new TextBox { Dock = DockStyle.Fill, Multiline = true, ScrollBars = ScrollBars.Vertical,
                Text = original?.Text ?? "", MaxLength = ClipboardHistoryStore.MaxEntryLength };
            var save = MakeButton("tasks.save");
            var close = MakeButton("settings.close");
            close.DialogResult = DialogResult.Cancel;
            var row = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true };
            row.Controls.AddRange([save, close]);
            editor.Controls.AddRange([text, title, row]);
            editor.AcceptButton = save;
            editor.CancelButton = close;
            bool saved = false;
            save.Click += (_, _) =>
            {
                var draft = new QuickTask(original?.Id ?? Guid.NewGuid(), title.Text.Trim(), text.Text, false);
                if (!QuickTaskStore.Valid(draft))
                {
                    MessageBox.Show(editor, L10n.T("tasks.invalid"));
                    return;
                }
                if (!Change(items =>
                {
                    if (original == null) return [draft, .. items];
                    var current = items.FirstOrDefault(item => item.Id == original.Id);
                    if (current == null || current.Title != original.Title || current.Text != original.Text)
                        throw new InvalidOperationException();
                    return items.Select(item => item.Id == draft.Id ? draft with { Completed = item.Completed } : item).ToArray();
                }))
                {
                    MessageBox.Show(editor, _status.Text);
                    return;
                }
                saved = true;
                editor.DialogResult = DialogResult.OK;
            };
            editor.FormClosing += (_, e) =>
            {
                if (!saved && (title.Text != (original?.Title ?? "") || text.Text != (original?.Text ?? "")))
                    e.Cancel = MessageBox.Show(editor, L10n.T("tasks.discard"), editor.Text, MessageBoxButtons.YesNo,
                        MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes;
            };
            editor.ShowDialog(this);
        }
        finally { _editing = false; }
    }

    private static Button MakeButton(string key) => new() { Text = L10n.T(key), AutoSize = true };
}
