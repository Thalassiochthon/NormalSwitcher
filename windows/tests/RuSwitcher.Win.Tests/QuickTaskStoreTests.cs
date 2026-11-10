using RuSwitcher.Win.Core;
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
}
