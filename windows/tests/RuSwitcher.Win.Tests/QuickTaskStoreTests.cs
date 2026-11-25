using System.Windows.Forms;
using RuSwitcher.Win.Core;
using RuSwitcher.Win.UI;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class QuickTaskStoreTests
{
    [Fact]
    public void TaskRoundTripAndCorruptFileCannotBeOverwritten()
    {
        string folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        string path = Path.Combine(folder, "tasks.dat");
        try
        {
            var store = new QuickTaskStore(path);
            var task = QuickTask.FromText("\r\n   Журнал 👩‍💻\r\nполный текст");
            Assert.Equal("Журнал 👩‍💻", task.Title);
            store.Change(_ => [task]);
            Assert.Equal(task, Assert.Single(new QuickTaskStore(path).Read()));
            store.Change(items => [items.Single() with { Completed = true }]);
            Assert.True(Assert.Single(store.Read()).Completed);
            byte[] damaged = [1, 2, 3];
            File.WriteAllBytes(path, damaged);
            Assert.ThrowsAny<Exception>(() => store.Change(_ => []));
            Assert.Equal(damaged, File.ReadAllBytes(path));
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }

    [Theory]
    [InlineData(0, false)]
    [InlineData(1, true)]
    [InlineData(119, true)]
    [InlineData(120, true)]
    [InlineData(121, false)]
    public void TitleLengthIsAnInclusiveMaximum(int length, bool accepted)
    {
        // An emoji grapheme spans multiple UTF-16 units.
        string title = string.Concat(Enumerable.Repeat("👩‍💻", length));
        Assert.Equal(accepted, QuickTaskStore.Valid(new(Guid.NewGuid(), title, "", false)));
    }

    [Fact]
    public async Task NewTaskButtonSavesAShortTitleWithoutClipboardText()
    {
        string folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var store = new QuickTaskStore(Path.Combine(folder, "tasks.dat"));
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ui = new Thread(() =>
        {
            try
            {
                using var window = new QuickTasksWindow(store);
                window.Open();
                var create = (Button)window.Controls.Find("NewTask", true).Single();
                Exception? editorFailure = null;
                window.BeginInvoke(() =>
                {
                    Form? editor = null;
                    try
                    {
                        editor = Application.OpenForms.Cast<Form>().Single(form => form.Name == "TaskEditor");
                        var title = (TextBox)editor.Controls.Find("TaskTitle", true).Single();
                        title.Text = "  План  ";
                        ((Button)editor.AcceptButton!).PerformClick();
                    }
                    catch (Exception error)
                    {
                        editorFailure = error;
                        editor?.Close();
                    }
                });
                create.PerformClick();
                Assert.Null(editorFailure);
                var saved = Assert.Single(store.Read());
                Assert.Equal("План", saved.Title);
                Assert.Equal("", saved.Text);
                Assert.False(saved.Completed);
                finished.SetResult();
            }
            catch (Exception error) { finished.SetException(error); }
            finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
        }) { IsBackground = true };
        ui.SetApartmentState(ApartmentState.STA);
        ui.Start();
        await finished.Task.WaitAsync(TimeSpan.FromSeconds(20));
    }
}
